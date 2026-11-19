using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using MemoryGuardian.Core;
using Forms = System.Windows.Forms;

namespace MemoryGuardian.Windows;

internal sealed record AppRow(AppMemory App, ulong Total)
{
    public string Name => App.Name;
    public string Size => App.Size;
    public ulong? MemoryBytes => App.Bytes;
    public double? PhysicalShare => App.Bytes.HasValue && Total > 0 ? (double)App.Bytes.Value / Total : null;
    public string Share => App.Bytes.HasValue && Total > 0 ? $"{(double)App.Bytes.Value / Total:P1}" : "—";
    public int Count => App.ProcessCount;
    public string Metric => App.Metric;
}

internal sealed class MainWindow : Window
{
    private readonly WindowsSampler sampler = new();
    private readonly MemoryHistory history = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly DataGrid table = new();
    private readonly TextBox search = new();
    private readonly TextBlock physical = Theme.Label("—", 48), physicalCaption = Theme.Label("等待真实采样", 12, Theme.Secondary),
        commit = Theme.Label("—", 26), commitCaption = Theme.Label("已提交 / 提交上限", 12, Theme.Secondary),
        pagefile = Theme.Label("—", 26), pageCaption = Theme.Label("已用 / 已分配", 12, Theme.Secondary),
        headroom = Theme.Label("正在采样", 14, Theme.Mint), status = Theme.Label("准备读取本机数据", 12, Theme.Secondary),
        detailName = Theme.Label("选择应用", 24), detailBytes = Theme.Label("—", 36),
        detailMetric = Theme.Label("", 12, Theme.Secondary), detailCommit = Theme.Label("", 14),
        detailPath = Theme.Label("", 12, Theme.Secondary), trendCaption = Theme.Label("采样后开始记录", 12, Theme.Secondary),
        services = Theme.Label("", 13, Theme.Secondary), detailAdvice = Theme.Label("", 13, Theme.Secondary);
    private readonly Gauge physicalGauge = new(), commitGauge = new() { Fill = Theme.Blue };
    private readonly Trend chart = new() { Height = 115 };
    private readonly Button closeButton, processButton;
    private readonly Forms.NotifyIcon tray = new();
    private readonly Dictionary<string, ProcessWindow> processWindows = new();
    private MemorySample? sample;
    private bool sampling, closing;

