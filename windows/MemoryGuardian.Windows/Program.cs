using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;

namespace MemoryGuardian.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--self-test")
            return SelfTest(args.Length > 1 ? args[1] : Path.Combine(AppContext.BaseDirectory, "self-test.json"));
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        return app.Run(new MainWindow());
    }

    private static int SelfTest(string output)
    {
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            var sampler = new WindowsSampler(); var watch = Stopwatch.StartNew();
            var sample = sampler.Read(); long elapsed = watch.ElapsedMilliseconds;
            bool layout = Marshal.SizeOf<Native.Performance>() == (IntPtr.Size == 8 ? 104 : 56) &&
                Marshal.OffsetOf<Native.Counters>(nameof(Native.Counters.PrivateWorkingSet)).ToInt32() == (IntPtr.Size == 8 ? 80 : 44);
            bool totals = sample.System.PhysicalTotal > 0 && sample.System.PhysicalAvailable <= sample.System.PhysicalTotal &&
                sample.System.CommitUsed <= sample.System.CommitLimit;
            var pids = sample.Apps.SelectMany(a => a.Processes).Select(p => p.Pid).ToArray();
            bool unique = pids.Length == sample.ProcessCount && pids.Distinct().Count() == pids.Length;
            var own = sample.Apps.SelectMany(a => a.Processes).FirstOrDefault(p => p.Pid == Environment.ProcessId);
            bool ownRead = own != null && own.WorkingSet > 0 && own.PrivateCommit > 0 && own.Started > 0;
            var argv = Native.Arguments("node.exe \"C:\\项目 空格\\node_modules\\@scope\\mcp\\dist\\index.js\" --token hidden");
            bool argvValid = argv.Length == 4 && argv[1] == "C:\\项目 空格\\node_modules\\@scope\\mcp\\dist\\index.js";
            var report = new
            {
                passed = layout && totals && unique && ownRead && argvValid,
                time = DateTimeOffset.Now, architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                checks = new { layout, totals, unique, ownRead, argvValid }, sampleMilliseconds = elapsed,
                system = sample.System, sample.ProcessCount, sample.UnreadableCount, sample.AttributionWarning,
                selfWorkingSetBytes = own?.WorkingSet, selfPrivateCommitBytes = own?.PrivateCommit,
                unverified = new[] { "UI、托盘、关闭请求、任务管理器同口径核对及持续采样资源开销需另行验收" }
            };
            File.WriteAllText(output, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            return report.passed ? 0 : 1;
        }
        catch (Exception e)
        {
            try { File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = e.GetType().Name })); }
            catch (IOException) { }
            return 1;
        }
    }
}
