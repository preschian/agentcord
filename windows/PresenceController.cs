// Observes active Claude Code and Codex sessions, selects the most recently
// active enabled agent, builds the Rich Presence payload from the user's
// settings, and drives DiscordIpc. Clears the presence when the session goes
// idle or the app quits. Port of
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
    public SessionInfo? ClaudeSession { get; private set; }
    public SessionInfo? CodexSession { get; private set; }

    public event Action? Changed;

    private static readonly TimeSpan UpdateInterval = TimeSpan.FromSeconds(3);

    private readonly Settings _settings;
    private readonly ClaudeSession _claudeScanner = new();
    private readonly CodexSession _codexScanner = new();
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
            var activeWindow = Math.Max(_settings.IdleWindowSeconds, 1);
            _claudeScanner.ActiveWindowSeconds = activeWindow;
            _codexScanner.ActiveWindowSeconds = activeWindow;
            ClaudeSession = _claudeScanner.Scan();
            CodexSession = _codexScanner.Scan();

            var info = new[] { ClaudeSession, CodexSession }
                .Where(session => session is not null && _settings.IsAgentEnabled(session.Agent))
                .MaxBy(session => session!.LastModifiedMs);
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
        // Match the macOS payload's dynamic activity name behavior, using the
        // active agent as the top line. The second line only needs the model;
        // repeating the agent there would add no information.
        var model = _settings.ShowModel ? info.Model : null;
        var details = model;

        var stateParts = new List<string>();
        if (_settings.ShowProject)
            stateParts.Add($"Working on: {info.ProjectName}");
        if (_settings.ShowTokens && info.TotalTokens > 0)
            stateParts.Add($"{FormatTokens(info.TotalTokens)} tokens");
        var state = stateParts.Count > 0 ? string.Join(" · ", stateParts) : null;

        return new RichPresence
        {
            Type = Settings.IsAllowedActivity(_settings.ActivityType) ? _settings.ActivityType : 0,
            Name = info.Agent.DisplayName(),
            Details = details,
            State = state,
            Timestamps = new Timestamps { Start = info.StartEpochMs },
            Assets = new Assets
            {
                LargeImage = info.Agent == AgentKind.Codex ? "logo-chatgpt" : "logo-claude",
                LargeText = "agentcord",
                SmallImage = NonEmpty(_settings.SmallImageKey),
                SmallText = $"Active {info.Agent.DisplayName()} session",
            },
            Buttons =
            [
                AgentButton(info.Agent),
                RepoButton,
            ],
        };
    }

    public SessionInfo? SessionFor(AgentKind agent) =>
        agent == AgentKind.Codex ? CodexSession : ClaudeSession;

    private static PresenceButton AgentButton(AgentKind agent) => agent switch
    {
        AgentKind.Codex => new PresenceButton
        {
            Label = "What is Codex",
            Url = "https://developers.openai.com/codex",
        },
        _ => new PresenceButton
        {
            Label = "What is Claude Code",
            Url = "https://www.anthropic.com",
        },
    };

    private static PresenceButton RepoButton => new()
    {
        Label = "AgentCord on GitHub",
        Url = "https://github.com/preschian/agentcord",
    };

    private static string? NonEmpty(string s) => s.Length == 0 ? null : s;

    public static string FormatTokens(long count) => count switch
    {
        >= 1_000_000 => $"{count / 1_000_000.0:F1}M",
        >= 1_000 => $"{count / 1_000.0:F1}K",
        _ => count.ToString(),
    };
}
