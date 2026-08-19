// Tray entry point. No window and no taskbar entry — the app lives entirely
// in the notification area, mirroring the macOS menu bar app (LSUIElement).

using System.IO;
using System.Windows.Forms;

namespace AgentCord;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => LogCrash("ThreadException", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            LogCrash("UnhandledException", e.ExceptionObject as Exception);

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
        try
        {
            LogCrash("Startup", null);
            Application.Run(new TrayApplicationContext(showPopoverOnStart: args.Contains("--popover")));
            LogCrash("Application.Run returned", null);
        }
        catch (Exception ex)
        {
            LogCrash("Main", ex);
        }
    }

    private static void Screenshot(string path)
    {
        var settings = Settings.Load();
        using var controller = new PresenceController(settings);
        using var usage = new ClaudeUsage();
        using var codexUsage = new CodexUsage();
        using var cursorUsage = new CursorUsage();
        using var grokUsage = new GrokUsage();
        using var status = new AnthropicStatus();
        controller.Start();
        usage.Start();
        codexUsage.Start();
        cursorUsage.Start();
        grokUsage.Start();
        status.Start();

        // Let the first session scan, usage fetch, and status fetch land so
        // the capture shows real data.
        var deadline = DateTime.UtcNow.AddSeconds(6);
        while (DateTime.UtcNow < deadline)
        {
            Application.DoEvents();
            Thread.Sleep(100);
        }

        var window = new PopoverWindow(
            settings, controller, usage, codexUsage, cursorUsage, grokUsage, status, () => { });
        window.CaptureForDebug(path);
        controller.Shutdown();
    }

    internal static void LogCrash(string kind, Exception? ex)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "AgentCord");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "crash.log"),
                $"{DateTime.Now:O} {kind}: {ex?.ToString() ?? "ok"}\n");
        }
        catch
        {
            // Logging must never take the app down.
        }
    }
}
