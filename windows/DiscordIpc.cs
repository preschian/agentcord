// A hand-written Discord RPC IPC client. No third-party dependencies.
// Implements only the subset needed for Rich Presence: pipe discovery,
// handshake, SET_ACTIVITY, and clearing. Port of AgentCord/DiscordIPC.swift.
//
// Transport: macOS uses a Unix domain socket at $TMPDIR/discord-ipc-{0..9};
// Windows uses a named pipe at \\.\pipe\discord-ipc-{0..9}. Opened with
// NamedPipeClientStream and PipeOptions.Asynchronous, so it uses overlapped
// I/O: a concurrent read loop and writer are safe — matching the macOS design.
// (A synchronous pipe would serialize reads and writes on one file object and
// deadlock a blocking reader against a writer, forcing a write-only loop.)
//
// Frame format on the wire:
//   [ opcode: UInt32 LE ][ payloadLength: UInt32 LE ][ JSON bytes ]

using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgentCord;

public sealed class DiscordIpc : IDisposable
{
    public enum ConnState { Disconnected, Connecting, Connected }

    private enum Opcode : uint { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 }

    // Callbacks may fire on background threads; UI code must marshal itself.
    public event Action<ConnState>? StateChanged;
    public event Action<string>? Error;
    public event Action? Ready;

    public ConnState State { get; private set; } = ConnState.Disconnected;

    private static readonly JsonSerializerOptions WireOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly object _lock = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly int _pid = Environment.ProcessId;

    private string _clientId = "";
    private bool _shouldRun;
    private bool _ready;
    private NamedPipeClientStream? _pipe;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    /// <summary>The last non-null activity we were asked to display, re-sent on
    /// reconnect. Stored as its serialized JSON node for cheap dedup.</summary>
    private JsonNode? _currentActivity;
    private string? _sentSignature;

    // --- Public API

    /// <summary>Begin connecting (and keep reconnecting) using the given
    /// application id. Idempotent while already running with the same id.</summary>
    public void Connect(string clientId)
    {
        lock (_lock)
        {
            if (_shouldRun && _clientId == clientId) return;
            StopLocked(clearFirst: false);
            _clientId = clientId;
            _shouldRun = true;
            _cts = new CancellationTokenSource();
            _loop = Task.Run(() => RunAsync(_cts.Token));
        }
    }

    /// <summary>Stop reconnecting, clear the presence, and close the pipe.</summary>
    public void Disconnect()
    {
        lock (_lock)
        {
            _currentActivity = null;
            StopLocked(clearFirst: true);
            SetState(ConnState.Disconnected);
        }
    }

    /// <summary>Set (or with null, clear) the presence. Deduplicates: an
    /// unchanged payload is not re-sent.</summary>
    public void SetActivity(RichPresence? activity)
    {
        JsonNode? node = activity is null ? null : JsonSerializer.SerializeToNode(activity, WireOptions);
        var signature = node?.ToJsonString() ?? "CLEARED";

        NamedPipeClientStream? pipe;
        lock (_lock)
        {
            _currentActivity = node;
            if (!_ready || signature == _sentSignature) return;
            _sentSignature = signature;
            pipe = _pipe;
        }
        if (pipe is null) return;
        _ = Task.Run(async () =>
        {
            try { await SendActivityAsync(pipe, node, CancellationToken.None); }
            catch { /* the read loop notices the broken pipe and reconnects */ }
        });
    }

    /// <summary>Best-effort synchronous clear, used during app termination so
    /// the presence does not get stuck. Returns quickly either way.</summary>
    public void ClearActivitySync()
    {
        NamedPipeClientStream? pipe;
        lock (_lock)
        {
            if (!_ready) return;
            pipe = _pipe;
        }
        if (pipe is null) return;
        try { SendActivityAsync(pipe, null, CancellationToken.None).Wait(500); }
        catch { }
    }

    public void Dispose()
    {
        lock (_lock) StopLocked(clearFirst: true);
    }

    // --- Connection lifecycle

    /// <summary>Must hold _lock. Cancels the loop and closes the pipe.</summary>
    private void StopLocked(bool clearFirst)
    {
        _shouldRun = false;
        if (clearFirst && _ready && _pipe is { } p)
        {
            try { SendActivityAsync(p, null, CancellationToken.None).Wait(500); }
            catch { }
        }
        _cts?.Cancel();
        _cts = null;
        _loop = null;
        ClosePipeLocked();
    }

    private void ClosePipeLocked()
    {
        _ready = false;
        _sentSignature = null;
        try { _pipe?.Dispose(); } catch { }
        _pipe = null;
    }

    private async Task RunAsync(CancellationToken ct)
    {
        var attempt = 0;
        while (!ct.IsCancellationRequested)
        {
            SetState(ConnState.Connecting);
            var pipe = OpenFirstAvailablePipe();
            if (pipe is null)
            {
                SetState(ConnState.Disconnected);
                if (!await Backoff(++attempt, ct)) return;
                continue;
            }

            lock (_lock)
            {
                _pipe = pipe;
                _ready = false;
                _sentSignature = null;
            }

            try
            {
                var handshake = JsonSerializer.SerializeToUtf8Bytes(
                    new { v = 1, client_id = _clientId });
                await WriteFrameAsync(pipe, Opcode.Handshake, handshake, ct);
                SetState(ConnState.Connected);
                await ReadLoopAsync(pipe, ct);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                // Fall through to reconnect.
            }

            lock (_lock) ClosePipeLocked();
            if (ct.IsCancellationRequested) return;
            SetState(ConnState.Disconnected);
            if (!await Backoff(++attempt, ct)) return;
        }
    }

