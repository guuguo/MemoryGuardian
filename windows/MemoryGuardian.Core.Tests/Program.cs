using MemoryGuardian.Core;

int passed = 0;
void Check(string name, Action test)
{
    try { test(); Console.WriteLine("PASS " + name); passed++; }
    catch (Exception e) { Console.Error.WriteLine("FAIL " + name + ": " + e.Message); Environment.Exit(1); }
}
void Require(bool condition) { if (!condition) throw new Exception("assertion failed"); }
ProcessMemory P(int pid, int parent, string name, bool window = false, long start = 100, ulong? ws = 20,
    ulong? privateWs = 10, ulong? commit = 30, ServiceInfo? service = null) =>
    new(pid, parent, start, name, "C:\\Apps\\" + name, ws, privateWs, commit, window, service);
SystemMemory S(DateTimeOffset time) => new(time, 48, 10, 60, 96, 8, 4, 12, 48);

Check("physical and commit denominators stay separate", () =>
{
    var s = S(DateTimeOffset.Now); Require(s.PhysicalUsed == 38 && s.PhysicalRatio == 38d / 48 && s.CommitRatio == 60d / 96);
    Require((s with { PhysicalAvailable = 99 }).PhysicalUsed == 0);
});
Check("headroom includes commit exhaustion", () => Require((S(DateTimeOffset.Now) with { CommitUsed = 95 }).Headroom == "余量偏低"));
Check("unknown bytes are not zero", () => Require(Units.Bytes(null) == "—" && AppMemory.SumKnown([null, null]) == null));
Check("multi-level Node children belong to the visible application once", () =>
{
    var rows = new[] { P(1, 99, "ChatGPT.exe", true), P(2, 1, "codex.exe"), P(3, 2, "node.exe"), P(4, 3, "node.exe") };
    var groups = AppAggregator.Aggregate(rows); Require(groups.Count == 1 && groups[0].ProcessCount == 4 && groups[0].Bytes == 40);
    Require(groups.SelectMany(g => g.Processes).Select(p => p.Pid).Distinct().Count() == 4);
});
Check("newer reused parent PID is not an owner", () =>
{
    var groups = AppAggregator.Aggregate([P(1, 99, "ChatGPT.exe", true, 200), P(2, 1, "node.exe", start: 100)]);
    Require(groups.Count == 2);
});
Check("unknown creation time does not infer ancestry", () =>
    Require(AppAggregator.Aggregate([P(1, 99, "ChatGPT.exe", true), P(2, 1, "node.exe", start: 0)]).Count == 2));
Check("missing and cyclic parents terminate without losing or duplicating processes", () =>
{
    var groups = AppAggregator.Aggregate([P(1, 2, "one.exe"), P(2, 1, "two.exe"), P(3, 99, "node.exe")]);
    Require(groups.SelectMany(a => a.Processes).Select(p => p.Pid).Distinct().Count() == 3);
});
Check("explorer does not absorb applications and child ownership respects nearest window", () =>
{
    var groups = AppAggregator.Aggregate([P(1, 99, "explorer.exe", true), P(2, 1, "App.exe", true), P(3, 2, "node.exe")]);
    Require(groups.Count == 2 && groups.Single(a => a.Primary.Pid == 2).ProcessCount == 2);
});
Check("a same-executable cycle does not swap ownership", () =>
{
    var groups = AppAggregator.Aggregate([P(1, 2, "node.exe"), P(2, 1, "node.exe")]);
    Require(groups.Count == 2 && groups.All(g => g.Processes.Any(p => p.Identity == g.Primary.Identity)));
});
Check("one missing private metric switches the whole app to working set", () =>
{
    var group = AppAggregator.Aggregate([P(1, 99, "App.exe", true, ws: 50), P(2, 1, "node.exe", privateWs: null)]).Single();
    Require(!group.UsesPrivateWorkingSet && group.Bytes == 70 && group.Metric.Contains("共享"));
});
Check("partial unreadable group is labelled and commit is not invented", () =>
{
    var group = AppAggregator.Aggregate([P(1, 99, "App.exe", true), P(2, 1, "node.exe", ws: null, privateWs: null, commit: null)]).Single();
    Require(group.UnreadableCount == 1 && group.Bytes == 20 && group.Commit == null && group.Metric.Contains("未读取"));
});
Check("scoped package names and npm wrappers agree", () =>
{
    var a = NodeService.Parse(["node.exe", @"C:\cache\node_modules\@agentmemory\mcp\dist\index.js"]);
    var b = NodeService.Parse(["node.exe", @"C:\node\npm-cli.js", "exec", "-y", "@agentmemory/mcp@1.2.3"]);
    Require(a?.Name == "@agentmemory/mcp" && a.Identity == b?.Identity);
});
Check("npm title and npx entry preserve package identity", () =>
{
    Require(NodeService.Parse(["npm exec shadcn@latest mcp"])?.Name == "shadcn");
    Require(NodeService.Parse(["node.exe", @"C:\node\npx-cli.js", "-y", "@scope/tool"])?.Name == "@scope/tool");
});
Check("independent scripts have distinct identities and Unicode/spaces survive", () =>
{
    var a = NodeService.Parse(["node.exe", @"C:\项目 一\src\server.mjs"]);
    var b = NodeService.Parse(["node.exe", @"D:\项目 二\src\server.mjs"]);
    Require(a?.Name == "项目 一" && a.Identity != b?.Identity && a.EntryPoint!.Contains("项目 一"));
});
Check("relative paths, inline code and options are not guessed as service entries", () =>
{
    Require(NodeService.Parse(["node.exe", "src/server.js"]) == null);
    Require(NodeService.Parse(["node.exe", "-e", "secret content"]) == null);
    Require(NodeService.Parse(["node.exe", "--token", "private"]) == null);
});
Check("independent same-package instances are not conflated", () =>
{
    var service = new ServiceInfo("package:tool", "tool", null);
    Require(AppAggregator.Aggregate([P(1, 99, "node.exe", service: service), P(2, 98, "node.exe", service: service)]).Count == 2);
});
Check("history has no fabricated past, duplicates or mixed metrics", () =>
{
    var t = DateTimeOffset.UtcNow; var app = AppAggregator.Aggregate([P(1, 99, "App.exe", true)]).Single();
    var history = new MemoryHistory(); Require(history.For(app).Count == 0);
    var sample = new MemorySample(S(t), [app], 1, 0); history.Add(sample); history.Add(sample);
    Require(history.For(app).Count == 1 && history.For(app)[0].Time == t);
    var fallback = AppAggregator.Aggregate([P(1, 99, "App.exe", true, privateWs: null)]).Single();
    Require(history.For(fallback).Count == 0);
    history.Add(new(S(t.AddMinutes(6)), [fallback], 1, 0));
    Require(history.For(app).Count == 0 && history.For(fallback).Count == 1);
});
Check("service contributions are already included in app total and searchable", () =>
{
    var service = new ServiceInfo("package:tool", "tool", @"C:\tool.js");
    var app = AppAggregator.Aggregate([P(1, 99, "App.exe", true), P(2, 1, "node.exe", service: service)]).Single();
    Require(app.Bytes == 20 && app.Services.Single().Bytes == 10 && app.Matches("tool") && app.Matches("2"));
});
Console.WriteLine($"{passed} checks passed");
