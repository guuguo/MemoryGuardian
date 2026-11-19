namespace MemoryGuardian.Core;

public sealed record MemoryPoint(DateTimeOffset Time, ulong Bytes);

public sealed class MemoryHistory
{
    private readonly Dictionary<string, List<MemoryPoint>> points = [];
    public static readonly TimeSpan Window = TimeSpan.FromMinutes(5);

    public void Add(MemorySample sample)
    {
        var cutoff = sample.System.Timestamp - Window;
        foreach (var series in points.Values) series.RemoveAll(p => p.Time < cutoff);
        foreach (string key in points.Where(p => p.Value.Count == 0).Select(p => p.Key).ToArray()) points.Remove(key);
        foreach (var app in sample.Apps)
        {
            if (!app.Bytes.HasValue) continue;
            // A metric fallback starts a separate series; do not join working-set and private-working-set samples.
            string key = app.Key + ":" + app.UsesPrivateWorkingSet;
            if (!points.TryGetValue(key, out var series)) points[key] = series = [];
            if (series.Count == 0 || series[^1].Time < sample.System.Timestamp)
                series.Add(new(sample.System.Timestamp, app.Bytes.Value));
        }
    }

    public IReadOnlyList<MemoryPoint> For(AppMemory app) =>
        points.TryGetValue(app.Key + ":" + app.UsesPrivateWorkingSet, out var series) ? series : [];
}
