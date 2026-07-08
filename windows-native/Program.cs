// Tray entry point. No window and no taskbar entry — the app lives entirely
// in the notification area, mirroring the macOS menu bar app (LSUIElement).

using System.Windows.Forms;

namespace AgentCord;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // A second instance would fight over the Discord pipe and the tray
        // icon; quietly defer to the one already running.
        using var mutex = new Mutex(initiallyOwned: true, "AgentCord.SingleInstance", out var isFirst);
        if (!isFirst) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);

        // --screenshot <path>: render the popover off-screen to PNGs and exit.
        // Debug-only, for checking the UI without touching the tray.
        var shotIndex = Array.IndexOf(args, "--screenshot");
        if (shotIndex >= 0 && shotIndex + 1 < args.Length)
        {
            Screenshot(args[shotIndex + 1]);
            return;
        }

        // --popover opens the status popover immediately (handy for debugging
        // the UI without reaching for the tray icon).
        Application.Run(new TrayApplicationContext(showPopoverOnStart: args.Contains("--popover")));
    }

    private static void Screenshot(string path)
    {
        var settings = Settings.Load();
        using var controller = new PresenceController(settings);
        using var usage = new ClaudeUsage();
        using var status = new AnthropicStatus();
        controller.Start();
        usage.Start();
        status.Start();

        // Let the first session scan, usage fetch, and status fetch land so
        // the capture shows real data.
        var deadline = DateTime.UtcNow.AddSeconds(6);
        while (DateTime.UtcNow < deadline)
        {
            Application.DoEvents();
            Thread.Sleep(100);
        }

        var window = new PopoverWindow(settings, controller, usage, status, new SleepGuard(), () => { });
        window.CaptureForDebug(path);
        controller.Shutdown();
    }
}
