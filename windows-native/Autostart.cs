// Launch-at-login, toggled through the per-user Run registry key. The macOS
// app uses SMAppService; the Windows equivalent is a value under
// HKCU\Software\Microsoft\Windows\CurrentVersion\Run.

using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AgentCord;

public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "AgentCord";

    private static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    /// <summary>True when the Run value exists and points at this executable.</summary>
    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            var stored = key?.GetValue(ValueName) as string;
            if (string.IsNullOrEmpty(stored)) return false;
            return string.Equals(
                Path.GetFullPath(stored.Trim().Trim('"')),
                Path.GetFullPath(ExePath),
                StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Add or remove the Run value. Returns whether the change succeeded.</summary>
    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled)
            {
                // Quoted, no arguments: the exe starts in tray mode.
                key.SetValue(ValueName, $"\"{ExePath}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }
}
