// Snapshot of a growing session-file tree. Presence ticks every 3s; walking
// ~/.claude/projects (or the Codex / Cursor / Grok equivalents) on
// every tick is the expensive path. A FileSystemWatcher marks structural
// changes. Between walks we only re-stat files whose last mtime is still
// inside the lookback window. A 30s safety walk catches missed events.
// Matches the macOS FSEvents + slow safety-walk design.

using System.Collections.Concurrent;
using System.IO;

namespace AgentCord;

internal sealed class SessionTreeIndex : IDisposable
{
    internal static readonly TimeSpan SafetyInterval = TimeSpan.FromSeconds(30);

    private readonly string _root;
    private readonly string _pattern;
    private readonly Func<string, bool>? _match;
    private readonly ConcurrentQueue<(WatcherChangeTypes Change, string Path)> _events = new();
    private FileSystemWatcher? _watcher;
    private List<(string Path, DateTime Mtime)> _files = [];
    private DateTime _lastWalk = DateTime.MinValue;
    private int _needWalk = 1;
    private int _queued;
    private bool _disposed;

    public SessionTreeIndex(string root, string pattern, Func<string, bool>? match = null)
    {
        _root = root;
        _pattern = pattern;
        _match = match;
    }

    public bool RootExists => Directory.Exists(_root);

    /// <summary>Current path+mtime snapshot. Walks at most every 30s or when
    /// the watcher reports a structural change.</summary>
    public IReadOnlyList<(string Path, DateTime Mtime)> Snapshot(TimeSpan lookback)
    {
        TryAttachWatcher();
        DrainEvents();

        var now = DateTime.UtcNow;
        if (Volatile.Read(ref _needWalk) != 0 || now - _lastWalk >= SafetyInterval)
        {
            Walk();
            Interlocked.Exchange(ref _needWalk, 0);
            _lastWalk = now;
            return _files;
        }

        RefreshRecent(now - lookback);
        return _files;
    }

    public void Dispose()
    {
        _disposed = true;
        DisposeWatcher();
    }

    private void Walk()
    {
        while (_events.TryDequeue(out _)) { }
        Interlocked.Exchange(ref _queued, 0);

        List<(string Path, DateTime Mtime)> files = [];
        try
        {
            if (!Directory.Exists(_root))
            {
                _files = files;
                return;
            }

            foreach (var path in Directory.EnumerateFiles(_root, _pattern, SearchOption.AllDirectories))
            {
                if (_match is not null && !_match(path)) continue;
                try { files.Add((path, File.GetLastWriteTimeUtc(path))); }
                catch { /* vanished mid-walk */ }
            }
        }
        catch
        {
            // Tree can disappear mid-scan; keep the last snapshot.
            return;
        }

        _files = files;
        TryAttachWatcher();
    }

    private void RefreshRecent(DateTime cutoffUtc)
    {
        for (var i = _files.Count - 1; i >= 0; i--)
        {
            var path = _files[i].Path;
            if (_files[i].Mtime < cutoffUtc) continue;
            try
            {
                if (!File.Exists(path))
                {
                    _files.RemoveAt(i);
                    continue;
                }
                _files[i] = (path, File.GetLastWriteTimeUtc(path));
            }
            catch
            {
                _files.RemoveAt(i);
            }
        }
    }

    private static string WatcherFilter(string pattern) =>
        string.IsNullOrEmpty(pattern) || pattern is "*" or "*.*" ? "*.*" : pattern;

    private void DrainEvents()
    {
        while (_events.TryDequeue(out var ev))
        {
            Interlocked.Decrement(ref _queued);
            if (ev.Change is WatcherChangeTypes.Deleted or WatcherChangeTypes.Renamed)
            {
                Interlocked.Exchange(ref _needWalk, 1);
                continue;
            }

            if (!Matches(ev.Path))
            {
                // Directory create/change: a new session folder may appear.
                if (ev.Change == WatcherChangeTypes.Created)
                    Interlocked.Exchange(ref _needWalk, 1);
                continue;
            }

            try
            {
                if (!File.Exists(ev.Path))
                {
                    _files.RemoveAll(f => PathsEqual(f.Path, ev.Path));
                    continue;
                }

                var mtime = File.GetLastWriteTimeUtc(ev.Path);
                var idx = _files.FindIndex(f => PathsEqual(f.Path, ev.Path));
                if (idx >= 0) _files[idx] = (ev.Path, mtime);
                else _files.Add((ev.Path, mtime));
            }
            catch
            {
                Interlocked.Exchange(ref _needWalk, 1);
            }
        }
    }

    private bool Matches(string path)
    {
        if (_match is not null && !_match(path)) return false;
        if (_pattern is "*" or "*.*") return true;
        return path.EndsWith(_pattern.TrimStart('*'), StringComparison.OrdinalIgnoreCase);
    }

    private static bool PathsEqual(string a, string b) =>
        a.Equals(b, StringComparison.OrdinalIgnoreCase);

    private void TryAttachWatcher()
    {
        if (_disposed || _watcher is not null) return;
        if (!Directory.Exists(_root)) return;
        try
        {
            var watcher = new FileSystemWatcher(_root)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
                // Watch only the files we parse. Filter=* on ~/.cursor/chats
                // enqueues every store.db write and the queue grows without bound.
                Filter = WatcherFilter(_pattern),
                InternalBufferSize = 16 * 1024,
            };
            watcher.Created += OnEvent;
            watcher.Changed += OnEvent;
            watcher.Deleted += OnEvent;
            watcher.Renamed += OnRenamed;
            watcher.Error += OnError;
            watcher.EnableRaisingEvents = true;
            _watcher = watcher;
        }
        catch
        {
            // Watcher is a hint. The 30s safety walk still runs.
        }
    }

    private void OnEvent(object sender, FileSystemEventArgs e) => Enqueue(e.ChangeType, e.FullPath);

    private void OnRenamed(object sender, RenamedEventArgs e)
    {
        Enqueue(WatcherChangeTypes.Renamed, e.FullPath);
        if (e.OldFullPath.Length > 0)
            Enqueue(WatcherChangeTypes.Deleted, e.OldFullPath);
    }

    private void Enqueue(WatcherChangeTypes change, string path)
    {
        if (path.Length == 0) return;
        if (change is WatcherChangeTypes.Changed && !Matches(path)) return;
        if (Volatile.Read(ref _needWalk) != 0) return;
        if (Volatile.Read(ref _queued) >= 256)
        {
            Interlocked.Exchange(ref _needWalk, 1);
            return;
        }
        Interlocked.Increment(ref _queued);
        _events.Enqueue((change, path));
    }

    private void OnError(object sender, ErrorEventArgs e)
    {
        DisposeWatcher();
        Interlocked.Exchange(ref _needWalk, 1);
    }

    private void DisposeWatcher()
    {
        var watcher = _watcher;
        _watcher = null;
        if (watcher is null) return;
        try
        {
            watcher.EnableRaisingEvents = false;
            watcher.Created -= OnEvent;
            watcher.Changed -= OnEvent;
            watcher.Deleted -= OnEvent;
            watcher.Renamed -= OnRenamed;
            watcher.Error -= OnError;
            watcher.Dispose();
        }
        catch { }
    }
}