    internal MainWindow()
    {
        Title = "内存守卫 · Windows 预览版"; Width = 1280; Height = 850; MinWidth = 1100; MinHeight = 740;
        Background = Theme.Background; Foreground = Theme.Text; FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14;
        closeButton = Theme.Button("正常退出…", RequestClose);
        processButton = Theme.Button("查看进程", (_, _) => ShowProcesses());
        closeButton.IsEnabled = false; processButton.IsEnabled = false;
        Content = Build();
        timer.Tick += async (_, _) => await Refresh();
        Loaded += async (_, _) => { timer.Start(); await Refresh(); };
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) Hide(); };
        Closed += (_, _) =>
        {
            closing = true; timer.Stop(); tray.Visible = false; tray.Dispose();
            foreach (var window in processWindows.Values.ToArray()) window.Close();
        };
        tray.Icon = System.Drawing.SystemIcons.Application; tray.Text = "内存守卫 · 等待采样"; tray.Visible = true;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(Restore);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示内存守卫", null, (_, _) => Dispatcher.Invoke(Restore));
        menu.Items.Add("退出", null, (_, _) => Dispatcher.Invoke(Close)); tray.ContextMenuStrip = menu;
    }

    private UIElement Build()
    {
        var root = new Grid { Margin = new Thickness(32) };
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 28) };
        var refresh = Theme.Button("刷新", async (_, _) => await Refresh()); DockPanel.SetDock(refresh, Dock.Right); header.Children.Add(refresh);
        var info = Theme.Button("统计说明", (_, _) => MessageBox.Show(this,
            "物理已用 = 物理总量 − 可用量；可用量包含可回收的待机页。\n\n提交量是系统承诺提供后备存储的内存，不代表实际驻留或分页文件已用。分页文件数值单独枚举。\n\n排行优先显示私有工作集；整组有该指标不可读时回退工作集并标注。工作集含共享页，各应用相加不能作为物理内存分区。未知或受限值不显示为 0。\n\n余量提醒按物理使用率或提交率达到 80% / 90% 提示，属于本应用规则。不是 Windows 内存压力事件。\n\nNode 命令行仅用于解析服务名/入口，不保存或显示完整参数。界面数据每 5 秒刷新。最小化可收入托盘，关闭窗口退出。",
            "数据口径", MessageBoxButton.OK, MessageBoxImage.Information));
        DockPanel.SetDock(info, Dock.Right); header.Children.Add(info);
        header.Children.Add(Theme.Label("▤  内存守卫", 21, Theme.Mint)); root.Children.Add(header);
        var overview = new Grid { Margin = new Thickness(0, 0, 0, 28) };
        overview.ColumnDefinitions.Add(new() { Width = new GridLength(2, GridUnitType.Star) });
        overview.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        overview.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var ram = Card("物理内存", physical, physicalCaption, physicalGauge);
        ram.Children.Add(headroom); headroom.Margin = new Thickness(0, 10, 0, 0);
        overview.Children.Add(ram);
        var committed = Card("系统提交量", commit, commitCaption, commitGauge); Grid.SetColumn(committed, 1); overview.Children.Add(committed);
        var paging = Card("分页文件", pagefile, pageCaption);
        paging.Children.Add(Theme.Label("与物理内存分开统计", 12, Theme.Secondary)); Grid.SetColumn(paging, 2); overview.Children.Add(paging);
        Grid.SetRow(overview, 1); root.Children.Add(overview);
        var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new() { Width = new GridLength(320) });
        var left = new Grid { Margin = new Thickness(0, 0, 28, 0) };
        left.RowDefinitions.Add(new() { Height = GridLength.Auto }); left.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        var listHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        search.Width = 260; search.MinHeight = 32; search.Background = Theme.Surface; search.Foreground = Theme.Text;
        search.CaretBrush = Theme.Mint; search.BorderBrush = Theme.Line; search.Padding = new Thickness(10, 5, 10, 5);
        search.ToolTip = "搜索应用、路径、服务名或 PID"; search.TextChanged += (_, _) => ShowRows();
        System.Windows.Automation.AutomationProperties.SetName(search, "搜索应用、路径、服务名或 PID");
        DockPanel.SetDock(search, Dock.Right); listHeader.Children.Add(search); listHeader.Children.Add(Theme.Label("应用", 22));
        left.Children.Add(listHeader); Theme.StyleGrid(table);
        table.Columns.Add(Theme.Column("名称", nameof(AppRow.Name), 0));
        var memoryColumn = Theme.Column("内存", nameof(AppRow.Size), 115); memoryColumn.SortMemberPath = nameof(AppRow.MemoryBytes); table.Columns.Add(memoryColumn);
        var shareColumn = Theme.Column("占物理容量", nameof(AppRow.Share), 110); shareColumn.SortMemberPath = nameof(AppRow.PhysicalShare); table.Columns.Add(shareColumn);
        table.Columns.Add(Theme.Column("进程", nameof(AppRow.Count), 65));
        table.SelectionChanged += (_, _) => UpdateDetails();
        table.MouseDoubleClick += (_, _) => ShowProcesses();
        Grid.SetRow(table, 1); left.Children.Add(table); body.Children.Add(left);
        var detail = new StackPanel { Margin = new Thickness(20, 0, 0, 0) };
        foreach (var item in new UIElement[] { detailName, detailBytes, detailMetric, detailCommit, detailPath,
            Theme.Label("最近 5 分钟", 16), chart, trendCaption, Theme.Label("已包含的后台服务", 16), services, detailAdvice })
        {
            if (item is FrameworkElement el) el.Margin = new Thickness(0, 0, 0, 12);
            detail.Children.Add(item);
        }
        var actions = new WrapPanel(); actions.Children.Add(processButton); actions.Children.Add(closeButton); detail.Children.Add(actions);
        var scroll = new ScrollViewer { Content = detail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1); body.Children.Add(scroll); Grid.SetRow(body, 2); root.Children.Add(body);
        status.Margin = new Thickness(0, 18, 0, 0); Grid.SetRow(status, 3); root.Children.Add(status); return root;
    }

    private static StackPanel Card(string title, TextBlock number, TextBlock caption, Gauge? gauge = null)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 24, 0) };
        stack.Children.Add(Theme.Label(title, 17)); number.Margin = new Thickness(0, 14, 0, 8); stack.Children.Add(number);
        stack.Children.Add(caption);
        if (gauge != null) { gauge.Height = 14; gauge.Margin = new Thickness(0, 14, 0, 0); stack.Children.Add(gauge); }
        return stack;
    }

    private async Task Refresh()
    {
        if (sampling || closing) return;
        sampling = true; var watch = Stopwatch.StartNew();
        try
        {
            var next = await Task.Run(sampler.Read);
            if (closing) return;
            sample = next; history.Add(next); var s = next.System;
            physical.Text = Units.Bytes(s.PhysicalUsed); physicalCaption.Text = $"/ {Units.Bytes(s.PhysicalTotal)} · 已用 {s.PhysicalRatio:P1}\n可用 {Units.Bytes(s.PhysicalAvailable)}";
            commit.Text = Units.Bytes(s.CommitUsed); commitCaption.Text = $"/ {Units.Bytes(s.CommitLimit)} · {s.CommitRatio:P1}";
            pagefile.Text = Units.Bytes(s.PageFileUsed); pageCaption.Text = s.PageFileAllocated.HasValue
                ? $"/ {Units.Bytes(s.PageFileAllocated)} 已分配" : "读取受限或不可用";
            physicalGauge.Ratio = s.PhysicalRatio; commitGauge.Ratio = s.CommitRatio; headroom.Text = s.Headroom;
            status.Text = $"采样于 {s.Timestamp:HH:mm:ss} · {next.ProcessCount} 个进程 · {next.UnreadableCount} 项内存未读取 · 耗时 {watch.ElapsedMilliseconds} ms · 每 5 秒采样" +
                (next.AttributionWarning == null ? "" : " · " + next.AttributionWarning);
            status.Foreground = Theme.Secondary;
            tray.Text = $"内存守卫 · 已用 {s.PhysicalRatio:P0} · {s.Headroom}";
            ShowRows();
            foreach (var pair in processWindows.ToArray()) pair.Value.Update(next.Apps.FirstOrDefault(a => a.Key == pair.Key), s.Timestamp);
        }
        catch (Exception e)
        {
            if (!closing)
            {
                status.Text = $"采样失败（{e.GetType().Name}）" + (sample == null ? "；尚无有效数据" : $"；显示 {sample.System.Timestamp:HH:mm:ss} 的上次成功数据");
                status.Foreground = Theme.Brush("#E5B48A"); tray.Text = "内存守卫 · 采样失败";
            }
        }
        finally { sampling = false; }
    }

    private void ShowRows()
    {
        if (sample == null) return;
        string? key = (table.SelectedItem as AppRow)?.App.Key;
        var rows = sample.Apps.Where(a => a.Matches(search.Text.Trim())).Select(a => new AppRow(a, sample.System.PhysicalTotal)).ToArray();
        var sorts = table.Items.SortDescriptions.ToArray();
        table.ItemsSource = rows;
        foreach (var sort in sorts) table.Items.SortDescriptions.Add(sort);
        table.SelectedItem = rows.FirstOrDefault(r => r.App.Key == key) ?? table.Items.Cast<AppRow>().FirstOrDefault(); UpdateDetails();
    }

    private void UpdateDetails()
    {
        var app = (table.SelectedItem as AppRow)?.App;
        processButton.IsEnabled = app != null; closeButton.IsEnabled = app != null && ProcessActions.CanClose(app);
        if (app == null)
        {
            detailName.Text = "没有匹配的应用"; detailBytes.Text = "—"; detailMetric.Text = ""; detailCommit.Text = "";
            detailPath.Text = ""; services.Text = ""; detailAdvice.Text = ""; chart.Update(Array.Empty<MemoryPoint>()); trendCaption.Text = ""; return;
        }
        detailName.Text = app.Name; detailBytes.Text = app.Size; detailMetric.Text = $"{app.Metric} · {app.ProcessCount} 个进程";
        detailCommit.Text = $"私有提交量  {app.CommitSize}"; detailPath.Text = app.Location;
        services.Text = app.Services.Count == 0 ? "未识别到 Node 服务；不根据名称猜测用途。" :
            string.Join("\n", app.Services.Select(s => $"{s.Name}   {Units.Bytes(s.Bytes)} · {s.Count} 个进程"));
        int unresolved = app.Processes.Count(p => p.IsNode && p.Service == null);
        if (unresolved > 0) services.Text += $"\n{unresolved} 个 Node 入口未确认（相对路径或读取受限）。";
        var points = history.For(app); chart.Update(points);
        trendCaption.Text = points.Count == 0 ? "等待此指标的成功采样" : $"{points[0].Time:HH:mm:ss} — {points[^1].Time:HH:mm:ss} · {points.Count} 个真实采样点";
        detailAdvice.Text = app.Services.Count > 0
            ? "后台服务已包含在应用合计中。多份同名 MCP 可先检查是否需要全局常驻；不要直接结束不明 Node。"
            : sample != null && (sample.System.PhysicalRatio >= .8 || sample.System.CommitRatio >= .8) ? "可先保存工作，再关闭闲置窗口或浏览器标签。缓存通常由系统回收，无需主动清空。"
            : "当前余量允许继续工作，无需为提高空闲数字而清理缓存。";
    }

    private void RequestClose(object sender, RoutedEventArgs e)
    {
        var app = (table.SelectedItem as AppRow)?.App;
        if (app == null || !ProcessActions.CanClose(app)) return;
        if (MessageBox.Show(this, $"请求正常退出 {app.Name}（PID {app.Primary.Pid}）？\n请先保存工作。应用可能显示保存提示；不会强制终止其子进程。",
            "正常退出", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK)
            status.Text = ProcessActions.RequestClose(app);
    }

    private void ShowProcesses()
    {
        var app = (table.SelectedItem as AppRow)?.App; if (app == null || sample == null) return;
        if (processWindows.TryGetValue(app.Key, out var existing)) { existing.Activate(); return; }
        var window = new ProcessWindow(app, sample.System.Timestamp) { Owner = this };
        processWindows[app.Key] = window; window.Closed += (_, _) => processWindows.Remove(app.Key); window.Show();
    }

    private void Restore() { Show(); WindowState = WindowState.Normal; Activate(); }
}
