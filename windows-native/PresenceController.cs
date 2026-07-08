// Observes the active Claude Code session, builds the Rich Presence payload
// from the user's settings, and drives DiscordIpc. Clears the presence when
// the session goes idle or the app quits. Port of
// AgentCord/PresenceController.swift.
//
// A 3-second tick both re-scans the session (cheap, thanks to the per-file
// aggregate cache) and serves as the update throttle — Discord rate-limits
// rapid activity updates, and DiscordIpc additionally dedupes unchanged
// payloads.

namespace AgentCord;

public sealed class PresenceController : IDisposable
{
    public DiscordIpc.ConnState DiscordState => _ipc.State;
    public string? LastError { get; private set; }

    /// <summary>Latest scan result; the tray applies display settings when rendering.</summary>
    public SessionInfo? CurrentSession { get; private set; }

    public event Action? Changed;

    private static readonly TimeSpan UpdateInterval = TimeSpan.FromSeconds(3);

    private readonly Settings _settings;
    private readonly ClaudeSession _session = new();
    private readonly DiscordIpc _ipc = new();
    private System.Threading.Timer? _timer;
    private int _ticking;

    public PresenceController(Settings settings)
    {
        _settings = settings;
        _ipc.StateChanged += _ => Changed?.Invoke();
        _ipc.Error += message => { LastError = message; Changed?.Invoke(); };
        _ipc.Ready += () => { LastError = null; Changed?.Invoke(); };
    }

    public void Start()
    {
        _timer = new System.Threading.Timer(_ => Tick(), null, TimeSpan.Zero, UpdateInterval);
    }

    public void SetEnabled(bool enabled)
    {
        _settings.PresenceEnabled = enabled;
        _settings.Save();
        if (!enabled) _ipc.Disconnect();
        Tick();
    }

    /// <summary>Clear the presence and disconnect. Called on app exit.</summary>
    public void Shutdown()
    {
        _timer?.Dispose();
        _timer = null;
        _ipc.ClearActivitySync();
        _ipc.Disconnect();
    }

    public void Dispose()
    {
        _timer?.Dispose();
        _ipc.Dispose();
    }

    private void Tick()
    {
        // Timer callbacks can overlap if a scan runs long; skip instead of piling up.
        if (Interlocked.Exchange(ref _ticking, 1) == 1) return;
        try
        {
            _session.ActiveWindowSeconds = Math.Max(_settings.IdleWindowSeconds, 1);
            var info = _session.Scan();
            var changed = !Equals(info, CurrentSession);
            CurrentSession = info;

            if (_settings.PresenceEnabled)
            {
                _ipc.Connect(Settings.DiscordClientId);
                _ipc.SetActivity(info is null ? null : BuildPresence(info));
            }

            if (changed) Changed?.Invoke();
        }
        finally
        {
            Interlocked.Exchange(ref _ticking, 0);
        }
    }

    private RichPresence BuildPresence(SessionInfo info)
    {
        // Header (bold title): the model, e.g. "Opus 4.8".
        var name = (_settings.ShowModel ? info.Model : null) ?? "agentcord";

        // details: the repository being worked on.
        var details = _settings.ShowProject ? $"Working on: {info.ProjectName}" : null;

        // state: token usage.
        var state = _settings.ShowTokens && info.TotalTokens > 0
            ? $"{FormatTokens(info.TotalTokens)} tokens"
            : null;

        return new RichPresence
        {
            Type = Settings.IsAllowedActivity(_settings.ActivityType) ? _settings.ActivityType : 0,
            Name = name,
            Details = details,
            State = state,
            Timestamps = new Timestamps { Start = info.StartEpochMs },
            Assets = new Assets
            {
                LargeImage = NonEmpty(_settings.LargeImageKey),
                LargeText = "agentcord",
                SmallImage = NonEmpty(_settings.SmallImageKey),
                SmallText = "Active session",
            },
            Buttons = [new PresenceButton { Label = "What is Claude Code", Url = "https://www.anthropic.com" }],
        };
    }

    private static string? NonEmpty(string s) => s.Length == 0 ? null : s;

    public static string FormatTokens(long count) => count switch
    {
        >= 1_000_000 => $"{count / 1_000_000.0:F1}M",
        >= 1_000 => $"{count / 1_000.0:F1}K",
        _ => count.ToString(),
    };
}