    /// <summary>Reads frames until the pipe drops. Handles READY (mark ready,
    /// re-send the current activity), PING (reply PONG), ERROR, and CLOSE.</summary>
    private async Task ReadLoopAsync(NamedPipeClientStream pipe, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var frame = await ReadFrameAsync(pipe, ct);
            if (frame is null) return; // peer closed
            var (opcode, payload) = frame.Value;

            switch ((Opcode)opcode)
            {
                case Opcode.Frame:
                    JsonDocument doc;
                    try { doc = JsonDocument.Parse(payload); }
                    catch { continue; }
                    using (doc)
                    {
                        var evt = doc.RootElement.TryGetProperty("evt", out var e) && e.ValueKind == JsonValueKind.String
                            ? e.GetString() : null;
                        if (evt == "READY")
                        {
                            JsonNode? resend;
                            lock (_lock)
                            {
                                _ready = true;
                                resend = _currentActivity;
                                _sentSignature = resend?.ToJsonString() ?? "CLEARED";
                            }
                            Ready?.Invoke();
                            try { await SendActivityAsync(pipe, resend, ct); } catch { return; }
                        }
                        else if (evt == "ERROR")
                        {
                            var message = doc.RootElement.TryGetProperty("data", out var d)
                                && d.ValueKind == JsonValueKind.Object
                                && d.TryGetProperty("message", out var m)
                                && m.ValueKind == JsonValueKind.String
                                ? m.GetString() : null;
                            Error?.Invoke(message ?? "Discord reported an error");
                        }
                    }
                    break;

                case Opcode.Ping:
                    await WriteFrameAsync(pipe, Opcode.Pong, payload, ct);
                    break;

                case Opcode.Close:
                    return;
            }
        }
    }

    private static async Task<bool> Backoff(int attempt, CancellationToken ct)
    {
        // Exponential backoff capped at 30s, matching the macOS client.
        var delay = Math.Min(Math.Pow(2, Math.Min(attempt, 5)), 30.0);
        try { await Task.Delay(TimeSpan.FromSeconds(delay), ct); }
        catch (OperationCanceledException) { return false; }
        return true;
    }

    // --- Framing

    private async Task SendActivityAsync(NamedPipeClientStream pipe, JsonNode? activity, CancellationToken ct)
    {
        // The args object must carry an explicit "activity": null to clear the
        // presence, so it is built as a JsonObject rather than serialized from a
        // model with null-omitting options.
        var command = new JsonObject
        {
            ["cmd"] = "SET_ACTIVITY",
            ["nonce"] = Guid.NewGuid().ToString(),
            ["args"] = new JsonObject
            {
                ["pid"] = _pid,
                ["activity"] = activity?.DeepClone(),
            },
        };
        await WriteFrameAsync(pipe, Opcode.Frame, Encoding.UTF8.GetBytes(command.ToJsonString()), ct);
    }

    private async Task WriteFrameAsync(NamedPipeClientStream pipe, Opcode opcode, byte[] payload, CancellationToken ct)
    {
        var frame = new byte[8 + payload.Length];
        BitConverter.TryWriteBytes(frame.AsSpan(0, 4), (uint)opcode);
        BitConverter.TryWriteBytes(frame.AsSpan(4, 4), (uint)payload.Length);
        payload.CopyTo(frame, 8);

        // Serialize writes: the read loop's PONGs and SetActivity calls would
        // otherwise interleave frames.
        await _writeLock.WaitAsync(ct);
        try
        {
            await pipe.WriteAsync(frame, ct);
            await pipe.FlushAsync(ct);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    /// <summary>Read one frame; null when the peer closed the pipe.</summary>
    private static async Task<(uint Opcode, byte[] Payload)?> ReadFrameAsync(NamedPipeClientStream pipe, CancellationToken ct)
    {
        var header = await ReadExactAsync(pipe, 8, ct);
        if (header is null) return null;
        var opcode = BitConverter.ToUInt32(header, 0);
        var length = BitConverter.ToUInt32(header, 4);
        if (length == 0) return (opcode, []);
        var payload = await ReadExactAsync(pipe, (int)length, ct);
        return payload is null ? null : (opcode, payload);
    }

    private static async Task<byte[]?> ReadExactAsync(NamedPipeClientStream pipe, int count, CancellationToken ct)
    {
        var buffer = new byte[count];
        var total = 0;
        while (total < count)
        {
            int n;
            try { n = await pipe.ReadAsync(buffer.AsMemory(total, count - total), ct); }
            catch (IOException) { return null; }
            if (n <= 0) return null;
            total += n;
        }
        return buffer;
    }

    // --- Pipe discovery

    /// <summary>Open the first available \\.\pipe\discord-ipc-{0..9}.</summary>
    private static NamedPipeClientStream? OpenFirstAvailablePipe()
    {
        for (var i = 0; i <= 9; i++)
        {
            var pipe = new NamedPipeClientStream(
                ".", $"discord-ipc-{i}", PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                pipe.Connect(200);
                return pipe;
            }
            catch
            {
                pipe.Dispose();
            }
        }
        return null;
    }

    // --- Helpers

    private void SetState(ConnState newState)
    {
        if (State == newState) return;
        State = newState;
        StateChanged?.Invoke(newState);
    }
}
