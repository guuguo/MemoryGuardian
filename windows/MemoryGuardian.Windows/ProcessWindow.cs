using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using MemoryGuardian.Core;

namespace MemoryGuardian.Windows;

internal sealed record ProcessRow(ProcessMemory Process, bool PrivateMetric)
{
    public string Name => Process.Name;
    public int Pid => Process.Pid;
    public int Parent => Process.ParentPid;
    public string Memory => Units.Bytes(PrivateMetric ? Process.PrivateWorkingSet : Process.WorkingSet);
    public ulong? MemoryBytes => PrivateMetric ? Process.PrivateWorkingSet : Process.WorkingSet;
    public string Commit => Units.Bytes(Process.PrivateCommit);
    public ulong? CommitBytes => Process.PrivateCommit;
    public string Service => Process.Service?.Name ?? "—";
    public string Path => Process.Service?.EntryPoint ?? Process.Executable ?? "读取受限";
}

internal sealed class ProcessWindow : Window
{
    private readonly DataGrid table = new();
    private readonly TextBlock caption = Theme.Label("", 12, Theme.Secondary);
    private readonly TextBlock path = Theme.Label("选择进程查看入口；不显示完整命令参数。", 12, Theme.Secondary);

    internal ProcessWindow(AppMemory app, DateTimeOffset timestamp)
    {
        Title = app.Name + " · 实时进程明细"; Width = 1000; Height = 620; MinWidth = 800; MinHeight = 450;
        Background = Theme.Background; Foreground = Theme.Text; FontFamily = new System.Windows.Media.FontFamily("Microsoft YaHei UI"); FontSize = 14;
        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); caption.Margin = new Thickness(0, 0, 0, 16); grid.Children.Add(caption);
        Theme.StyleGrid(table); table.Columns.Add(Theme.Column("进程", nameof(ProcessRow.Name), 0));
        table.Columns.Add(Theme.Column("PID", nameof(ProcessRow.Pid), 80)); table.Columns.Add(Theme.Column("父 PID", nameof(ProcessRow.Parent), 80));
        var memory = Theme.Column("内存", nameof(ProcessRow.Memory), 115); memory.SortMemberPath = nameof(ProcessRow.MemoryBytes); table.Columns.Add(memory);
        var commit = Theme.Column("私有提交", nameof(ProcessRow.Commit), 115); commit.SortMemberPath = nameof(ProcessRow.CommitBytes); table.Columns.Add(commit);
        table.Columns.Add(Theme.Column("服务", nameof(ProcessRow.Service), 180));
        table.SelectionChanged += (_, _) => path.Text = (table.SelectedItem as ProcessRow)?.Path ?? "选择进程查看入口；不显示完整命令参数。";
        Grid.SetRow(table, 1); grid.Children.Add(table); path.Margin = new Thickness(0, 16, 0, 0); Grid.SetRow(path, 2); grid.Children.Add(path); Content = grid;
        Update(app, timestamp);
    }

    internal void Update(AppMemory? app, DateTimeOffset timestamp)
    {
        int? selected = (table.SelectedItem as ProcessRow)?.Pid;
        caption.Text = app == null ? "此应用组已退出或归属已变化。" :
            $"更新于 {timestamp:HH:mm:ss} · 每 5 秒跟随主窗口刷新 · {app.Metric} · 不与私有提交量相加";
        var rows = app?.Processes.OrderByDescending(p => app.UsesPrivateWorkingSet ? p.PrivateWorkingSet : p.WorkingSet)
            .Select(p => new ProcessRow(p, app.UsesPrivateWorkingSet)).ToArray() ?? Array.Empty<ProcessRow>();
        table.ItemsSource = rows; table.SelectedItem = rows.FirstOrDefault(r => r.Pid == selected);
    }
}
