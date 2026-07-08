// Code-behind for the popover: fills the XAML layout from the live state
// (settings, controller, usage, Anthropic status) once per second while
// visible, and applies setting changes from its toggles. Mirrors
// MenuContentView in the macOS app's App.swift.

using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using FormsTimer = System.Windows.Forms.Timer;

namespace AgentCord;

public partial class PopoverWindow : Window
{
    private readonly Settings _settings;
    private readonly PresenceController _controller;
    private readonly ClaudeUsage _usage;
    private readonly AnthropicStatus _status;
    private readonly SleepGuard _sleepGuard;
    private readonly Action _quit;

    // A WinForms timer: it runs off the same message pump WinForms already
    // drives, so no WPF Dispatcher assumptions are needed.
    private readonly FormsTimer _timer = new() { Interval = 1000 };

    private readonly List<UsageRow> _usageRows = [];
    private StatusInfo? _renderedStatus;
    private bool _expandStatus;
    private DateTime _lastHidden = DateTime.MinValue;
    private bool _closing;
    private bool _offscreenCapture;

    /// <summary>Set once the window has actually taken focus. Show() can be
    /// followed by a Deactivated before activation ever lands (the message loop
    /// may not be pumping yet at startup), which would hide the popover the
    /// instant it opens. Only dismiss on a deactivation that follows a real
    /// activation.</summary>
    private bool _seenActivation;

    private static readonly int[] IdleSteps = [5, 10, 15, 20, 25, 30];

    // Palette (matches the macOS popover design spec).
    private static readonly Color TextColor = Rgb(0x1D, 0x1D, 0x1F);
    private static readonly Color Secondary = Rgb(0x3C, 0x3C, 0x43);
    private static readonly Color Track = Rgb(0x78, 0x78, 0x80);
    private static readonly Color Blue = Rgb(0x00, 0x7A, 0xFF);
    private static readonly Color Green = Rgb(0x34, 0xC7, 0x59);
    private static readonly Color GreenText = Rgb(0x1D, 0x8A, 0x3A);
    private static readonly Color Yellow = Rgb(0xE6, 0xB3, 0x00);
    private static readonly Color YellowText = Rgb(0x99, 0x73, 0x00);
    private static readonly Color Orange = Rgb(0xFF, 0x95, 0x00);
    private static readonly Color Red = Rgb(0xFF, 0x3B, 0x30);
    private static readonly Color Discord = Rgb(0x58, 0x65, 0xF2);

    public PopoverWindow(
        Settings settings, PresenceController controller, ClaudeUsage usage,
        AnthropicStatus status, SleepGuard sleepGuard, Action quit)
    {
        _settings = settings;
        _controller = controller;
        _usage = usage;
        _status = status;
        _sleepGuard = sleepGuard;
        _quit = quit;
        InitializeComponent();
        _timer.Tick += (_, _) => UpdateUi();
        Activated += (_, _) => _seenActivation = true;
    }

    // --- Show / hide

    /// <summary>Left-clicking the tray icon toggles the popover. Clicking it
    /// while open first deactivates (and hides) the window, so a short
    /// cooldown keeps that same click from instantly reopening it.</summary>
    public void TogglePopover()
    {
        if (IsVisible) HidePopover();
        else if ((DateTime.UtcNow - _lastHidden).TotalMilliseconds > 300) ShowPopover();
    }

    public void ShowPopover()
    {
        // Pull fresh usage numbers and Anthropic status as the popover opens
        // (throttled internally) so they're current.
        _usage.Refresh();
        _status.Refresh();
        ShowMainScreen();
        UpdateUi();
        _seenActivation = false;
        Show();
        UpdateLayout();
        Reposition();
        Activate();
        _timer.Start();
    }

    private void HidePopover()
    {
        _timer.Stop();
        _lastHidden = DateTime.UtcNow;
        Hide();
    }

