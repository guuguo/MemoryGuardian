using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MemoryGuardian.Windows;

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Performance
    {
        internal uint Size;
        internal nuint CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable,
            SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        internal uint Handles, Processes, Threads;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Counters
    {
        internal uint Size, PageFaultCount;
        internal nuint PeakWorkingSet, WorkingSet, PeakPagedPool, PagedPool, PeakNonpagedPool,
            NonpagedPool, PagefileUsage, PeakPagefileUsage, PrivateUsage, PrivateWorkingSet;
        internal ulong SharedCommit;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct Entry
    {
        internal uint Size, Usage, Pid;
        internal nuint DefaultHeap;
        internal uint Module, Threads, ParentPid;
        internal int Priority;
        internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] internal string Name;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PageFile { internal uint Size, Reserved; internal nuint Total, Used, Peak; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal delegate bool PageFileCallback(nint context, ref PageFile info, string name);
    internal delegate bool WindowCallback(nint window, nint parameter);

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetPerformanceInfo(ref Performance info, uint size);
    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetProcessMemoryInfo(SafeProcessHandle handle, ref Counters counters, uint size);
    [DllImport("psapi.dll", EntryPoint = "EnumPageFilesW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumPageFiles(PageFileCallback callback, nint context);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ProcessFirst(SafeFileHandle snapshot, ref Entry entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ProcessNext(SafeFileHandle snapshot, ref Entry entry);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeProcessHandle OpenProcess(uint rights, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder name, ref uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exited, out long kernel, out long user);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(WindowCallback callback, nint parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint memory);

    internal static string[] Arguments(string command)
    {
        nint memory = CommandLineToArgvW(command, out int count);
        if (memory == 0) return [];
        try
        {
            var values = new string[count];
            for (int i = 0; i < count; i++) values[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size)) ?? "";
            return values;
        }
        finally { LocalFree(memory); }
    }

    internal static long Started(int pid)
    {
        using var h = OpenProcess(0x1000, false, pid);
        return !h.IsInvalid && GetProcessTimes(h, out long t, out _, out _, out _) ? t : 0;
    }

    internal static string? ExecutablePath(SafeProcessHandle process)
    {
        var name = new StringBuilder(512); uint length = (uint)name.Capacity;
        if (QueryFullProcessImageName(process, 0, name, ref length)) return name.ToString();
        if (Marshal.GetLastWin32Error() != 122) return null;
        name = new StringBuilder(32768); length = (uint)name.Capacity;
        return QueryFullProcessImageName(process, 0, name, ref length) ? name.ToString() : null;
    }

    internal static HashSet<int> WindowProcesses()
    {
        var ids = new HashSet<int>();
        EnumWindows((window, _) =>
        {
            if (IsWindowVisible(window)) { GetWindowThreadProcessId(window, out uint pid); ids.Add((int)pid); }
            return true;
        }, 0);
        return ids;
    }

    internal static Exception Error(string label) => new Win32Exception(Marshal.GetLastWin32Error(), label);
}
