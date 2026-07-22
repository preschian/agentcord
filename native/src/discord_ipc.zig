//! Minimal Discord Rich Presence IPC client for Windows.
//!
//! Transport: named pipe `\\.\pipe\discord-ipc-{0..9}`
//! Wire format: 8-byte little-endian header + JSON payload
//!   [ opcode: u32 LE ][ length: u32 LE ][ payload bytes ]
//!
//! Implements the subset AgentCord needs: handshake, READY, SET_ACTIVITY,
//! ping/pong, reconnect with backoff, and clear-on-stop.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Opcode = enum(u32) {
    handshake = 0,
    frame = 1,
    close = 2,
    ping = 3,
    pong = 4,
};

pub const ConnState = enum {
    disconnected,
    connecting,
    connected,
};

/// Snapshot for the UI thread. Strings live in fixed buffers.
pub const Snapshot = struct {
    state: ConnState = .disconnected,
    ready: bool = false,
    last_error: [128]u8 = .{0} ** 128,
    last_error_len: usize = 0,

    pub fn errorSlice(self: *const Snapshot) []const u8 {
        return self.last_error[0..self.last_error_len];
    }
};

/// Activity fields the UI can set. Empty slices omit the field on the wire.
pub const Activity = struct {
    type: i32 = 0, // 0 Playing, 2 Listening, 3 Watching, 5 Competing
    name: []const u8 = "agentcord",
    details: []const u8 = "",
    state: []const u8 = "",
    large_image: []const u8 = "logo-grok",
    large_text: []const u8 = "Grok",
    small_image: []const u8 = "",
    small_text: []const u8 = "",
    start_ms: i64 = 0, // 0 = omit timestamps
    button_label: []const u8 = "What is Claude Code",
    button_url: []const u8 = "https://www.anthropic.com",
};

const INVALID_HANDLE = windows.INVALID_HANDLE_VALUE;
const GENERIC_READ: windows.DWORD = 0x80000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;