    /// <summary>Really close the window (app quit); otherwise Closing is
    /// intercepted and turned into a hide.</summary>
    public void CloseForExit()
    {
        _closing = true;
        _timer.Dispose();
        Close();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (_seenActivation) HidePopover();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) HidePopover();
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_closing) return;
        e.Cancel = true;
        HidePopover();
    }

    /// <summary>Anchor the bottom-right corner near the tray, like the macOS
    /// popover hangs off its status item. Re-run on every size change so
    /// expanding a section grows the window upward.</summary>
    private void OnSizeChanged(object sender, SizeChangedEventArgs e) => Reposition();

    private void Reposition()
    {
        if (_offscreenCapture) return;
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 2;
        Top = area.Bottom - ActualHeight - 2;
    }

    /// <summary>Debug helper for the --screenshot mode: renders the popover
    /// off-screen (no focus steal, nothing visible) into PNG files — the main
    /// screen at <paramref name="path"/> and the settings screen next to it.</summary>
    public void CaptureForDebug(string path)
    {
        _offscreenCapture = true;
        ShowActivated = false;
        Left = -12000;
        Top = -12000;
        Show();

        ShowMainScreen();
        _expandStatus = true;
        StatusExpanded.Visibility = Visibility.Visible;
        RenderStatusDetails(_status.Current);
        UpdateUi();
        SavePng(path);

        MainScreen.Visibility = Visibility.Collapsed;
        SettingsScreen.Visibility = Visibility.Visible;
        DisplayExpanded.Visibility = Visibility.Visible;
        ActivityExpanded.Visibility = Visibility.Visible;
        SavePng(System.IO.Path.ChangeExtension(path, null) + "-settings.png");

        CloseForExit();
    }

    private void SavePng(string path)
    {
        UpdateLayout();
        var dpi = VisualTreeHelper.GetDpi(this);
        var bitmap = new RenderTargetBitmap(
            (int)Math.Ceiling(ActualWidth * dpi.DpiScaleX),
            (int)Math.Ceiling(ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    // --- Screens

    private void ShowMainScreen()
    {
        MainScreen.Visibility = Visibility.Visible;
        SettingsScreen.Visibility = Visibility.Collapsed;
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        MainScreen.Visibility = Visibility.Collapsed;
        SettingsScreen.Visibility = Visibility.Visible;
        UpdateUi();
    }

    private void OnCloseSettings(object sender, RoutedEventArgs e) => ShowMainScreen();

    private void OnQuit(object sender, RoutedEventArgs e) => _quit();

    // --- Settings handlers (Click only fires on user interaction, so
    // programmatic IsChecked updates in UpdateUi cannot loop back here.)

    private void OnPresenceSwitch(object sender, RoutedEventArgs e)
    {
        _controller.SetEnabled(PresenceSwitch.IsChecked == true);
        UpdateUi();
    }

    private void OnAutostartSwitch(object sender, RoutedEventArgs e)
    {
        if (!Autostart.SetEnabled(AutostartSwitch.IsChecked == true))
            AutostartSwitch.IsChecked = Autostart.IsEnabled();
    }

    private void OnPreventSleepSwitch(object sender, RoutedEventArgs e)
    {
        _settings.PreventSleep = PreventSleepSwitch.IsChecked == true;
        _settings.Save();
        _sleepGuard.SetEnabled(_settings.PreventSleep);
    }

    private void OnShowProjectSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowProject = v, ShowProjectSwitch);

    private void OnShowModelSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowModel = v, ShowModelSwitch);

    private void OnShowTokensSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowTokens = v, ShowTokensSwitch);

    private void SaveDisplayToggle(Action<bool> apply, ToggleButton toggle)
    {
        apply(toggle.IsChecked == true);
        _settings.Save();
        UpdateUi();
    }

    private void OnCycleActivity(object sender, RoutedEventArgs e)
    {
        var types = Settings.ActivityTypes;
        var idx = Array.FindIndex(types, t => t.Value == _settings.ActivityType);
        _settings.ActivityType = types[(idx + 1 + types.Length) % types.Length].Value;
        _settings.Save();
        UpdateUi();
    }

    private void OnIdleChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        var seconds = IdleSteps[(int)Math.Round(IdleSlider.Value)] * 60.0;
        if (Math.Abs(seconds - _settings.IdleWindowSeconds) < 1) return;
        _settings.IdleWindowSeconds = seconds;
        _settings.Save();
        UpdateUi();
    }

    private void OnToggleStatus(object sender, RoutedEventArgs e)
    {
        _expandStatus = !_expandStatus;
        StatusExpanded.Visibility = _expandStatus ? Visibility.Visible : Visibility.Collapsed;
        StatusChevron.Text = _expandStatus ? "" : "";
        if (_expandStatus) RenderStatusDetails(_status.Current);
    }

    private void OnToggleDisplay(object sender, RoutedEventArgs e) =>
        ToggleSection(DisplayExpanded, DisplayChevron);

    private void OnToggleActivity(object sender, RoutedEventArgs e) =>
        ToggleSection(ActivityExpanded, ActivityChevron);

    private static void ToggleSection(UIElement panel, TextBlock chevron)
    {
        var expand = panel.Visibility != Visibility.Visible;
        panel.Visibility = expand ? Visibility.Visible : Visibility.Collapsed;
        chevron.Text = expand ? "" : "";
    }

    private void OnOpenStatusPage(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(AnthropicStatus.PageUrl) { UseShellExecute = true }); }
        catch { }
    }

    // --- Rendering

    private void UpdateUi()
    {
        var session = _controller.CurrentSession;
        var hasSession = session is not null;
        var presenceOn = _settings.PresenceEnabled;
        var active = hasSession && presenceOn;

        // Connection pill.
        if (!presenceOn)
            SetPill(StatusPill, StatusPillDot, StatusPillText, Track, WithAlpha(Secondary, 0xB3), "Off");
        else if (_controller.DiscordState == DiscordIpc.ConnState.Connected)
            SetPill(StatusPill, StatusPillDot, StatusPillText, Green, GreenText, "Connected");
        else
            SetPill(StatusPill, StatusPillDot, StatusPillText, Yellow, YellowText, "Connecting");

        // Active session card.
        SessionDot.Fill = Brush(active ? Green : WithAlpha(Track, 0xB3));
        ElapsedText.Text = session is null ? "—" : Format.Clock(Format.NowMs() - session.StartEpochMs);
        ElapsedText.Foreground = Brush(active ? TextColor : WithAlpha(Secondary, 0x73));

        var showProject = hasSession && _settings.ShowProject;
        ProjectText.Text = session is null ? "No active session"
            : _settings.ShowProject ? session.ProjectName : "Project hidden";
        ProjectText.FontStyle = showProject ? FontStyles.Normal : FontStyles.Italic;
        ProjectText.Foreground = Brush(active && showProject ? TextColor : WithAlpha(Secondary, 0x73));

        var bits = new List<string>();
        if (session is not null)
        {
            if (_settings.ShowModel && session.Model is not null) bits.Add(session.Model);
            if (_settings.ShowTokens && session.TotalTokens > 0)
                bits.Add($"{PresenceController.FormatTokens(session.TotalTokens)} tokens");
        }
        MetaText.Text = bits.Count > 0 ? string.Join("  ·  ", bits)
            : session is null ? "Waiting for a session" : "Model & tokens hidden";
        MetaText.FontStyle = bits.Count > 0 ? FontStyles.Normal : FontStyles.Italic;
        MetaText.Foreground = Brush(WithAlpha(Secondary, active && bits.Count > 0 ? (byte)0xB3 : (byte)0x66));

        BroadcastDot.Fill = Brush(active ? Discord : WithAlpha(Track, 0x99));
        BroadcastText.Text = !presenceOn ? "Presence is off"
            : hasSession ? "Sharing to Discord as your status" : "Waiting for a session";

        // Usage card.
        RenderUsage(_usage.Current);
        ErrorText.Text = _controller.LastError ?? "";
        ErrorText.Visibility = _controller.LastError is null ? Visibility.Collapsed : Visibility.Visible;

        // Claude status card: hidden entirely until the first successful fetch.
        var status = _status.Current;
        StatusCard.Visibility = status is null ? Visibility.Collapsed : Visibility.Visible;
        if (status is not null)
        {
            var (accent, textColor) = StatusPillColors(status.Indicator);
            SetPill(ClaudePill, ClaudePillDot, ClaudePillText, accent, textColor, status.SummaryLabel);
            if (_expandStatus && !ReferenceEquals(status, _renderedStatus)) RenderStatusDetails(status);
            if (_expandStatus) StatusFooterText.Text = StatusFooter(status);
        }

        SettingsSummary.Text = presenceOn ? "Presence on" : "Presence off";

        // Settings screen.
        PresenceSwitch.IsChecked = presenceOn;
        AutostartSwitch.IsChecked = Autostart.IsEnabled();
        PreventSleepSwitch.IsChecked = _settings.PreventSleep;
        ShowProjectSwitch.IsChecked = _settings.ShowProject;
        ShowModelSwitch.IsChecked = _settings.ShowModel;
        ShowTokensSwitch.IsChecked = _settings.ShowTokens;

        var displayCount = new[] { _settings.ShowProject, _settings.ShowModel, _settings.ShowTokens }.Count(v => v);
        DisplaySummary.Text = $"{displayCount} on";

        var idleMinutes = (int)Math.Round(_settings.IdleWindowSeconds / 60.0);
        var idleIndex = Array.IndexOf(IdleSteps, idleMinutes);
        if (idleIndex >= 0 && (int)Math.Round(IdleSlider.Value) != idleIndex) IdleSlider.Value = idleIndex;
        IdleValue.Text = $"{idleMinutes} min";
        ActivityLabel.Text = Settings.ActivityLabel(_settings.ActivityType);
        ActivitySummary.Text = $"{ActivityLabel.Text} · {idleMinutes} min";
    }

    private void RenderUsage(UsageInfo? usage)
    {
        var wanted = 2 + (usage?.ModelWeekly.Count ?? 0);
        if (_usageRows.Count != wanted)
        {
            _usageRows.Clear();
            UsageRows.Children.Clear();
            for (var i = 0; i < wanted; i++)
            {
                var row = new UsageRow();
                _usageRows.Add(row);
                UsageRows.Children.Add(row.Root);
            }
        }

        _usageRows[0].Update("Current session", usage?.FiveHour, resetAsDate: false);
        _usageRows[1].Update("All models", usage?.Weekly, resetAsDate: true);
        for (var i = 0; i < (usage?.ModelWeekly.Count ?? 0); i++)
            _usageRows[2 + i].Update(usage!.ModelWeekly[i].ModelName, usage.ModelWeekly[i].Window, resetAsDate: true);
    }

    private void RenderStatusDetails(StatusInfo? status)
    {
        _renderedStatus = status;
        IncidentsPanel.Children.Clear();
        ComponentsPanel.Children.Clear();
        if (status is null) return;

        foreach (var incident in status.Incidents)
            IncidentsPanel.Children.Add(IncidentCallout(incident));

        foreach (var component in status.Components)
            ComponentsPanel.Children.Add(ComponentRow(component));

        StatusFooterText.Text = StatusFooter(status);
    }

    private static string StatusFooter(StatusInfo status)
    {
        var updated = $"updated {Format.Ago(status.FetchedAtMs)}";
        return status.DegradedCount > 0
            ? $"{status.DegradedCount} of {status.Components.Count} degraded · {updated}"
            : $"All systems operational · {updated}";
    }

    /// <summary>An active incident, tinted by its impact.</summary>
    private static UIElement IncidentCallout(StatusIncident incident)
    {
        var tint = incident.Impact switch
        {
            "critical" => Red,
            "minor" => Yellow,
            "maintenance" => Blue,
            _ => Orange, // "major" and anything else
        };

        var meta = char.ToUpperInvariant(incident.Status[0]) + incident.Status[1..];
        if (incident.StartedAtMs is long started)
            meta = $"{meta} · started {Format.Since(started)} ago";

        var text = new StackPanel();
        text.Children.Add(new TextBlock
        {
            Text = incident.Name,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
        });
        text.Children.Add(new TextBlock
        {
            Text = meta,
            FontSize = 11,
            Foreground = Brush(WithAlpha(Secondary, 0x8C)),
            Margin = new Thickness(0, 2, 0, 0),
        });

        var layout = new DockPanel();
        var dot = new Ellipse
        {
            Width = 6, Height = 6, Fill = Brush(tint),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 4, 8, 0),
        };
        DockPanel.SetDock(dot, Dock.Left);
        layout.Children.Add(dot);
        layout.Children.Add(text);

        return new Border
        {
            Background = Brush(WithAlpha(tint, 0x14)),
            BorderBrush = Brush(WithAlpha(tint, 0x33)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(9, 8, 9, 8),
            Margin = new Thickness(0, 0, 0, 9),
            Child = layout,
        };
    }

    /// <summary>One row of the per-component breakdown.</summary>
    private static UIElement ComponentRow(StatusComponent component)
    {
        var (color, label) = component.Status switch
        {
            "operational" => (Green, "Operational"),
            "degraded_performance" => (Orange, "Degraded"),
            "partial_outage" => (Orange, "Partial Outage"),
            "major_outage" => (Red, "Major Outage"),
            "under_maintenance" => (Blue, "Maintenance"),
            _ => (Track, "Unknown"),
        };

        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(new Ellipse
        {
            Width = 6, Height = 6, Fill = Brush(color),
            VerticalAlignment = VerticalAlignment.Center,
        });
        right.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 11.5,
            FontWeight = FontWeights.Medium,
            Foreground = Brush(color),
            Margin = new Thickness(5, 0, 0, 0),
        });
        DockPanel.SetDock(right, Dock.Right);

        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };
        row.Children.Add(right);
        row.Children.Add(new TextBlock
        {
            Text = component.Name,
            FontSize = 12.5,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        return row;
    }

    private static (Color Accent, Color Text) StatusPillColors(string indicator) => indicator switch
    {
        "none" => (Green, GreenText),
        "minor" or "major" => (Orange, Rgb(0xC2, 0x66, 0x0A)),
        "critical" => (Red, Rgb(0xC0, 0x27, 0x1F)),
        "maintenance" => (Blue, Rgb(0x00, 0x57, 0xB6)),
        _ => (Track, WithAlpha(Secondary, 0xB3)),
    };

    // --- Small UI helpers

    /// <summary>A colored capsule: tinted background, stronger border, dot, label.</summary>
    private static void SetPill(Border pill, Ellipse dot, TextBlock text, Color accent, Color textColor, string label)
    {
        pill.Background = Brush(WithAlpha(accent, 0x1F));
        pill.BorderBrush = Brush(WithAlpha(accent, 0x47));
        dot.Fill = Brush(accent);
        text.Foreground = Brush(textColor);
        text.Text = label;
    }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
    private static Color WithAlpha(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);

    private static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    /// <summary>One usage row: label + "46% · resets …" + a colored progress
    /// bar. The fill fraction is expressed with star-sized grid columns so no
    /// manual width math is needed.</summary>
    private sealed class UsageRow
    {
        public readonly StackPanel Root = new() { Margin = new Thickness(0, 0, 0, 10) };
        private readonly TextBlock _label = new() { FontSize = 12.5 };
        private readonly TextBlock _value = new() { FontSize = 12.5, FontWeight = FontWeights.SemiBold };
        private readonly ColumnDefinition _fillCol = new();
        private readonly ColumnDefinition _restCol = new();
        private readonly Border _fill = new() { CornerRadius = new CornerRadius(3) };

        public UsageRow()
        {
            // Tabular figures keep the percentages from jittering as they tick.
            Typography.SetNumeralAlignment(_value, FontNumeralAlignment.Tabular);
            DockPanel.SetDock(_value, Dock.Right);
            var top = new DockPanel();
            top.Children.Add(_value);
            top.Children.Add(_label);

            var bar = new Grid();
            bar.ColumnDefinitions.Add(_fillCol);
            bar.ColumnDefinitions.Add(_restCol);
            Grid.SetColumn(_fill, 0);
            bar.Children.Add(_fill);

            var track = new Border
            {
                Height = 6,
                CornerRadius = new CornerRadius(3),
                Background = Brush(WithAlpha(Track, 0x29)),
                Margin = new Thickness(0, 5, 0, 0),
                Child = bar,
            };

            Root.Children.Add(top);
            Root.Children.Add(track);
        }

        public void Update(string label, UsageWindow? window, bool resetAsDate)
        {
            _label.Text = label;
            if (window is null)
            {
                _value.Text = "—";
            }
            else
            {
                var reset = window.ResetsAtMs is long ms
                    ? $" · resets {(resetAsDate ? Format.ResetDate(ms) : Format.ResetTime(ms))}"
                    : "";
                _value.Text = $"{window.Percent}%{reset}";
            }

            // Keep a faint sliver visible even at 0% so the track reads as a bar.
            var fraction = Math.Clamp((window?.Percent ?? 0) / 100.0, 0.015, 1.0);
            _fillCol.Width = new GridLength(fraction, GridUnitType.Star);
            _restCol.Width = new GridLength(1 - fraction, GridUnitType.Star);

            var severity = window?.Severity.ToLowerInvariant() ?? "normal";
            _fill.Background = Brush(severity switch
            {
                "normal" => Blue,
                "warning" or "warn" or "low" => Orange,
                _ => Red,
            });
        }
    }
}
