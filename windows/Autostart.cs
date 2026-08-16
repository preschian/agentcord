// Launch-at-login, toggled through the per-user Run registry key. The macOS
// app uses SMAppService; the Windows equivalent is a value under
// HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
//
// Writing Run is not enough on Windows 10/11: Settings / Task Manager also
// store an enable/disable flag under Explorer\StartupApproved\Run. A leftover
// "disabled" blob (first byte 0x03) keeps Explorer from launching the app
// even when the Run value is present and the in-app switch looks on.

using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AgentCord;

public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovedKey =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "AgentCord";

    private static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    /// <summary>True when the Run value points at this executable and Windows
    /// has not disabled the startup entry.</summary>
    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            var stored = key?.GetValue(ValueName) as string;
            if (string.IsNullOrEmpty(stored)) return false;
            if (!string.Equals(
                Path.GetFullPath(stored.Trim().Trim('"')),
                Path.GetFullPath(ExePath),
                StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            return IsStartupApproved(approved?.GetValue(ValueName) as byte[]);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Add or remove the Run value and the matching StartupApproved
    /// flag. Returns whether the change succeeded.</summary>
    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            using var approved = Registry.CurrentUser.CreateSubKey(ApprovedKey);
            if (enabled)
            {
                // Quoted, no arguments: the exe starts in tray mode.
                key.SetValue(ValueName, $"\"{ExePath}\"");
                approved.SetValue(ValueName, EnabledApprovedBlob(), RegistryValueKind.Binary);
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                approved.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Missing blob means Explorer has not vetoed the Run entry.
    /// 0x02 / 0x06 = enabled; 0x03 / 0x07 = disabled in Settings.</summary>
    internal static bool IsStartupApproved(byte[]? blob)
    {
        if (blob is null || blob.Length == 0) return true;
        return blob[0] is 0x02 or 0x06;
    }

    private static byte[] EnabledApprovedBlob()
    {
        var blob = new byte[12];
        blob[0] = 0x02;
        var time = BitConverter.GetBytes(DateTime.UtcNow.ToFileTimeUtc());
        Buffer.BlockCopy(time, 0, blob, 4, 8);
        return blob;
    }
}