pub const Client = struct {
    /// Zig 0.16: blocking mutex lives on `std.Io`; this spin-style lock is enough
    /// for short critical sections between the UI thread and the IPC worker.
    mutex: std.atomic.Mutex = .unlocked,
    should_run: bool = false,
    ready: bool = false,
    state: ConnState = .disconnected,
    client_id: [32]u8 = undefined,
    client_id_len: usize = 0,
    activity_json: [2048]u8 = undefined,
    activity_json_len: usize = 0,
    activity_dirty: bool = false,
    clear_requested: bool = false,
    has_activity: bool = false,
    last_error: [128]u8 = .{0} ** 128,
    last_error_len: usize = 0,
    thread: ?std.Thread = null,
    pipe: ?windows.HANDLE = null,
    pid: u32 = 0,
    nonce: u32 = 1,

    pub fn init() Client {
        return .{
            .pid = if (builtin.os.tag == .windows) windows.GetCurrentProcessId() else 0,
        };
    }

    fn lock(self: *Client) void {
        while (!self.mutex.tryLock()) {
            if (builtin.os.tag == .windows) Sleep(1) else std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Client) void {
        self.mutex.unlock();
    }

    /// Begin connecting with the given Discord Application ID.
    pub fn connect(self: *Client, client_id: []const u8) void {
        if (builtin.os.tag != .windows) {
            self.setError("Discord IPC is only implemented on Windows in this prototype");
            return;
        }

        self.lock();
        const already = self.should_run and std.mem.eql(u8, self.clientIdSlice(), client_id);
        self.unlock();
        if (already) return;

        self.disconnect();

        self.lock();
        const n = @min(client_id.len, self.client_id.len);
        @memcpy(self.client_id[0..n], client_id[0..n]);
        self.client_id_len = n;
        self.should_run = true;
        self.state = .connecting;
        self.clearErrorLocked();
        self.unlock();

        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            self.lock();
            self.should_run = false;
            self.state = .disconnected;
            self.setErrorLocked("failed to spawn Discord IPC thread");
            self.unlock();
            return;
        };
    }

    /// Stop reconnecting and clear presence (best-effort).
    pub fn disconnect(self: *Client) void {
        self.lock();
        self.should_run = false;
        if (self.ready) {
            if (self.pipe) |pipe| {
                self.sendActivityUnlocked(pipe, null) catch {};
            }
        }
        self.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        self.lock();
        self.state = .disconnected;
        self.ready = false;
        if (self.pipe) |pipe| {
            windows.CloseHandle(pipe);
            self.pipe = null;
        }
        self.unlock();
    }

    /// Set (or clear with null) the activity. Dedupes identical payloads.
    pub fn setActivity(self: *Client, activity: ?Activity) void {
        self.lock();
        defer self.unlock();

        if (activity) |act| {
            var buf: [2048]u8 = undefined;
            const json = buildActivityJson(&buf, act) catch {
                self.setErrorLocked("activity JSON too large");
                return;
            };
            if (self.has_activity and std.mem.eql(u8, self.activityJsonSlice(), json)) return;
            @memcpy(self.activity_json[0..json.len], json);
            self.activity_json_len = json.len;
            self.has_activity = true;
            self.clear_requested = false;
            self.activity_dirty = true;
        } else {
            if (!self.has_activity and !self.clear_requested) return;
            self.has_activity = false;
            self.activity_json_len = 0;
            self.clear_requested = true;
            self.activity_dirty = true;
        }
    }

    pub fn snapshot(self: *Client) Snapshot {
        self.lock();
        defer self.unlock();
        var snap: Snapshot = .{
            .state = self.state,
            .ready = self.ready,
            .last_error_len = self.last_error_len,
        };
        @memcpy(snap.last_error[0..self.last_error_len], self.last_error[0..self.last_error_len]);
        return snap;
    }

    fn clientIdSlice(self: *const Client) []const u8 {
        return self.client_id[0..self.client_id_len];
    }

    fn activityJsonSlice(self: *const Client) []const u8 {
        return self.activity_json[0..self.activity_json_len];
    }

    fn setError(self: *Client, msg: []const u8) void {
        self.lock();
        defer self.unlock();
        self.setErrorLocked(msg);
    }

    fn setErrorLocked(self: *Client, msg: []const u8) void {
        const n = @min(msg.len, self.last_error.len);
        @memcpy(self.last_error[0..n], msg[0..n]);
        self.last_error_len = n;
    }

    fn clearErrorLocked(self: *Client) void {
        self.last_error_len = 0;
    }

    fn setState(self: *Client, state: ConnState) void {
        self.lock();
        defer self.unlock();
        self.state = state;
    }

    fn workerMain(self: *Client) void {
        var attempt: u32 = 0;
        while (true) {
            self.lock();
            const running = self.should_run;
            self.unlock();
            if (!running) break;

            self.setState(.connecting);
            const pipe = openFirstPipe() orelse {
                self.setState(.disconnected);
                attempt += 1;
                if (!self.backoff(attempt)) break;
                continue;
            };

            self.lock();
            self.pipe = pipe;
            self.ready = false;
            self.unlock();

            if (!self.doHandshake(pipe)) {
                self.closePipe();
                attempt += 1;
                if (!self.backoff(attempt)) break;
                continue;
            }

            self.setState(.connected);
            attempt = 0;
            self.readLoop(pipe);
            self.closePipe();

            self.lock();
            const still = self.should_run;
            self.unlock();
            if (!still) break;
            self.setState(.disconnected);
            attempt += 1;
            if (!self.backoff(attempt)) break;
        }

        self.lock();
        self.ready = false;
        self.state = .disconnected;
        self.unlock();
    }

    fn backoff(self: *Client, attempt: u32) bool {
        // Cap at 30s, matching AgentCord's C#/Swift clients.
        const capped = @min(attempt, 5);
        const secs: u64 = @min(std.math.pow(u64, 2, capped), 30);
        var waited: u64 = 0;
        while (waited < secs * 1000) {
            self.lock();
            const running = self.should_run;
            self.unlock();
            if (!running) return false;
            Sleep(100);
            waited += 100;
        }
        return true;
    }

    fn doHandshake(self: *Client, pipe: windows.HANDLE) bool {
        var payload_buf: [128]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"v\":1,\"client_id\":\"{s}\"}}", .{self.clientIdSlice()}) catch return false;
        self.writeFrame(pipe, .handshake, payload) catch {
            self.setError("handshake write failed");
            return false;
        };
        return true;
    }

    fn readLoop(self: *Client, pipe: windows.HANDLE) void {
        while (true) {
            self.lock();
            const running = self.should_run;
            const dirty = self.activity_dirty;
            const has = self.has_activity;
            const clear = self.clear_requested;
            var act_copy: [2048]u8 = undefined;
            const act_len = self.activity_json_len;
            if (has and act_len > 0) {
                @memcpy(act_copy[0..act_len], self.activity_json[0..act_len]);
            }
            if (dirty) self.activity_dirty = false;
            const is_ready = self.ready;
            self.unlock();

            if (!running) return;

            if (dirty and is_ready) {
                if (has) {
                    self.sendActivityUnlocked(pipe, act_copy[0..act_len]) catch {
                        self.setError("SET_ACTIVITY write failed");
                        return;
                    };
                } else if (clear) {
                    self.sendActivityUnlocked(pipe, null) catch {
                        self.setError("clear activity write failed");
                        return;
                    };
                }
            }

            var avail: windows.DWORD = 0;
            if (!PeekNamedPipe(pipe, null, 0, null, &avail, null).toBool()) {
                return;
            }

            if (avail < 8) {
                Sleep(50);
                continue;
            }

            var header: [8]u8 = undefined;
            self.readExact(pipe, &header) catch return;
            const opcode: u32 = std.mem.readInt(u32, header[0..4], .little);
            const length: u32 = std.mem.readInt(u32, header[4..8], .little);
            if (length > 65536) return;

            var payload_storage: [65536]u8 = undefined;
            const payload = payload_storage[0..length];
            if (length > 0) {
                self.readExact(pipe, payload) catch return;
            }

            switch (@as(Opcode, @enumFromInt(opcode))) {
                .frame => self.handleFrame(pipe, payload),
                .ping => {
                    self.writeFrame(pipe, .pong, payload) catch return;
                },
                .close => return,
                .handshake, .pong => {},
            }
        }
    }

    fn handleFrame(self: *Client, pipe: windows.HANDLE, payload: []const u8) void {
        if (std.mem.indexOf(u8, payload, "\"evt\":\"READY\"") != null or
            std.mem.indexOf(u8, payload, "\"evt\": \"READY\"") != null)
        {
            self.lock();
            self.ready = true;
            self.clearErrorLocked();
            const has = self.has_activity;
            var act_copy: [2048]u8 = undefined;
            const act_len = self.activity_json_len;
            if (has and act_len > 0) {
                @memcpy(act_copy[0..act_len], self.activity_json[0..act_len]);
            }
            self.activity_dirty = false;
            self.unlock();

            if (has) {
                self.sendActivityUnlocked(pipe, act_copy[0..act_len]) catch {};
            }
            return;
        }

        if (std.mem.indexOf(u8, payload, "\"evt\":\"ERROR\"") != null or
            std.mem.indexOf(u8, payload, "\"evt\": \"ERROR\"") != null)
        {
            self.setError("Discord reported an ERROR event");
        }
    }

    fn sendActivityUnlocked(self: *Client, pipe: windows.HANDLE, activity_json: ?[]const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        const nonce = self.nonce;
        self.nonce +%= 1;

        try w.writeAll("{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"");
        try w.print("{d}", .{nonce});
        try w.writeAll("\",\"args\":{\"pid\":");
        try w.print("{d}", .{self.pid});
        try w.writeAll(",\"activity\":");
        if (activity_json) |json| {
            try w.writeAll(json);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}}");

        try self.writeFrame(pipe, .frame, w.buffered());
    }

    fn writeFrame(self: *Client, pipe: windows.HANDLE, opcode: Opcode, payload: []const u8) !void {
        _ = self;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intFromEnum(opcode), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);

        try writeAll(pipe, &header);
        if (payload.len > 0) try writeAll(pipe, payload);
    }

    fn readExact(self: *Client, pipe: windows.HANDLE, buf: []u8) !void {
        _ = self;
        var filled: usize = 0;
        while (filled < buf.len) {
            var n: windows.DWORD = 0;
            if (!ReadFile(pipe, buf[filled..].ptr, @intCast(buf.len - filled), &n, null).toBool()) {
                return error.ReadFailed;
            }
            if (n == 0) return error.PipeClosed;
            filled += n;
        }
    }

    fn closePipe(self: *Client) void {
        self.lock();
        defer self.unlock();
        self.ready = false;
        if (self.pipe) |pipe| {
            windows.CloseHandle(pipe);
            self.pipe = null;
        }
    }
};

