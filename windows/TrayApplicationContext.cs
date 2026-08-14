// The tray application shell: a NotifyIcon whose left-click opens the WPF
// popover (PopoverWindow, mirroring the macOS popover) and whose right-click
// offers a minimal quick menu. There is no window and no taskbar entry,
// matching the macOS accessory app.

using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace AgentCord;

public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly Settings _settings;
    private readonly PresenceController _controller;
    private readonly ClaudeUsage _usage = new();
    private readonly CodexUsage _codexUsage = new();
    private readonly CursorUsage _cursorUsage = new();
    private readonly AntigravityUsage _antigravityUsage = new();
    private readonly GrokUsage _grokUsage = new();
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
        // Windows 11 creates the NotifyIconSettings key after the first
        // Shell_NotifyIcon; promote on the next idle so it stays on the bar.
        Application.Idle += PromoteTrayIconOnce;
        _notifyIcon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) Popover.TogglePopover();
        };

        _tooltipTimer.Tick += (_, _) => RefreshTooltip();
        _tooltipTimer.Start();

        _sleepGuard.SetEnabled(_settings.PreventSleep);
        _controller.Start();
        _usage.Start();
        _codexUsage.Start();
        _cursorUsage.Start();
        _antigravityUsage.Start();
        _grokUsage.Start();
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
        _popover ??= new PopoverWindow(
            _settings, _controller, _usage, _codexUsage, _cursorUsage, _antigravityUsage, _grokUsage, _status, _sleepGuard, Quit);

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
        try
        {
            // Mirrors the macOS menu bar line: session bits + compact usage.
            // NotifyIcon.Text is plain text (multi-line via \n) and capped at 63 chars.
            var text = TrayStatusText.Build(
                _settings, _controller, _usage.Current, _codexUsage.Current, _cursorUsage.Current, _antigravityUsage.Current, _grokUsage.Current);
            if (_notifyIcon.Text != text) _notifyIcon.Text = text;
        }
        catch { }
    }

    private void PromoteTrayIconOnce(object? sender, EventArgs e)
    {
        Application.Idle -= PromoteTrayIconOnce;
        PromoteTrayIcon();
    }

    /// <summary>Ask Windows 11 to keep the icon on the taskbar, not only in
    /// the overflow chevron. The key is created after the first notify.</summary>
    private static void PromoteTrayIcon()
    {
        try
        {
            var exe = Path.GetFullPath(Application.ExecutablePath);
            using var root = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Control Panel\NotifyIconSettings", writable: true);
            if (root is null) return;
            foreach (var name in root.GetSubKeyNames())
            {
                using var sub = root.OpenSubKey(name, writable: true);
                if (sub?.GetValue("ExecutablePath") as string is not { } path) continue;
                if (!path.Equals(exe, StringComparison.OrdinalIgnoreCase)) continue;
                sub.SetValue("IsPromoted", 1, Microsoft.Win32.RegistryValueKind.DWord);
            }
        }
        catch
        {
            // Best-effort: overflow is still clickable.
        }
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
        Program.LogCrash("ShutdownOnce", null);
        _tooltipTimer.Stop();
        _popover?.CloseForExit();
        _controller.Shutdown();
        _usage.Dispose();
        _codexUsage.Dispose();
        _cursorUsage.Dispose();
        _antigravityUsage.Dispose();
        _grokUsage.Dispose();
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
