// The tray application: a NotifyIcon whose context menu mirrors the macOS
// popover's content — connection pill, active session card, usage bars,
// Claude status row, and settings toggles — rendered as native menu items.
// There is no window and no taskbar entry, matching the macOS accessory app.

using System.Diagnostics;
using System.Reflection;

namespace AgentCord;

public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly Settings _settings;
    private readonly PresenceController _controller;
    private readonly ClaudeUsage _usage = new();
    private readonly AnthropicStatus _status = new();
    private readonly SleepGuard _sleepGuard = new();

    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu = new();
    private readonly System.Windows.Forms.Timer _refreshTimer = new() { Interval = 1000 };

    // Info rows refreshed in place (dynamic usage rows are rebuilt on open).
    private readonly ToolStripMenuItem _headerItem = Info("agentcord");
    private readonly ToolStripMenuItem _projectItem = Info("No active session");
    private readonly ToolStripMenuItem _metaItem = Info("Waiting for a session");
    private readonly ToolStripMenuItem _usage5hItem = Info("Current session: —");
    private readonly ToolStripMenuItem _usageWeeklyItem = Info("All models: —");
    private readonly List<ToolStripMenuItem> _modelUsageItems = [];
    private readonly ToolStripMenuItem _statusItem = new("Claude status: —");
    private readonly ToolStripMenuItem _errorItem = Info("");

    private readonly ToolStripMenuItem _presenceItem = new("Enable presence") { CheckOnClick = true };
    private readonly ToolStripMenuItem _autostartItem = new("Launch at login") { CheckOnClick = true };
    private readonly ToolStripMenuItem _preventSleepItem = new("Prevent sleep") { CheckOnClick = true };
    private readonly ToolStripMenuItem _showProjectItem = new("Show project") { CheckOnClick = true };
    private readonly ToolStripMenuItem _showModelItem = new("Show model") { CheckOnClick = true };
    private readonly ToolStripMenuItem _showTokensItem = new("Show tokens") { CheckOnClick = true };
    private readonly ToolStripMenuItem _activityMenu = new("Activity type");
    private readonly ToolStripMenuItem _idleMenu = new("Idle window");

    private static readonly int[] IdleStepsMinutes = [5, 10, 15, 20, 25, 30];

    public TrayApplicationContext()
    {
        _settings = Settings.Load();
        _controller = new PresenceController(_settings);

        BuildMenu();
        SyncTogglesFromSettings();

        _notifyIcon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "AgentCord",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        // The context menu only opens on right-click by default; a tray app
        // should respond to left-click too.
        _notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowMenu();
        };

        _menu.Opening += (_, _) =>
        {
            // Pull fresh usage numbers and Anthropic status as the menu opens
            // (throttled internally), and render the current snapshot.
            _usage.Refresh();
            _status.Refresh();
            RefreshMenu();
        };
        _refreshTimer.Tick += (_, _) =>
        {
            RefreshTooltip();
            if (_menu.Visible) RefreshMenu();
        };
        _refreshTimer.Start();

        _sleepGuard.SetEnabled(_settings.PreventSleep);
        _controller.Start();
        _usage.Start();
        _status.Start();

        // Clear the presence even when the process exits via logoff/shutdown
        // rather than the Quit item.
        Application.ApplicationExit += (_, _) => ShutdownOnce();
    }

    // --- Menu construction

    private static ToolStripMenuItem Info(string text) => new(text) { Enabled = false };

    private void BuildMenu()
    {
        _statusItem.Click += (_, _) => OpenUrl(AnthropicStatus.PageUrl);
        _statusItem.Visible = false;
        _errorItem.Visible = false;
        _errorItem.ForeColor = Color.Firebrick;

        _presenceItem.CheckedChanged += (_, _) =>
        {
            if (_presenceItem.Checked != _settings.PresenceEnabled)
                _controller.SetEnabled(_presenceItem.Checked);
        };
        _autostartItem.Click += (_, _) =>
        {
            if (!Autostart.SetEnabled(_autostartItem.Checked))
                _autostartItem.Checked = Autostart.IsEnabled();
        };
        _preventSleepItem.CheckedChanged += (_, _) =>
        {
            _settings.PreventSleep = _preventSleepItem.Checked;
            _settings.Save();
            _sleepGuard.SetEnabled(_settings.PreventSleep);
        };

        WireDisplayToggle(_showProjectItem, v => _settings.ShowProject = v);
        WireDisplayToggle(_showModelItem, v => _settings.ShowModel = v);
        WireDisplayToggle(_showTokensItem, v => _settings.ShowTokens = v);

        foreach (var (value, name) in Settings.ActivityTypes)
        {
            var item = new ToolStripMenuItem(name) { Tag = value };
            item.Click += (_, _) =>
            {
                _settings.ActivityType = value;
                _settings.Save();
                SyncTogglesFromSettings();
            };
            _activityMenu.DropDownItems.Add(item);
        }

        foreach (var minutes in IdleStepsMinutes)
        {
            var item = new ToolStripMenuItem($"{minutes} min") { Tag = minutes };
            item.Click += (_, _) =>
            {
                _settings.IdleWindowSeconds = minutes * 60.0;
                _settings.Save();
                SyncTogglesFromSettings();
            };
            _idleMenu.DropDownItems.Add(item);
        }

        var displayMenu = new ToolStripMenuItem("Display");
        displayMenu.DropDownItems.AddRange([_showProjectItem, _showModelItem, _showTokensItem]);

        var quitItem = new ToolStripMenuItem("Quit agentcord");
        quitItem.Click += (_, _) => Quit();

        _menu.Items.AddRange(
        [
            _headerItem,
            new ToolStripSeparator(),
            _projectItem,
            _metaItem,
            new ToolStripSeparator(),
            _usage5hItem,
            _usageWeeklyItem,
            // Per-model usage rows are inserted here on refresh.
            _statusItem,
            _errorItem,
            new ToolStripSeparator(),
            _presenceItem,
            _autostartItem,
            _preventSleepItem,
            displayMenu,
            _activityMenu,
            _idleMenu,
            new ToolStripSeparator(),
            quitItem,
        ]);
    }

    private void WireDisplayToggle(ToolStripMenuItem item, Action<bool> apply)
    {
        item.CheckedChanged += (_, _) =>
        {
            apply(item.Checked);
            _settings.Save();
        };
    }

    private void SyncTogglesFromSettings()
    {
        _presenceItem.Checked = _settings.PresenceEnabled;
        _autostartItem.Checked = Autostart.IsEnabled();
        _preventSleepItem.Checked = _settings.PreventSleep;
        _showProjectItem.Checked = _settings.ShowProject;
        _showModelItem.Checked = _settings.ShowModel;
        _showTokensItem.Checked = _settings.ShowTokens;
        foreach (ToolStripMenuItem item in _activityMenu.DropDownItems)
            item.Checked = (int)item.Tag! == _settings.ActivityType;
        var idleMinutes = (int)Math.Round(_settings.IdleWindowSeconds / 60.0);
        foreach (ToolStripMenuItem item in _idleMenu.DropDownItems)
            item.Checked = (int)item.Tag! == idleMinutes;
    }

    // --- Rendering

    private void RefreshMenu()
    {
        var session = _controller.CurrentSession;

        _headerItem.Text = $"agentcord — {ConnectionLabel()}";

        if (session is null)
        {
            _projectItem.Text = "No active session";
            _metaItem.Text = "Waiting for a session";
        }
        else
        {
            _projectItem.Text = _settings.ShowProject ? session.ProjectName : "Project hidden";
            var bits = new List<string>();
            if (_settings.ShowModel && session.Model is not null) bits.Add(session.Model);
            bits.Add(FormatElapsed(NowMs() - session.StartEpochMs));
            if (_settings.ShowTokens && session.TotalTokens > 0)
                bits.Add($"{PresenceController.FormatTokens(session.TotalTokens)} tokens");
            _metaItem.Text = string.Join("  ·  ", bits);
        }

        var usage = _usage.Current;
        _usage5hItem.Text = UsageLine("Current session", usage?.FiveHour);
        _usageWeeklyItem.Text = UsageLine("All models", usage?.Weekly);
        RefreshModelUsageRows(usage);

        var status = _status.Current;
        _statusItem.Visible = status is not null;
        if (status is not null)
        {
            var suffix = status.IncidentCount > 0
                ? $" ({status.IncidentCount} incident{(status.IncidentCount == 1 ? "" : "s")})"
                : "";
            _statusItem.Text = $"Claude status: {status.SummaryLabel}{suffix}";
        }

        _errorItem.Visible = _controller.LastError is not null;
        _errorItem.Text = _controller.LastError ?? "";

        SyncTogglesFromSettings();
    }

    /// <summary>Per-model weekly rows (e.g. "Fable") vary in count per plan, so
    /// they are re-created after the fixed weekly row whenever the set changes.</summary>
    private void RefreshModelUsageRows(UsageInfo? usage)
    {
        var wanted = usage?.ModelWeekly ?? [];
        if (_modelUsageItems.Count != wanted.Count)
        {
            foreach (var item in _modelUsageItems) _menu.Items.Remove(item);
            _modelUsageItems.Clear();
            var index = _menu.Items.IndexOf(_usageWeeklyItem) + 1;
            for (var i = 0; i < wanted.Count; i++)
            {
                var item = Info("");
                _menu.Items.Insert(index++, item);
                _modelUsageItems.Add(item);
            }
        }
        for (var i = 0; i < wanted.Count; i++)
            _modelUsageItems[i].Text = UsageLine(wanted[i].ModelName, wanted[i].Window);
    }

    private static string UsageLine(string label, UsageWindow? window)
    {
        if (window is null) return $"{label}: —";
        var reset = window.ResetsAtMs is long ms ? $" · resets {FormatResetRelative(ms)}" : "";
        return $"{label}: {window.Percent}%{reset}";
    }

    private string ConnectionLabel()
    {
        if (!_settings.PresenceEnabled) return "presence off";
        return _controller.DiscordState switch
        {
            DiscordIpc.ConnState.Connected => "connected",
            DiscordIpc.ConnState.Connecting => "connecting…",
            _ => "disconnected",
        };
    }

    private void RefreshTooltip()
    {
        var text = "AgentCord";
        if (_controller.CurrentSession is { } session)
        {
            var bits = new List<string> { session.ProjectName };
            if (session.Model is not null) bits.Add(session.Model);
            bits.Add(FormatElapsed(NowMs() - session.StartEpochMs));
            text = $"AgentCord — {string.Join(" · ", bits)}";
        }
        // NotifyIcon.Text throws past 127 characters.
        if (text.Length > 127) text = text[..126] + "…";
        if (_notifyIcon.Text != text) _notifyIcon.Text = text;
    }

    // --- Formatting

    private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>Formats a duration without seconds: "1h 05m" / "10m".</summary>
    private static string FormatElapsed(long ms)
    {
        var totalMinutes = Math.Max(0, ms / 60000);
        var h = totalMinutes / 60;
        var m = totalMinutes % 60;
        return h > 0 ? $"{h}h {m:00}m" : $"{m}m";
    }

    /// <summary>Relative reset time: "now" / "in 25m" / "in 1h 20m" / "in 3d 4h".</summary>
    private static string FormatResetRelative(long resetsAtMs)
    {
        var secs = (resetsAtMs - NowMs()) / 1000;
        if (secs <= 0) return "now";
        var d = secs / 86_400;
        var h = secs / 3600 % 24;
        var m = secs / 60 % 60;
        if (d > 0) return $"in {d}d {h}h";
        if (h > 0) return $"in {h}h {m}m";
        return $"in {m}m";
    }

    // --- Plumbing

    private static Icon LoadIcon()
    {
        try
        {
            return Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        }
        catch
        {
            return SystemIcons.Application;
        }
    }

    private void ShowMenu()
    {
        // NotifyIcon has no public API to open its menu on left-click; this
        // internal helper also positions the menu correctly near the tray.
        typeof(NotifyIcon)
            .GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)
            ?.Invoke(_notifyIcon, null);
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }

    private bool _shutdown;

    private void ShutdownOnce()
    {
        if (_shutdown) return;
        _shutdown = true;
        _refreshTimer.Stop();
        _controller.Shutdown();
        _usage.Dispose();
        _status.Dispose();
        _sleepGuard.SetEnabled(false);
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }

    private void Quit()
    {
        ShutdownOnce();
        ExitThread();
    }
}