fn writeAll(pipe: windows.HANDLE, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        var n: windows.DWORD = 0;
        if (!WriteFile(pipe, buf[sent..].ptr, @intCast(buf.len - sent), &n, null).toBool()) {
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

fn openFirstPipe() ?windows.HANDLE {
    var i: u8 = 0;
    while (i <= 9) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "\\\\.\\pipe\\discord-ipc-{d}", .{i}) catch continue;

        var wide: [65]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(wide[0..64], path) catch continue;
        wide[wide_len] = 0;

        const handle = CreateFileW(
            wide[0..wide_len :0].ptr,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle != INVALID_HANDLE) return handle;
    }
    return null;
}

fn buildActivityJson(buf: []u8, act: Activity) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);

    try w.writeAll("{");
    try w.print("\"type\":{d}", .{act.type});
    try w.writeAll(",\"name\":");
    try writeJsonString(&w, act.name);

    if (act.details.len > 0) {
        try w.writeAll(",\"details\":");
        try writeJsonString(&w, act.details);
    }
    if (act.state.len > 0) {
        try w.writeAll(",\"state\":");
        try writeJsonString(&w, act.state);
    }
    if (act.start_ms > 0) {
        try w.print(",\"timestamps\":{{\"start\":{d}}}", .{act.start_ms});
    }

    try w.writeAll(",\"assets\":{");
    var first_asset = true;
    if (act.large_image.len > 0) {
        try w.writeAll("\"large_image\":");
        try writeJsonString(&w, act.large_image);
        first_asset = false;
    }
    if (act.large_text.len > 0) {
        if (!first_asset) try w.writeAll(",");
        try w.writeAll("\"large_text\":");
        try writeJsonString(&w, act.large_text);
        first_asset = false;
    }
    if (act.small_image.len > 0) {
        if (!first_asset) try w.writeAll(",");
        try w.writeAll("\"small_image\":");
        try writeJsonString(&w, act.small_image);
        first_asset = false;
    }
    if (act.small_text.len > 0) {
        if (!first_asset) try w.writeAll(",");
        try w.writeAll("\"small_text\":");
        try writeJsonString(&w, act.small_text);
    }
    try w.writeAll("}");

    if (act.button_label.len > 0 and act.button_url.len > 0) {
        try w.writeAll(",\"buttons\":[{");
        try w.writeAll("\"label\":");
        try writeJsonString(&w, act.button_label);
        try w.writeAll(",\"url\":");
        try writeJsonString(&w, act.button_url);
        try w.writeAll("}]");
    }

    try w.writeAll("}");
    return w.buffered();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "buildActivityJson includes type and name" {
    const act = Activity{
        .type = 0,
        .name = "Opus 4.8",
        .details = "Working on: agentcord",
        .state = "12.3K tokens",
        .start_ms = 1_700_000_000_000,
    };
    var buf: [2048]u8 = undefined;
    const json = try buildActivityJson(&buf, act);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Opus 4.8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"details\":\"Working on: agentcord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamps\":{\"start\":1700000000000}") != null);
}
