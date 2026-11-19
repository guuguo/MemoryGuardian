using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MemoryGuardian.Core;

namespace MemoryGuardian.Windows;

internal static class Theme
{
    internal static readonly Brush Background = Brush("#181A1C"), Surface = Brush("#222628"),
        Text = Brush("#ECEDE9"), Secondary = Brush("#999FA7"), Mint = Brush("#A6D8C3"),
        Blue = Brush("#829EB9"), Line = Brush("#383C3E");
    internal static Brush Brush(string color)
    { var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); b.Freeze(); return b; }
    internal static TextBlock Label(string text, double size = 14, Brush? color = null) =>
        new() { Text = text, FontSize = size, Foreground = color ?? Text, TextWrapping = TextWrapping.Wrap };
    internal static Button Button(string label, RoutedEventHandler click)
    {
        var b = new Button { Content = label, MinHeight = 32, Padding = new Thickness(14, 5, 14, 5),
            Background = Surface, Foreground = Text, BorderBrush = Line, BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 0, 8, 0), FocusVisualStyle = null, Cursor = System.Windows.Input.Cursors.Hand };
        var border = new FrameworkElementFactory(typeof(Border), "frame");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        foreach (var pair in new[] { (Border.BackgroundProperty, "Background"), (Border.BorderBrushProperty, "BorderBrush"),
            (Border.BorderThicknessProperty, "BorderThickness") })
            border.SetBinding(pair.Item1, new System.Windows.Data.Binding(pair.Item2) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        content.SetBinding(FrameworkElement.MarginProperty, new System.Windows.Data.Binding("Padding") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Brush("#303836"), "frame")); template.Triggers.Add(hover);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, .45)); template.Triggers.Add(disabled);
        b.Template = template;
        b.Click += click; return b;
    }
    internal static void StyleGrid(DataGrid grid)
    {
        grid.Background = Background; grid.Foreground = Text; grid.RowBackground = Background;
        grid.AlternatingRowBackground = Brush("#1D2022"); grid.BorderThickness = new Thickness(0);
        grid.HorizontalGridLinesBrush = Line; grid.GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
        grid.AutoGenerateColumns = false; grid.IsReadOnly = true; grid.CanUserAddRows = false;
        grid.CanUserDeleteRows = false; grid.CanUserReorderColumns = false;
        grid.HeadersVisibility = DataGridHeadersVisibility.Column; grid.RowHeight = 48;
        grid.SelectionMode = DataGridSelectionMode.Single; grid.SelectionUnit = DataGridSelectionUnit.FullRow;
        grid.EnableRowVirtualization = true; grid.EnableColumnVirtualization = true;
        VirtualizingPanel.SetVirtualizationMode(grid, VirtualizationMode.Recycling);
        ScrollViewer.SetCanContentScroll(grid, true);
        var header = new Style(typeof(System.Windows.Controls.Primitives.DataGridColumnHeader));
        header.Setters.Add(new Setter(Control.BackgroundProperty, Background));
        header.Setters.Add(new Setter(Control.ForegroundProperty, Secondary));
        header.Setters.Add(new Setter(Control.BorderBrushProperty, Line));
        header.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 12, 10, 12)));
        grid.ColumnHeaderStyle = header;
        var row = new Style(typeof(DataGridRow));
        var selected = new Trigger { Property = DataGridRow.IsSelectedProperty, Value = true };
        selected.Setters.Add(new Setter(Control.BackgroundProperty, Brush("#2B3934")));
        selected.Setters.Add(new Setter(Control.ForegroundProperty, Text)); row.Triggers.Add(selected);
        row.Setters.Add(new Setter(Control.FocusVisualStyleProperty, null)); grid.RowStyle = row;
        var cell = new Style(typeof(DataGridCell));
        cell.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0)));
        cell.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 8, 10, 8)));
        cell.Setters.Add(new Setter(Control.FocusVisualStyleProperty, null));
        var chosen = new Trigger { Property = DataGridCell.IsSelectedProperty, Value = true };
        chosen.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Transparent));
        chosen.Setters.Add(new Setter(Control.ForegroundProperty, Text)); cell.Triggers.Add(chosen);
        grid.CellStyle = cell;
    }
    internal static DataGridTextColumn Column(string label, string property, double width) => new()
    {
        Header = label, Binding = new System.Windows.Data.Binding(property),
        Width = width == 0 ? new DataGridLength(1, DataGridLengthUnitType.Star) : new DataGridLength(width)
    };
}

internal sealed class Gauge : FrameworkElement
{
    private double ratio;
    internal Brush Fill { get; set; } = Theme.Mint;
    internal double Ratio { get => ratio; set { ratio = Math.Clamp(value, 0, 1); InvalidateVisual(); } }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        dc.DrawRoundedRectangle(Theme.Surface, null, new Rect(0, 0, ActualWidth, 9), 4, 4);
        if (ratio > 0) dc.DrawRoundedRectangle(Fill, null, new Rect(0, 0, ActualWidth * ratio, 9), 4, 4);
    }
}

internal sealed class Trend : FrameworkElement
{
    private IReadOnlyList<MemoryPoint> points = Array.Empty<MemoryPoint>();
    internal void Update(IReadOnlyList<MemoryPoint> values) { points = values.ToArray(); InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        double w = ActualWidth, h = ActualHeight;
        if (w < 1 || h < 1) return;
        var line = new Pen(Theme.Line, 1);
        dc.DrawLine(line, new Point(0, 8), new Point(w, 8));
        dc.DrawLine(line, new Point(0, h - 8), new Point(w, h - 8));
        if (points.Count == 0) return;
        double max = Math.Max(1, points.Max(p => (double)p.Bytes) * 1.08);
        double duration = Math.Max(1, (points[^1].Time - points[0].Time).TotalSeconds);
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
            for (int i = 0; i < points.Count; i++)
            {
                var p = new Point((points[i].Time - points[0].Time).TotalSeconds / duration * w,
                    h - 8 - points[i].Bytes / max * (h - 16));
                if (i == 0) ctx.BeginFigure(p, false, false); else ctx.LineTo(p, true, false);
                if (points.Count == 1) dc.DrawEllipse(Theme.Mint, null, p, 2, 2);
            }
        geometry.Freeze(); dc.DrawGeometry(null, new Pen(Theme.Mint, 1.6), geometry);
    }
}
