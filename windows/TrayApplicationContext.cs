// The tray application shell: a NotifyIcon whose left-click opens the WPF
// popover (PopoverWindow, mirroring the macOS popover) and whose right-click
// offers a minimal quick menu. There is no window and no taskbar entry,
// matching the macOS accessory app.

using System.Drawing;
using System.Windows.Forms;

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
    private readonly ToolStripMenuItem _presenceItem = new("Enable presence") { CheckOnClick = true };
    private readonly System.Windows.Forms.Timer _tooltipTimer = new() { Interval = 2000 };

    private PopoverWindow? _popover;
    private bool _shutdown;

    public TrayApplicationContext(bool showPopoverOnStart = false)
    {
        _settings = Settings.Load();
        _controller = new PresenceController(_settings);

        BuildMenu();

        _notifyIcon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "AgentCord",
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) Popover.TogglePopover();
        };

        _tooltipTimer.Tick += (_, _) => RefreshTooltip();
        _tooltipTimer.Start();

        _sleepGuard.SetEnabled(_settings.PreventSleep);
        _controller.Start();
        _usage.Start();
        _status.Start();

        // Clear the presence even when the process exits via logoff/shutdown
        // rather than the Quit item.
        Application.ApplicationExit += (_, _) => ShutdownOnce();

        // Show once the message loop is pumping; a Show() from the constructor
        // can never take focus, so the popover would sit there un-dismissable.
        if (showPopoverOnStart)
        {
            var once = new System.Windows.Forms.Timer { Interval = 1 };
            once.Tick += (_, _) => { once.Dispose(); Popover.ShowPopover(); };
            once.Start();
        }
    }

    /// <summary>The popover is created lazily on first use; WPF and WinForms
    /// share this thread's message pump, so it lives happily alongside the
    /// NotifyIcon.</summary>
    private PopoverWindow Popover =>
        _popover ??= new PopoverWindow(_settings, _controller, _usage, _status, _sleepGuard, Quit);

    private void BuildMenu()
    {
        var showItem = new ToolStripMenuItem("Show status");
        showItem.Click += (_, _) => Popover.ShowPopover();

        _presenceItem.CheckedChanged += (_, _) =>
        {
            if (_presenceItem.Checked != _settings.PresenceEnabled)
                _controller.SetEnabled(_presenceItem.Checked);
        };

        var quitItem = new ToolStripMenuItem("Quit agentcord");
        quitItem.Click += (_, _) => Quit();

        _menu.Items.AddRange([showItem, _presenceItem, new ToolStripSeparator(), quitItem]);
        _menu.Opening += (_, _) => _presenceItem.Checked = _settings.PresenceEnabled;
    }

    private void RefreshTooltip()
    {
        var text = "AgentCord";
        if (_controller.CurrentSession is { } session)
        {
            var bits = new List<string> { session.ProjectName };
            if (session.Model is not null) bits.Add(session.Model);
            bits.Add(Format.Elapsed(Format.NowMs() - session.StartEpochMs));
            text = $"AgentCord — {string.Join(" · ", bits)}";
        }
        // NotifyIcon.Text throws past 127 characters.
        if (text.Length > 127) text = text[..126] + "…";
        if (_notifyIcon.Text != text) _notifyIcon.Text = text;
    }

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

    private void ShutdownOnce()
    {
        if (_shutdown) return;
        _shutdown = true;
        _tooltipTimer.Stop();
        _popover?.CloseForExit();
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
