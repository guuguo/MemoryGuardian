using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using MemoryGuardian.Core;

namespace MemoryGuardian.Windows;

internal sealed class WindowsSampler
{
    private readonly Dictionary<string, ServiceInfo?> nodeCache = new();
    private DateTimeOffset lastMetadataAttempt = DateTimeOffset.MinValue;
    private string? attributionWarning;

    internal MemorySample Read()
    {
        var native = new Native.Performance { Size = (uint)Marshal.SizeOf<Native.Performance>() };
        if (!Native.GetPerformanceInfo(ref native, native.Size)) throw Native.Error("无法读取系统内存");
        ulong page = native.PageSize;
        ulong pageAllocated = 0, pageUsed = 0;
        Native.PageFileCallback callback = (nint _, ref Native.PageFile file, string _) =>
        {
            pageAllocated += checked((ulong)file.Total * page);
            pageUsed += checked((ulong)file.Used * page);
            return true;
        };
        bool pageFilesRead = Native.EnumPageFiles(callback, 0);
        var system = new SystemMemory(DateTimeOffset.Now, checked((ulong)native.PhysicalTotal * page),
            checked((ulong)native.PhysicalAvailable * page), checked((ulong)native.CommitTotal * page),
            checked((ulong)native.CommitLimit * page), checked((ulong)native.SystemCache * page),
            checked((ulong)native.KernelTotal * page), pageFilesRead ? pageUsed : null,
            pageFilesRead ? pageAllocated : null);
        var rows = ReadProcesses();
        ReadNodeMetadata(rows);
        rows = rows.Select(p => p.IsNode && nodeCache.TryGetValue(p.Identity, out var service) ? p with { Service = service } : p).ToList();
        return new(system, AppAggregator.Aggregate(rows), rows.Count, rows.Count(p => !p.WorkingSet.HasValue), attributionWarning);
    }

    private static List<ProcessMemory> ReadProcesses()
    {
        long snapshotStarted = DateTime.UtcNow.ToFileTimeUtc();
        using var snapshot = Native.CreateToolhelp32Snapshot(2, 0);
        if (snapshot.IsInvalid) throw Native.Error("无法枚举进程");
        var windows = Native.WindowProcesses();
        var entry = new Native.Entry { Size = (uint)Marshal.SizeOf<Native.Entry>() };
        var rows = new List<ProcessMemory>();
        if (!Native.ProcessFirst(snapshot, ref entry)) throw Native.Error("无法读取进程列表");
        do
        {
            int pid = (int)entry.Pid;
            if (pid == 0) continue;
            var handle = Native.OpenProcess(0x1000, false, pid); // Query-only access; no VM_READ or debug privilege.
            using (handle)
            {
                string? path = null;
                long started = 0;
                ulong? ws = null, privateWs = null, commit = null;
                if (!handle.IsInvalid)
                {
                    path = Native.ExecutablePath(handle);
                    if (!Native.GetProcessTimes(handle, out started, out _, out _, out _)) started = 0;
                    // A PID that now denotes a process born after snapshot capture must not inherit the old entry's parent/name.
                    if (started > snapshotStarted) continue;
                    var memory = new Native.Counters { Size = (uint)Marshal.SizeOf<Native.Counters>() };
                    bool extended = Native.GetProcessMemoryInfo(handle, ref memory, memory.Size);
                    if (!extended)
                    {
                        // EX omits the final PrivateWorkingSet/SharedCommit fields; keep the metric fallback explicit.
                        memory.Size = (uint)Marshal.OffsetOf<Native.Counters>(nameof(Native.Counters.PrivateWorkingSet));
                        if (Native.GetProcessMemoryInfo(handle, ref memory, memory.Size))
                        { ws = (ulong)memory.WorkingSet; commit = (ulong)memory.PrivateUsage; }
                    }
                    else { ws = (ulong)memory.WorkingSet; privateWs = (ulong)memory.PrivateWorkingSet; commit = (ulong)memory.PrivateUsage; }
                }
                rows.Add(new(pid, (int)entry.ParentPid, started, entry.Name ?? $"PID {pid}", path,
                    ws, privateWs, commit, windows.Contains(pid)));
            }
        } while (Native.ProcessNext(snapshot, ref entry));
        int error = Marshal.GetLastWin32Error();
        if (error != 18) throw new System.ComponentModel.Win32Exception(error, "进程枚举未完整结束");
        return rows;
    }

    private void ReadNodeMetadata(List<ProcessMemory> rows)
    {
        var nodes = rows.Where(p => p.IsNode).ToArray();
        var alive = nodes.Select(p => p.Identity).ToHashSet();
        foreach (string key in nodeCache.Keys.Where(k => !alive.Contains(k)).ToArray()) nodeCache.Remove(key);
        if (nodes.Length == 0) { attributionWarning = null; return; }
        bool missing = nodes.Any(p => !nodeCache.ContainsKey(p.Identity));
        bool retry = attributionWarning != null && DateTimeOffset.UtcNow - lastMetadataAttempt > TimeSpan.FromSeconds(30);
        if (!missing && !retry) return;
        // At most one WMI batch each sampling tick; never one query per process and never spawn PowerShell.
        lastMetadataAttempt = DateTimeOffset.UtcNow;
        foreach (var p in nodes) nodeCache.TryAdd(p.Identity, null);
        try
        {
            var options = new EnumerationOptions { Timeout = TimeSpan.FromSeconds(2), ReturnImmediately = true, Rewindable = false };
            using var search = new ManagementObjectSearcher("root\\CIMV2",
                "SELECT ProcessId,CreationDate,CommandLine FROM Win32_Process WHERE Name='node.exe' OR Name='nodejs.exe'", options);
            using var found = search.Get();
            var byPid = nodes.ToDictionary(p => p.Pid);
            int restricted = 0;
            foreach (ManagementObject record in found)
            {
                using (record)
                {
                    int pid = Convert.ToInt32(record["ProcessId"]);
                    if (!byPid.TryGetValue(pid, out var p) || p.Started == 0) continue;
                    string? creation = record["CreationDate"] as string;
                    if (creation == null) { restricted++; continue; }
                    long wmiStarted = ManagementDateTimeConverter.ToDateTime(creation).ToUniversalTime().ToFileTimeUtc();
                    if (wmiStarted / 10 != p.Started / 10) continue; // WMI timestamps have microsecond precision.
                    // Verify this PID still denotes the process sampled above; WMI is a later snapshot.
                    if (Native.Started(pid) != p.Started) continue;
                    string? command = record["CommandLine"] as string;
                    if (string.IsNullOrWhiteSpace(command)) { restricted++; continue; }
                    nodeCache[p.Identity] = NodeService.Parse(Native.Arguments(command));
                    // Command lines are neither persisted nor included in view models or diagnostics.
                }
            }
            attributionWarning = restricted > 0 ? $"{restricted} 个 Node 进程的服务入口读取受限" : null;
        }
        catch (Exception e) when (e is ManagementException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        { attributionWarning = "Node 服务归因暂不可用；仍显示真实可读的内存与父子关系"; }
    }
}
