namespace MemoryGuardian.Core;

public sealed record SystemMemory(DateTimeOffset Timestamp, ulong PhysicalTotal, ulong PhysicalAvailable,
    ulong CommitUsed, ulong CommitLimit, ulong SystemCache, ulong KernelMemory,
    ulong? PageFileUsed, ulong? PageFileAllocated)
{
    public ulong PhysicalUsed => PhysicalTotal - Math.Min(PhysicalAvailable, PhysicalTotal);
    public double PhysicalRatio => PhysicalTotal == 0 ? 0 : (double)PhysicalUsed / PhysicalTotal;
    public double CommitRatio => CommitLimit == 0 ? 0 : (double)CommitUsed / CommitLimit;
    public string Headroom => PhysicalRatio >= .9 || CommitRatio >= .9 ? "余量偏低" :
        PhysicalRatio >= .8 || CommitRatio >= .8 ? "留意余量" : "余量充足";
}

public sealed record ServiceInfo(string Identity, string Name, string? EntryPoint);

public sealed record ProcessMemory(int Pid, int ParentPid, long Started, string Name, string? Executable,
    ulong? WorkingSet, ulong? PrivateWorkingSet, ulong? PrivateCommit, bool HasWindow, ServiceInfo? Service = null)
{
    public string Identity => $"{Pid}:{Started}";
    public bool IsNode => Name.Equals("node.exe", StringComparison.OrdinalIgnoreCase) ||
                          Name.Equals("nodejs.exe", StringComparison.OrdinalIgnoreCase);
}

public sealed record ServiceUsage(string Name, ulong? Bytes, int Count);

public sealed record AppMemory(string Key, string Name, ProcessMemory Primary,
    IReadOnlyList<ProcessMemory> Processes)
{
    public bool UsesPrivateWorkingSet => Processes.All(p => p.PrivateWorkingSet.HasValue);
    public int UnreadableCount => Processes.Count(p => !p.WorkingSet.HasValue);
    public ulong? Bytes => SumKnown(Processes.Select(p => UsesPrivateWorkingSet ? p.PrivateWorkingSet : p.WorkingSet));
    public ulong? Commit => Processes.All(p => p.PrivateCommit.HasValue)
        ? SumKnown(Processes.Select(p => p.PrivateCommit)) : null;
    public string Metric => UsesPrivateWorkingSet ? "私有工作集" :
        UnreadableCount > 0 ? $"工作集 · {UnreadableCount} 项未读取" : "工作集 · 含共享页";
    public string Size => Units.Bytes(Bytes);
    public string CommitSize => Units.Bytes(Commit);
    public int ProcessCount => Processes.Count;
    public string Location => Primary.Executable ?? "路径未读取";
    public IReadOnlyList<ServiceUsage> Services => Processes.Where(p => p.Service != null)
        .GroupBy(p => p.Service!.Identity)
        .Select(g => new ServiceUsage(g.First().Service!.Name,
            SumKnown(g.Select(p => UsesPrivateWorkingSet ? p.PrivateWorkingSet : p.WorkingSet)), g.Count()))
        .OrderByDescending(s => s.Bytes).ToArray();
    public bool Matches(string query) => string.IsNullOrWhiteSpace(query) ||
        Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
        Processes.Any(p => p.Pid.ToString().Contains(query, StringComparison.OrdinalIgnoreCase) ||
            (p.Executable?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false) ||
            (p.Service?.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false));

    public static ulong? SumKnown(IEnumerable<ulong?> values)
    {
        bool any = false; ulong sum = 0;
        foreach (var value in values)
            if (value.HasValue) { any = true; sum = checked(sum + value.Value); }
        return any ? sum : null;
    }
}

public sealed record MemorySample(SystemMemory System, IReadOnlyList<AppMemory> Apps, int ProcessCount,
    int UnreadableCount, string? AttributionWarning = null);

public static class Units
{
    public static string Bytes(ulong? value)
    {
        if (!value.HasValue) return "—";
        double size = value.Value;
        string[] suffix = ["B", "KiB", "MiB", "GiB", "TiB"];
        int i = 0;
        while (size >= 1024 && i < suffix.Length - 1) { size /= 1024; i++; }
        return $"{size:0.##} {suffix[i]}";
    }
}
