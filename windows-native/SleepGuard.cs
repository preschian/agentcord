// Keeps the machine awake while "Prevent sleep" is on. The macOS app uses an
// IOPMAssertion; the Windows equivalent is SetThreadExecutionState with
// ES_CONTINUOUS, which holds a per-thread system-required assertion until
// cleared. All calls must come from the same thread (the UI thread here),
// since the state is tied to the calling thread.

using System.Runtime.InteropServices;

namespace AgentCord;

public sealed class SleepGuard
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private bool _enabled;

    /// <summary>Idempotent: applying the current state again is a no-op.</summary>
    public void SetEnabled(bool enabled)
    {
        if (_enabled == enabled) return;
        _enabled = enabled;
        SetThreadExecutionState(enabled ? EsContinuous | EsSystemRequired : EsContinuous);
    }
}
