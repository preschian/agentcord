// Tray entry point. No window and no taskbar entry — the app lives entirely
// in the notification area, mirroring the macOS menu bar app (LSUIElement).

namespace AgentCord;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // A second instance would fight over the Discord pipe and the tray
        // icon; quietly defer to the one already running.
        using var mutex = new Mutex(initiallyOwned: true, "AgentCord.SingleInstance", out var isFirst);
        if (!isFirst) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.Run(new TrayApplicationContext());
    }
}
