// Code-behind for the popover: fills the XAML layout from the live state
// (settings, controller, usage, Anthropic status) once per second while
// visible, and applies setting changes from its toggles. Mirrors
// MenuContentView in the macOS app's App.swift — accordion agent list plus
// optional unified usage card.

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
    private readonly CodexUsage _codexUsage;
    private readonly CursorUsage _cursorUsage;
    private readonly AntigravityUsage _antigravityUsage;
    private readonly GrokUsage _grokUsage;
    private readonly AnthropicStatus _status;
    private readonly SleepGuard _sleepGuard;
    private readonly Action _quit;
    private readonly Action? _syncPollers;

    // A WinForms timer: it runs off the same message pump WinForms already
    // drives, so no WPF Dispatcher assumptions are needed.
    private readonly FormsTimer _timer = new() { Interval = 1000 };

    private readonly List<UsageRow> _unifiedRows = [];
    private readonly Dictionary<AgentKind, AgentRow> _agentRows = new();
    private readonly HashSet<AgentKind> _revealedEmails = [];
    private AgentKind? _expandedAgent;
    private bool _seededExpanded;
    private StatusInfo? _renderedStatus;
    private bool _expandStatus;
    private bool _closing;
    private bool _offscreenCapture;
    /// <summary>Stay pinned to the tray corner until the user actually moves the window.</summary>
    private bool _anchored = true;
    /// <summary>A tray click deactivates this window before NotifyIcon.MouseUp,
    /// so IsActive is already false. A recent Deactivated still means "was focused".</summary>
    private DateTime _lastDeactivated = DateTime.MinValue;

    private static readonly int[] IdleSteps = [0, 5, 10, 15, 20, 25, 30];

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
        Settings settings, PresenceController controller, ClaudeUsage usage, CodexUsage codexUsage,
        CursorUsage cursorUsage, AntigravityUsage antigravityUsage, GrokUsage grokUsage,
        AnthropicStatus status, SleepGuard sleepGuard, Action quit, Action? syncPollers = null)
    {
        _settings = settings;
        _controller = controller;
        _usage = usage;
        _codexUsage = codexUsage;
        _cursorUsage = cursorUsage;
        _antigravityUsage = antigravityUsage;
        _grokUsage = grokUsage;
        _status = status;
        _sleepGuard = sleepGuard;
        _quit = quit;
        _syncPollers = syncPollers;
        InitializeComponent();
        _timer.Tick += (_, _) => UpdateUi();
        MouseLeftButtonDown += OnDragMove;
        Deactivated += (_, _) => _lastDeactivated = DateTime.UtcNow;
    }

    // --- Show / hide

    /// <summary>Tray click shows the window, focuses it if it's already open
    /// in the background, or hides it when it was focused (including the
    /// deactivate that the tray click itself causes).</summary>
    public void TogglePopover()
    {
        if (!IsVisible) ShowPopover();
        else if (IsActive || (DateTime.UtcNow - _lastDeactivated).TotalMilliseconds < 300)
            HidePopover();
        else Activate();
    }

    public void ShowPopover()
    {
        // Pull fresh usage numbers and Anthropic status as the popover opens
        // (throttled internally) so they're current.
        _usage.Refresh();
        _codexUsage.Refresh();
        _cursorUsage.Refresh();
        _antigravityUsage.Refresh();
        _grokUsage.Refresh();
        _status.Refresh();
        ShowMainScreen();
        UpdateUi();
        Show();
        UpdateLayout();
        if (_anchored) Reposition();
        Activate();
        _timer.Start();
    }

    private void HidePopover()
    {
        _timer.Stop();
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

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) HidePopover();
    }

    private void OnDragMove(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        var left = Left;
        var top = Top;
        DragMove();
        if (Math.Abs(Left - left) > 1 || Math.Abs(Top - top) > 1)
            _anchored = false;
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_closing) return;
        e.Cancel = true;
        HidePopover();
    }

    /// <summary>Keep the bottom-right corner near the tray until the user
    /// moves the window. Re-run on size changes so expanding a section grows
    /// upward instead of off the work area.</summary>
    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_anchored) Reposition();
    }

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
        _expandedAgent = AgentKind.Claude;
        _settings.SelectedAgent = AgentKind.Claude;
        _expandStatus = true;
        UpdateUi();
        if (_agentRows.TryGetValue(AgentKind.Claude, out var claudeRow))
            claudeRow.SetStatusExpanded(true);
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

    private void OnShowUnifiedUsageSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.UnifiedUsage = v, ShowUnifiedUsageSwitch);

    private void OnShowProjectSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowProject = v, ShowProjectSwitch);

    private void OnShowModelSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowModel = v, ShowModelSwitch);

    private void OnShowTokensSwitch(object sender, RoutedEventArgs e) =>
        SaveDisplayToggle(v => _settings.ShowTokens = v, ShowTokensSwitch);

    private void OnClaudeAgentSwitch(object sender, RoutedEventArgs e) =>
        SaveAgentToggle(AgentKind.Claude, ClaudeAgentSwitch);

    private void OnCodexAgentSwitch(object sender, RoutedEventArgs e) =>
        SaveAgentToggle(AgentKind.Codex, CodexAgentSwitch);

    private void OnCursorAgentSwitch(object sender, RoutedEventArgs e) =>
        SaveAgentToggle(AgentKind.Cursor, CursorAgentSwitch);

    private void OnAntigravityAgentSwitch(object sender, RoutedEventArgs e) =>
        SaveAgentToggle(AgentKind.Antigravity, AntigravityAgentSwitch);

    private void OnGrokAgentSwitch(object sender, RoutedEventArgs e) =>
        SaveAgentToggle(AgentKind.Grok, GrokAgentSwitch);

    private void SaveAgentToggle(AgentKind agent, ToggleButton toggle)
    {
        _settings.SetAgentEnabled(agent, toggle.IsChecked == true);
        _settings.Save();
        _syncPollers?.Invoke();
        if (_expandedAgent is AgentKind expanded && !_settings.IsAgentEnabled(expanded))
            _expandedAgent = _settings.SelectedAgent;
        UpdateUi();
    }

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

    private void ToggleExpanded(AgentKind agent)
    {
        if (_expandedAgent == agent)
        {
            _expandedAgent = null;
            _expandStatus = false;
            _revealedEmails.Remove(agent);
        }
        else
        {
            if (_expandedAgent is AgentKind previous)
                _revealedEmails.Remove(previous);
            if (_expandedAgent != agent) _expandStatus = false;
            _expandedAgent = agent;
            _settings.SelectedAgent = agent;
            _settings.Save();
        }
        UpdateUi();
    }

    // --- Rendering

    private void UpdateUi()
    {
        var enabled = _settings.EnabledAgents;
        EnsureAgentRows(enabled);
        SeedExpandedAgent(enabled);

        var presenceOn = _settings.PresenceEnabled;
        var activeCount = enabled.Count(a => _controller.SessionFor(a) is not null);

        // Connection / multi-agent status pill.
        if (enabled.Count > 1)
        {
            if (!presenceOn)
                SetPill(StatusPill, StatusPillDot, StatusPillText, Track, WithAlpha(Secondary, 0xB3), "Off");
            else if (activeCount > 0)
                SetPill(StatusPill, StatusPillDot, StatusPillText, Green, GreenText,
                    activeCount == 1 ? "1 active" : $"{activeCount} active");
            else
                SetPill(StatusPill, StatusPillDot, StatusPillText, Yellow, YellowText, "0 active");
        }
        else if (!presenceOn)
            SetPill(StatusPill, StatusPillDot, StatusPillText, Track, WithAlpha(Secondary, 0xB3), "Off");
        else if (_controller.DiscordState == DiscordIpc.ConnState.Connected)
            SetPill(StatusPill, StatusPillDot, StatusPillText, Green, GreenText, "Connected");
        else
            SetPill(StatusPill, StatusPillDot, StatusPillText, Yellow, YellowText, "Connecting");

        RenderUnifiedUsage(enabled);

        foreach (var agent in enabled)
        {
            if (!_agentRows.TryGetValue(agent, out var row)) continue;
            var session = _controller.SessionFor(agent);
            var linked = IsAgentLinked(agent);
            var expanded = _expandedAgent == agent;
            var sharing = session is not null && presenceOn
                && _controller.CurrentSession?.Agent == agent;
            row.UpdateHeader(agent, linked, session, expanded, _settings.ShowProject);
            if (expanded)
            {
                row.UpdateDetail(agent, session, presenceOn, sharing, _settings,
                    AccountEmail(agent), PlanName(agent),
                    _revealedEmails.Contains(agent),
                    () =>
                    {
                        if (!_revealedEmails.Add(agent))
                            _revealedEmails.Remove(agent);
                        UpdateUi();
                    },
                    UsageRowsFor(agent),
                    agent == AgentKind.Claude ? _controller.LastError : null,
                    agent == AgentKind.Claude ? _status.Current : null,
                    _expandStatus,
                    () =>
                    {
                        _expandStatus = !_expandStatus;
                        UpdateUi();
                    },
                    OnOpenStatusPage);
                if (_expandStatus && agent == AgentKind.Claude
                    && !ReferenceEquals(_status.Current, _renderedStatus))
                {
                    row.RenderStatusDetails(_status.Current);
                    _renderedStatus = _status.Current;
                }
            }
            else
            {
                row.CollapseDetail();
            }
        }

        var enabledCount = enabled.Count;
        SettingsSummary.Text = enabledCount == 1 ? "1 agent on" : $"{enabledCount} agents on";

        // Settings screen.
        PresenceSwitch.IsChecked = presenceOn;
        AutostartSwitch.IsChecked = Autostart.IsEnabled();
        PreventSleepSwitch.IsChecked = _settings.PreventSleep;
        ShowUnifiedUsageSwitch.IsChecked = _settings.UnifiedUsage;
        ShowProjectSwitch.IsChecked = _settings.ShowProject;
        ShowModelSwitch.IsChecked = _settings.ShowModel;
        ShowTokensSwitch.IsChecked = _settings.ShowTokens;
        ClaudeAgentSwitch.IsChecked = _settings.AgentClaudeEnabled;
        CodexAgentSwitch.IsChecked = _settings.AgentCodexEnabled;
        CursorAgentSwitch.IsChecked = _settings.AgentCursorEnabled;
        GrokAgentSwitch.IsChecked = _settings.AgentGrokEnabled;
        AntigravityAgentSwitch.IsChecked = _settings.AgentAntigravityEnabled;

        var displayCount = new[]
        {
            _settings.UnifiedUsage, _settings.ShowProject, _settings.ShowModel, _settings.ShowTokens,
        }.Count(v => v);
        DisplaySummary.Text = $"{displayCount} on";

        var idleMinutes = (int)Math.Round(_settings.IdleWindowSeconds / 60.0);
        var idleIndex = Array.IndexOf(IdleSteps, idleMinutes);
        if (idleIndex >= 0 && (int)Math.Round(IdleSlider.Value) != idleIndex) IdleSlider.Value = idleIndex;
        IdleValue.Text = $"{idleMinutes} min";
        ActivityLabel.Text = Settings.ActivityLabel(_settings.ActivityType);
        ActivitySummary.Text = $"{ActivityLabel.Text} · {idleMinutes} min";
    }

    private void SeedExpandedAgent(IReadOnlyList<AgentKind> enabled)
    {
        if (_seededExpanded) return;
        _seededExpanded = true;
        if (_expandedAgent is null && enabled.Contains(_settings.SelectedAgent))
            _expandedAgent = _settings.SelectedAgent;
        else if (_expandedAgent is null && enabled.Count > 0)
            _expandedAgent = enabled[0];
    }

    private void EnsureAgentRows(IReadOnlyList<AgentKind> enabled)
    {
        var wanted = enabled.ToHashSet();
        var stale = _agentRows.Keys.Where(a => !wanted.Contains(a)).ToList();
        foreach (var agent in stale)
        {
            AgentListPanel.Children.Remove(_agentRows[agent].Root);
            _agentRows.Remove(agent);
        }

        // Rebuild order when the enabled set or order changed.
        var currentOrder = AgentListPanel.Children
            .OfType<FrameworkElement>()
            .Select(e => e.Tag)
            .OfType<AgentKind>()
            .ToList();
        if (currentOrder.SequenceEqual(enabled) && _agentRows.Count == enabled.Count)
            return;

        AgentListPanel.Children.Clear();
        for (var i = 0; i < enabled.Count; i++)
        {
            var agent = enabled[i];
            if (!_agentRows.TryGetValue(agent, out var row))
            {
                row = new AgentRow(agent, () => ToggleExpanded(agent));
                _agentRows[agent] = row;
            }
            row.SetDivider(i > 0);
            AgentListPanel.Children.Add(row.Root);
        }
    }

    private void RenderUnifiedUsage(IReadOnlyList<AgentKind> enabled)
    {
        var show = _settings.UnifiedUsage && enabled.Count > 1;
        UnifiedUsageCard.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (!show) return;

        var linked = enabled.Where(IsAgentLinked).ToList();
        UnifiedUsageEmpty.Visibility = linked.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UnifiedUsageRows.Visibility = linked.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (linked.Count == 0)
        {
            _unifiedRows.Clear();
            UnifiedUsageRows.Children.Clear();
            return;
        }

        EnsureUsageRows(_unifiedRows, UnifiedUsageRows, linked.Count);
        for (var i = 0; i < linked.Count; i++)
        {
            var agent = linked[i];
            var live = _controller.SessionFor(agent) is not null;
            var window = UnifiedWindow(agent);
            _unifiedRows[i].Update(agent.DisplayName(), window, live ? 1.0 : 0.55);
        }
    }

    private UsageWindow? UnifiedWindow(AgentKind agent) => agent switch
    {
        AgentKind.Codex => _codexUsage.Current?.Primary,
        AgentKind.Cursor => _cursorUsage.Current?.Included,
        AgentKind.Antigravity => _antigravityUsage.Current?.FiveHour,
        AgentKind.Grok => _grokUsage.Current?.Weekly,
        _ => _usage.Current?.FiveHour,
    };

    /// <summary>Linked when usage data, auth, or a live session exists.</summary>
    private bool IsAgentLinked(AgentKind agent) => agent switch
    {
        AgentKind.Codex => _codexUsage.IsAuthenticated || _codexUsage.Current is not null
            || _controller.SessionFor(agent) is not null,
        AgentKind.Cursor => _cursorUsage.IsAuthenticated || _cursorUsage.Current is not null
            || _controller.SessionFor(agent) is not null,
        AgentKind.Antigravity => _antigravityUsage.Current is not null
            || _antigravityUsage.AccountEmail is not null
            || _controller.AntigravityAccountEmail is not null
            || AntigravitySession.IsInstalled() || _controller.SessionFor(agent) is not null,
        AgentKind.Grok => _grokUsage.IsAuthenticated || _grokUsage.Current is not null
            || _controller.GrokAuthenticated || _controller.SessionFor(agent) is not null,
        _ => _usage.AccountEmail is not null || _usage.Current is not null
            || _controller.SessionFor(agent) is not null,
    };

    private string? AccountEmail(AgentKind agent) => agent switch
    {
        AgentKind.Codex => _codexUsage.AccountEmail,
        AgentKind.Cursor => _cursorUsage.AccountEmail,
        AgentKind.Antigravity => _antigravityUsage.AccountEmail ?? _controller.AntigravityAccountEmail,
        AgentKind.Grok => _grokUsage.AccountEmail,
        _ => _usage.AccountEmail,
    };

    private string? PlanName(AgentKind agent) => agent switch
    {
        AgentKind.Codex => _codexUsage.Current?.PlanType,
        AgentKind.Cursor => _cursorUsage.Current?.PlanName,
        AgentKind.Antigravity => _antigravityUsage.Current?.PlanName ?? _controller.AntigravityPlanType,
        AgentKind.Grok => null,
        _ => _usage.Current?.PlanName,
    };

    private List<(string Label, UsageWindow? Window)> UsageRowsFor(AgentKind agent)
    {
        if (agent == AgentKind.Grok)
        {
            var usage = _grokUsage.Current;
            if (usage is null)
            {
                return _grokUsage.IsAuthenticated || _controller.GrokAuthenticated
                    ? [("Waiting for Grok usage…", null)]
                    : [("Not signed in — run grok login", null)];
            }
            var rows = new List<(string Label, UsageWindow? Window)>
            {
                ("Weekly credits", usage.Weekly),
            };
            if (usage.OnDemand is not null) rows.Add(("On-demand", usage.OnDemand));
            return rows;
        }

        if (agent == AgentKind.Antigravity)
        {
            var usage = _antigravityUsage.Current;
            if (usage is null)
                return [("Waiting for Antigravity usage…", null)];
            return
            [
                ("Five-hour limit", usage.FiveHour),
                ("Weekly limit", usage.Weekly),
            ];
        }

        if (agent == AgentKind.Codex)
        {
            var usage = _codexUsage.Current;
            var rows = new List<(string Label, UsageWindow? Window)>
            {
                (usage?.PrimaryLabel ?? "Primary limit", usage?.Primary),
            };
            if (usage?.Secondary is not null)
                rows.Add((usage.SecondaryLabel ?? "Secondary limit", usage.Secondary));
            if (usage is not null)
                rows.AddRange(usage.AdditionalWindows.Select(item => (item.Label, (UsageWindow?)item.Window)));
            if (usage is null)
                rows.Add(("Waiting for Codex usage…", null));
            return rows;
        }

        if (agent == AgentKind.Cursor)
        {
            var usage = _cursorUsage.Current;
            if (usage is null)
                return [("Waiting for Cursor usage…", null)];
            var rows = new List<(string Label, UsageWindow? Window)>
            {
                ("Included usage", usage.Included),
            };
            if (usage.Auto is not null) rows.Add(("Auto + Composer", usage.Auto));
            if (usage.Api is not null) rows.Add(("API models", usage.Api));
            if (usage.OnDemand is not null) rows.Add(("On-demand", usage.OnDemand));
            return rows;
        }

        var claude = _usage.Current;
        if (claude is null)
            return [("Waiting for Claude usage…", null)];
        var claudeRows = new List<(string Label, UsageWindow? Window)>
        {
            ("Current session", claude.FiveHour),
            ("All models", claude.Weekly),
        };
        claudeRows.AddRange(claude.ModelWeekly.Select(item => (item.ModelName, (UsageWindow?)item.Window)));
        return claudeRows;
    }

    private static void EnsureUsageRows(List<UsageRow> pool, Panel host, int wanted)
    {
        if (pool.Count == wanted) return;
        pool.Clear();
        host.Children.Clear();
        for (var i = 0; i < wanted; i++)
        {
            var row = new UsageRow();
            pool.Add(row);
            host.Children.Add(row.Root);
        }
    }

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

    private static (Color Accent, Color Text) StatusPillColors(string indicator) => indicator switch
    {
        "none" => (Green, GreenText),
        "minor" or "major" => (Orange, Rgb(0xC2, 0x66, 0x0A)),
        "critical" => (Red, Rgb(0xC0, 0x27, 0x1F)),
        "maintenance" => (Blue, Rgb(0x00, 0x57, 0xB6)),
        _ => (Track, WithAlpha(Secondary, 0xB3)),
    };

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
            _ => Orange,
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

    private static ControlTemplate ChromelessButtonTemplate()
    {
        var factory = new FrameworkElementFactory(typeof(ContentPresenter));
        factory.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Stretch);
        factory.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        factory.SetValue(ContentPresenter.ContentSourceProperty, "Content");
        return new ControlTemplate(typeof(Button)) { VisualTree = factory };
    }

    /// <summary>One accordion row for an enabled agent.</summary>
    private sealed class AgentRow
    {
        public readonly Border Root;
        public readonly AgentKind Agent;

        private readonly Border _divider;
        private readonly Border _headerBg;
        private readonly TextBlock _name;
        private readonly TextBlock _subtitle;
        private readonly Ellipse _liveDot;
        private readonly TextBlock _trailing;
        private readonly TextBlock _chevron;
        private readonly Border _detail;
        private readonly StackPanel _detailBody;

        private readonly Button _accountButton;
        private readonly TextBlock _accountText;
        private readonly TextBlock _accountEye;
        private readonly Border _planChip;
        private readonly TextBlock _planText;
        private readonly TextBlock _projectText;
        private readonly TextBlock _sessionState;
        private readonly TextBlock _metaText;
        private readonly Ellipse _broadcastDot;
        private readonly TextBlock _broadcastText;
        private readonly StackPanel _usageHost;
        private readonly TextBlock _errorText;
        private readonly Border _statusCard;
        private readonly TextBlock _statusChevron;
        private readonly Border _statusPill;
        private readonly Ellipse _statusPillDot;
        private readonly TextBlock _statusPillText;
        private readonly StackPanel _statusExpanded;
        private readonly StackPanel _incidentsPanel;
        private readonly StackPanel _componentsPanel;
        private readonly TextBlock _statusFooterText;

        private readonly List<UsageRow> _usageRows = [];

        public AgentRow(AgentKind agent, Action onToggle)
        {
            Agent = agent;
            _name = new TextBlock
            {
                Text = agent.DisplayName(),
                FontSize = 13,
                FontWeight = FontWeights.Medium,
            };
            _subtitle = new TextBlock
            {
                FontSize = 10.5,
                Foreground = Brush(WithAlpha(Secondary, 0x80)),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            _liveDot = new Ellipse
            {
                Width = 6, Height = 6,
                VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed,
            };
            _trailing = new TextBlock
            {
                FontSize = 11.5,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Typography.SetNumeralAlignment(_trailing, FontNumeralAlignment.Tabular);
            _chevron = new TextBlock
            {
                Text = "",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 10,
                Foreground = Brush(WithAlpha(Secondary, 0x4D)),
                Width = 10,
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 0, 0, 0),
            };

            var titleCol = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            titleCol.Children.Add(_name);
            titleCol.Children.Add(_subtitle);

            var trailingStack = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
            };
            trailingStack.Children.Add(_liveDot);
            trailingStack.Children.Add(_trailing);

            var header = new DockPanel { Margin = new Thickness(11, 9, 11, 9) };
            DockPanel.SetDock(_chevron, Dock.Right);
            DockPanel.SetDock(trailingStack, Dock.Right);
            header.Children.Add(_chevron);
            header.Children.Add(trailingStack);
            header.Children.Add(titleCol);

            var headerButton = new Button
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                Cursor = Cursors.Hand,
                Focusable = false,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = header,
                Template = ChromelessButtonTemplate(),
            };
            headerButton.Click += (_, _) => onToggle();

            _headerBg = new Border { Child = headerButton };

            // Detail: account + session + usage + optional Claude status.
            _accountText = new TextBlock
            {
                FontSize = 12.5,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _accountEye = new TextBlock
            {
                // Segoe MDL2 / Fluent: View (E890). Updated in UpdateDetail when revealed.
                Text = "\uE890",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 10,
                Foreground = Brush(WithAlpha(Secondary, 0x73)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(5, 0, 0, 0),
                Visibility = Visibility.Collapsed,
            };
            var accountLeft = new StackPanel { Orientation = Orientation.Horizontal };
            accountLeft.Children.Add(_accountText);
            accountLeft.Children.Add(_accountEye);
            _accountButton = new Button
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                Cursor = Cursors.Hand,
                Focusable = false,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Template = ChromelessButtonTemplate(),
                Content = accountLeft,
            };
            _accountButton.Click += (_, _) => _onToggleEmail?.Invoke();
            _planText = new TextBlock
            {
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _planChip = new Border
            {
                Background = Brush(WithAlpha(Track, 0x1F)),
                BorderBrush = Brush(WithAlpha(Colors.Black, 0x14)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(7, 2, 7, 2),
                VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed,
                Child = _planText,
            };
            var accountRow = new DockPanel { Margin = new Thickness(0, 9, 0, 8) };
            DockPanel.SetDock(_planChip, Dock.Right);
            accountRow.Children.Add(_planChip);
            accountRow.Children.Add(_accountButton);

            _projectText = new TextBlock
            {
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            _sessionState = new TextBlock
            {
                FontSize = 11,
                Foreground = Brush(WithAlpha(Secondary, 0x80)),
                VerticalAlignment = VerticalAlignment.Center,
            };
            _metaText = new TextBlock
            {
                FontSize = 11.5,
                Margin = new Thickness(20, 0, 0, 0),
            };
            _broadcastDot = new Ellipse
            {
                Width = 5, Height = 5,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _broadcastText = new TextBlock
            {
                FontSize = 11,
                Foreground = Brush(WithAlpha(Secondary, 0x80)),
                Margin = new Thickness(6, 0, 0, 0),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            _usageHost = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
            _errorText = new TextBlock
            {
                FontSize = 11,
                Foreground = Brush(Red),
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, 6, 0, 0),
            };

            var folder = new TextBlock
            {
                Text = "",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 12,
                Foreground = Brush(WithAlpha(Secondary, 0x8C)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 7, 0),
            };
            var projectRow = new DockPanel();
            DockPanel.SetDock(_sessionState, Dock.Right);
            projectRow.Children.Add(_sessionState);
            var projectLeft = new StackPanel { Orientation = Orientation.Horizontal };
            projectLeft.Children.Add(folder);
            projectLeft.Children.Add(_projectText);
            projectRow.Children.Add(projectLeft);

            var broadcastRow = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Margin = new Thickness(20, 4, 0, 0),
            };
            broadcastRow.Children.Add(_broadcastDot);
            broadcastRow.Children.Add(_broadcastText);

            var sessionBlock = new StackPanel { Margin = new Thickness(0, 2, 0, 0) };
            sessionBlock.Children.Add(new Border
            {
                BorderBrush = Brush(WithAlpha(Colors.Black, 0x0F)),
                BorderThickness = new Thickness(0, 1, 0, 0),
                Padding = new Thickness(0, 10, 0, 0),
                Child = projectRow,
            });
            sessionBlock.Children.Add(_metaText);
            sessionBlock.Children.Add(broadcastRow);

            // Claude status expander.
            _statusChevron = new TextBlock
            {
                Text = "",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 10,
                Foreground = Brush(WithAlpha(Secondary, 0x66)),
                Width = 10,
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 0, 0, 0),
            };
            _statusPillDot = new Ellipse { Width = 6, Height = 6, VerticalAlignment = VerticalAlignment.Center };
            _statusPillText = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Margin = new Thickness(5, 0, 0, 0) };
            var pillInner = new StackPanel { Orientation = Orientation.Horizontal };
            pillInner.Children.Add(_statusPillDot);
            pillInner.Children.Add(_statusPillText);
            _statusPill = new Border
            {
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(6, 2, 8, 2),
                VerticalAlignment = VerticalAlignment.Center,
                BorderThickness = new Thickness(1),
                Child = pillInner,
            };
            _incidentsPanel = new StackPanel();
            _componentsPanel = new StackPanel();
            _statusFooterText = new TextBlock
            {
                FontSize = 11,
                Foreground = Brush(WithAlpha(Secondary, 0x8C)),
            };
            _statusExpanded = new StackPanel
            {
                Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, 4, 0, 0),
            };
            _statusExpanded.Children.Add(_incidentsPanel);
            _statusExpanded.Children.Add(_componentsPanel);
            var statusFooterBtn = new Button
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                Cursor = Cursors.Hand,
                Focusable = false,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(0, 8, 0, 0),
                Template = ChromelessButtonTemplate(),
            };
            var footerDock = new DockPanel();
            var ext = new TextBlock
            {
                Text = "",
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 10,
                Foreground = Brush(WithAlpha(Secondary, 0x66)),
            };
            DockPanel.SetDock(ext, Dock.Right);
            footerDock.Children.Add(ext);
            footerDock.Children.Add(_statusFooterText);
            statusFooterBtn.Content = footerDock;
            _statusExpanded.Children.Add(statusFooterBtn);

            var statusHeaderBtn = new Button
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                Cursor = Cursors.Hand,
                Focusable = false,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Template = ChromelessButtonTemplate(),
            };
            var statusHeader = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
            DockPanel.SetDock(_statusChevron, Dock.Right);
            DockPanel.SetDock(_statusPill, Dock.Right);
            statusHeader.Children.Add(_statusChevron);
            statusHeader.Children.Add(_statusPill);
            statusHeader.Children.Add(new TextBlock
            {
                Text = "Claude status",
                FontSize = 12.5,
                VerticalAlignment = VerticalAlignment.Center,
            });
            statusHeaderBtn.Content = statusHeader;

            var statusStack = new StackPanel();
            statusStack.Children.Add(statusHeaderBtn);
            statusStack.Children.Add(_statusExpanded);
            _statusCard = new Border
            {
                Visibility = Visibility.Collapsed,
                Child = statusStack,
            };

            // Wire status clicks after fields exist; handlers set via UpdateDetail.
            statusHeaderBtn.Tag = this;
            statusFooterBtn.Tag = this;

            _detailBody = new StackPanel { Margin = new Thickness(11, 2, 11, 11) };
            _detailBody.Children.Add(accountRow);
            _detailBody.Children.Add(sessionBlock);
            _detailBody.Children.Add(_usageHost);
            _detailBody.Children.Add(_errorText);
            _detailBody.Children.Add(_statusCard);

            _detail = new Border
            {
                Background = Brush(WithAlpha(Track, 0x0A)),
                BorderBrush = Brush(WithAlpha(Colors.Black, 0x0D)),
                BorderThickness = new Thickness(0, 1, 0, 0),
                Visibility = Visibility.Collapsed,
                Child = _detailBody,
            };

            _divider = new Border
            {
                Height = 1,
                Background = Brush(WithAlpha(Colors.Black, 0x0F)),
                Visibility = Visibility.Collapsed,
            };

            var column = new StackPanel();
            column.Children.Add(_divider);
            column.Children.Add(_headerBg);
            column.Children.Add(_detail);

            Root = new Border { Child = column, Tag = agent };

            // Store click targets for status on the buttons via closures.
            statusHeaderBtn.Click += (_, _) => _onToggleStatus?.Invoke();
            statusFooterBtn.Click += (_, e) => _onOpenStatus?.Invoke(statusFooterBtn, e);
        }

        private Action? _onToggleStatus;
        private Action? _onToggleEmail;
        private RoutedEventHandler? _onOpenStatus;

        public void SetDivider(bool show) =>
            _divider.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

        public void UpdateHeader(
            AgentKind agent, bool linked, SessionInfo? session, bool expanded, bool showProject)
        {
            _name.Foreground = Brush(linked ? TextColor : WithAlpha(Secondary, 0x80));
            if (!linked)
                _subtitle.Text = "Not connected";
            else if (session is null)
                _subtitle.Text = "Connected";
            else
                _subtitle.Text = showProject ? session.ProjectName : "Project hidden";

            if (session is not null)
            {
                _liveDot.Visibility = Visibility.Visible;
                _liveDot.Fill = Brush(Green);
                _liveDot.Margin = new Thickness(0, 0, 5, 0);
                _trailing.Text = Format.Clock(Format.NowMs() - session.StartEpochMs);
                _trailing.FontWeight = FontWeights.Medium;
                _trailing.Foreground = Brush(TextColor);
            }
            else if (linked)
            {
                _liveDot.Visibility = Visibility.Collapsed;
                _trailing.Text = "idle";
                _trailing.FontWeight = FontWeights.Normal;
                _trailing.Foreground = Brush(WithAlpha(Secondary, 0x73));
            }
            else
            {
                _liveDot.Visibility = Visibility.Collapsed;
                _trailing.Text = "Connect";
                _trailing.FontWeight = FontWeights.Medium;
                _trailing.Foreground = Brush(Blue);
            }

            _chevron.Text = expanded ? "" : "";
            _headerBg.Background = expanded
                ? Brush(WithAlpha(Track, 0x0A))
                : Brushes.Transparent;
            _detail.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        }

        public void CollapseDetail()
        {
            _detail.Visibility = Visibility.Collapsed;
            _statusExpanded.Visibility = Visibility.Collapsed;
            _statusChevron.Text = "";
        }

        public void UpdateDetail(
            AgentKind agent,
            SessionInfo? session,
            bool presenceOn,
            bool sharing,
            Settings settings,
            string? email,
            string? plan,
            bool emailRevealed,
            Action onToggleEmail,
            IReadOnlyList<(string Label, UsageWindow? Window)> usageRows,
            string? error,
            StatusInfo? status,
            bool expandStatus,
            Action onToggleStatus,
            RoutedEventHandler onOpenStatus)
        {
            _onToggleStatus = onToggleStatus;
            _onToggleEmail = onToggleEmail;
            _onOpenStatus = onOpenStatus;
            _detail.Visibility = Visibility.Visible;

            // Account row: masked email (tap to reveal) + plan chip.
            if (string.IsNullOrEmpty(email))
            {
                _accountText.Text = agent.ProviderName();
                _accountEye.Visibility = Visibility.Collapsed;
                _accountButton.IsEnabled = false;
                _accountButton.Cursor = Cursors.Arrow;
            }
            else
            {
                _accountText.Text = emailRevealed ? email : MaskedEmail(email);
                // Segoe MDL2 / Fluent: Hide (E894) when revealed, View (E890) when masked.
                _accountEye.Text = emailRevealed ? "\uE894" : "\uE890";
                _accountEye.Visibility = Visibility.Visible;
                _accountButton.IsEnabled = true;
                _accountButton.Cursor = Cursors.Hand;
                _accountButton.ToolTip = emailRevealed ? "Hide email" : "Show email";
            }

            if (string.IsNullOrWhiteSpace(plan))
            {
                _planChip.Visibility = Visibility.Collapsed;
            }
            else
            {
                _planText.Text = Capitalize(plan);
                _planChip.Visibility = Visibility.Visible;
            }

            var active = session is not null;
            var showProject = active && settings.ShowProject;
            _projectText.Text = session is null ? "No active session"
                : settings.ShowProject ? session.ProjectName : "Project hidden";
            _projectText.FontStyle = showProject ? FontStyles.Normal : FontStyles.Italic;
            _projectText.Foreground = Brush(active && showProject ? TextColor : WithAlpha(Secondary, 0x80));
            _sessionState.Text = active ? "active" : "idle";

            var bits = new List<string>();
            if (session is not null)
            {
                if (settings.ShowModel && session.Model is not null) bits.Add(session.Model);
                if (settings.ShowTokens && session.TotalTokens > 0)
                    bits.Add($"{PresenceController.FormatTokens(session.TotalTokens)} tokens");
            }
            _metaText.Text = bits.Count > 0 ? string.Join("  ·  ", bits)
                : session is null ? "Waiting for a session" : "Model & tokens hidden";
            _metaText.FontStyle = bits.Count > 0 ? FontStyles.Normal : FontStyles.Italic;
            _metaText.Foreground = Brush(WithAlpha(Secondary,
                active && bits.Count > 0 ? (byte)0x99 : (byte)0x66));

            _broadcastDot.Fill = Brush(sharing ? Discord : WithAlpha(Track, 0x99));
            _broadcastText.Text = !presenceOn ? "Presence is off"
                : sharing ? "Sharing to Discord as your status"
                : active ? "A newer agent session is sharing" : "Waiting for a session";

            EnsureUsageRows(_usageRows, _usageHost, usageRows.Count);
            for (var i = 0; i < usageRows.Count; i++)
                _usageRows[i].Update(usageRows[i].Label, usageRows[i].Window);

            _errorText.Text = error ?? "";
            _errorText.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;

            if (status is null)
            {
                _statusCard.Visibility = Visibility.Collapsed;
            }
            else
            {
                _statusCard.Visibility = Visibility.Visible;
                var (accent, textColor) = StatusPillColors(status.Indicator);
                SetPill(_statusPill, _statusPillDot, _statusPillText, accent, textColor, status.SummaryLabel);
                SetStatusExpanded(expandStatus);
                if (expandStatus) _statusFooterText.Text = StatusFooter(status);
            }
        }

        public void SetStatusExpanded(bool expand)
        {
            _statusExpanded.Visibility = expand ? Visibility.Visible : Visibility.Collapsed;
            _statusChevron.Text = expand ? "" : "";
        }

        public void RenderStatusDetails(StatusInfo? status)
        {
            _incidentsPanel.Children.Clear();
            _componentsPanel.Children.Clear();
            if (status is null) return;
            foreach (var incident in status.Incidents)
                _incidentsPanel.Children.Add(IncidentCallout(incident));
            foreach (var component in status.Components)
                _componentsPanel.Children.Add(ComponentRow(component));
            _statusFooterText.Text = StatusFooter(status);
        }
    }

    /// <summary>`pres@example.com` → `p•••@e••••••.com`.</summary>
    private static string MaskedEmail(string email)
    {
        var at = email.IndexOf('@');
        if (at < 0) return new string('•', Math.Max(email.Length, 4));

        var local = email[..at];
        var domain = email[(at + 1)..];
        var maskedLocal = local.Length == 0
            ? "•••"
            : local[0] + new string('•', Math.Max(3, local.Length - 1));

        var dot = domain.LastIndexOf('.');
        string maskedDomain;
        if (dot < 0)
        {
            maskedDomain = new string('•', Math.Max(3, domain.Length));
        }
        else
        {
            var name = domain[..dot];
            var tld = domain[dot..];
            maskedDomain = name.Length == 0
                ? "••" + tld
                : name[0] + new string('•', Math.Max(2, name.Length - 1)) + tld;
        }
        return maskedLocal + "@" + maskedDomain;
    }

    private static string Capitalize(string value)
    {
        if (string.IsNullOrEmpty(value)) return value;
        return char.ToUpperInvariant(value[0]) + (value.Length > 1 ? value[1..] : "");
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

        public void Update(string label, UsageWindow? window, double accentOpacity = 1.0)
        {
            _label.Text = label;
            _label.Opacity = accentOpacity;
            _value.Opacity = accentOpacity;
            if (window is null)
            {
                _value.Text = "—";
            }
            else
            {
                var reset = "";
                if (window.ResetsAtMs is long ms)
                {
                    var left = Format.ResetIn(ms);
                    reset = left == "now" ? " · resets now" : $" · resets in {left}";
                }
                _value.Text = $"{window.Percent}%{reset}";
            }

            var fraction = Math.Clamp((window?.Percent ?? 0) / 100.0, 0.015, 1.0);
            _fillCol.Width = new GridLength(fraction, GridUnitType.Star);
            _restCol.Width = new GridLength(1 - fraction, GridUnitType.Star);

            var severity = window?.Severity.ToLowerInvariant() ?? "normal";
            var color = severity switch
            {
                "normal" => Blue,
                "warning" or "warn" or "low" => Orange,
                _ => Red,
            };
            var alpha = (byte)Math.Clamp((int)Math.Round(0xFF * accentOpacity), 0x40, 0xFF);
            _fill.Background = Brush(WithAlpha(color, alpha));
        }
    }
}
