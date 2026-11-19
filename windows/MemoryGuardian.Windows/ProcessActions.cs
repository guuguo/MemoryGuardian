using System;
using System.Collections.Generic;
using System.Diagnostics;
using MemoryGuardian.Core;

namespace MemoryGuardian.Windows;

internal static class ProcessActions
{
    private static readonly HashSet<string> Protected = new(StringComparer.OrdinalIgnoreCase)
        { "explorer.exe", "svchost.exe", "services.exe", "wininit.exe", "winlogon.exe", "conhost.exe", "dwm.exe", "sihost.exe", "csrss.exe", "lsass.exe", "System" };
    internal static bool CanClose(AppMemory app) => app.Primary.HasWindow && app.Primary.Started != 0 &&
        app.Primary.Pid != Environment.ProcessId && !Protected.Contains(app.Primary.Name);

    internal static string RequestClose(AppMemory app)
    {
        if (!CanClose(app)) return "此组没有可安全请求关闭的应用窗口。";
        // Keep a handle to the verified process alive through the request so its PID cannot be recycled in between.
        using var identity = Native.OpenProcess(0x1000, false, app.Primary.Pid);
        if (identity.IsInvalid || !Native.GetProcessTimes(identity, out long started, out _, out _, out _) ||
            started != app.Primary.Started) return "原进程已退出、读取受限或 PID 已变化，请刷新。";
        try
        {
            using var process = Process.GetProcessById(app.Primary.Pid);
            // No Kill/TerminateProcess fallback. A save prompt or refusal belongs to the target application.
            return process.CloseMainWindow() ? "已发送正常关闭请求；请处理应用的保存提示。" : "应用未接受关闭请求，请在其窗口中退出。";
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { return "进程已退出或拒绝访问，请刷新后重试。"; }
    }
}
