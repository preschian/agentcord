//! Detect the active Cursor agent session on Windows.
//!
//! Port of macOS `CursorSession.swift`:
//!   - Newest `~/.cursor/projects/**/agent-transcripts/**/*.jsonl` within the
//!     active window (default 60s) counts as the live session
//!   - Enrich with `~/.cursor/chats/**/<session-id>/meta.json` (cwd, createdAtMs)

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");

/// A transcript counts as active if modified within this window (macOS default).
pub const default_active_window_ms: i64 = 60_000;

pub const SessionInfo = struct {
    project_name: [96]u8 = .{0} ** 96,
    project_len: usize = 0,
    session_id: [64]u8 = .{0} ** 64,
    session_id_len: usize = 0,
    cwd: [260]u8 = .{0} ** 260,
    cwd_len: usize = 0,
    start_epoch_ms: i64 = 0,
    /// Ranking clock: max(transcript mtime, meta updatedAtMs).
    activity_ms: i64 = 0,
    total_tokens: i64 = 0,

    pub fn project(self: *const SessionInfo) []const u8 {
        return self.project_name[0..self.project_len];
    }
    pub fn sessionId(self: *const SessionInfo) []const u8 {
        return self.session_id[0..self.session_id_len];
    }
    pub fn cwdPath(self: *const SessionInfo) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    pub fn setField(buf: []u8, len: *usize, value: []const u8) void {
        win32_fs.copyBounded(buf, len, value);
    }
};

pub fn isInstalled() bool {
    if (builtin.os.tag != .windows) return false;
    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return false;
    var path_buf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\.cursor\\projects", .{home}) catch return false;
    return win32_fs.isDirectory(path);
}

/// Scan for the newest live Cursor agent transcript. Null when none is active.
pub fn scan() ?SessionInfo {
    return scanWithWindow(default_active_window_ms, win32_fs.nowEpochMs());
}

pub fn scanWithWindow(active_window_ms: i64, now_ms: i64) ?SessionInfo {
    if (builtin.os.tag != .windows) return null;

    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return null;

    var projects_buf: [320]u8 = undefined;
    const projects = std.fmt.bufPrint(&projects_buf, "{s}\\.cursor\\projects", .{home}) catch return null;
    if (!win32_fs.isDirectory(projects)) return null;

    var newest_path: [700]u8 = undefined;
    var newest_len: usize = 0;
    var newest_mtime: i64 = 0;
    var walk = WalkNewest{
        .newest_path = &newest_path,
        .newest_len = &newest_len,
        .newest_mtime = &newest_mtime,
    };
    win32_fs.walkFiles(projects, 12, &walk, WalkNewest.onTranscript);

    if (newest_len == 0) return null;
    const transcript = newest_path[0..newest_len];
    if (now_ms - newest_mtime > active_window_ms) return null;

    const session_id = sessionIdFromTranscript(transcript);
    if (session_id.len == 0) return null;

    var info: SessionInfo = .{};
    SessionInfo.setField(&info.session_id, &info.session_id_len, session_id);
    info.activity_ms = newest_mtime;
    info.start_epoch_ms = newest_mtime;

    var chats_buf: [320]u8 = undefined;
    const chats = std.fmt.bufPrint(&chats_buf, "{s}\\.cursor\\chats", .{home}) catch return info;
    if (win32_fs.isDirectory(chats)) {
        var meta_path: [700]u8 = undefined;
        if (findMetaPath(chats, session_id, &meta_path)) |meta| {
            applyMeta(meta, &info, newest_mtime);
        }
    }

    if (info.project_len == 0) {
        const fallback = projectFromTranscriptPath(transcript);
        SessionInfo.setField(&info.project_name, &info.project_len, if (fallback.len > 0) fallback else "Cursor");
    }
    return info;
}

const WalkNewest = struct {
    newest_path: []u8,
    newest_len: *usize,
    newest_mtime: *i64,

    fn onTranscript(self: *@This(), path: []const u8) void {
        if (!std.mem.endsWith(u8, path, ".jsonl")) return;
        if (std.mem.indexOf(u8, path, "agent-transcripts") == null) return;
        const mtime = win32_fs.fileMtimeMs(path) orelse return;
        if (self.newest_len.* != 0 and mtime <= self.newest_mtime.*) return;
        const n = @min(path.len, self.newest_path.len);
        @memcpy(self.newest_path[0..n], path[0..n]);
        self.newest_len.* = n;
        self.newest_mtime.* = mtime;
    }
};

fn sessionIdFromTranscript(path: []const u8) []const u8 {
    const base = win32_fs.basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) {
        return base[0 .. base.len - ".jsonl".len];
    }
    return base;
}

fn findMetaPath(chats_root: []const u8, session_id: []const u8, out: []u8) ?[]const u8 {
    var found: [700]u8 = undefined;
    var found_len: usize = 0;
    var search = MetaSearch{
        .session_id = session_id,
        .found = &found,
        .found_len = &found_len,
    };
    win32_fs.walkFiles(chats_root, 8, &search, MetaSearch.onMeta);
    if (found_len == 0) return null;
    const n = @min(found_len, out.len);
    @memcpy(out[0..n], found[0..n]);
    return out[0..n];
}

const MetaSearch = struct {
    session_id: []const u8,
    found: []u8,
    found_len: *usize,

    fn onMeta(self: *@This(), path: []const u8) void {
        if (self.found_len.* > 0) return;
        if (!std.mem.endsWith(u8, path, "\\meta.json") and !std.mem.endsWith(u8, path, "/meta.json")) return;
        // Parent directory name is the session id.
        const slash = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return;
        const parent = win32_fs.basename(path[0..slash]);
        if (!std.mem.eql(u8, parent, self.session_id)) return;
        const n = @min(path.len, self.found.len);
        @memcpy(self.found[0..n], path[0..n]);
        self.found_len.* = n;
    }
};

fn applyMeta(meta_path: []const u8, info: *SessionInfo, transcript_mtime: i64) void {
    var buf: [8 * 1024]u8 = undefined;
    const json = win32_fs.readFile(meta_path, &buf) orelse return;

    if (json_lite.extractString(json, "cwd")) |cwd_raw| {
        var cwd_buf: [260]u8 = undefined;
        if (json_lite.jsonUnescape(cwd_raw, &cwd_buf)) |cwd| {
            SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);
            const base = win32_fs.basename(cwd);
            if (base.len > 0) {
                SessionInfo.setField(&info.project_name, &info.project_len, base);
            }
        }
    }
    if (json_lite.extractI64(json, "createdAtMs")) |created| {
        if (created > 0) info.start_epoch_ms = created;
    }
    // Ranking must not prefer stale meta over a hot transcript.
    var activity = transcript_mtime;
    if (json_lite.extractI64(json, "updatedAtMs")) |updated| {
        if (updated > activity) activity = updated;
    }
    info.activity_ms = activity;
}

/// `.../projects/D-Workspace-agentcord/agent-transcripts/...` → `agentcord`
fn projectFromTranscriptPath(path: []const u8) []const u8 {
    const marker = "\\projects\\";
    const at = std.mem.indexOf(u8, path, marker) orelse return "";
    const rest = path[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\\/") orelse rest.len;
    const encoded = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, encoded, '-')) |dash| {
        const tail = encoded[dash + 1 ..];
        if (tail.len > 0) return tail;
    }
    return encoded;
}

test "sessionIdFromTranscript flat and nested" {
    try std.testing.expectEqualStrings(
        "abc-123",
        sessionIdFromTranscript("C:\\x\\agent-transcripts\\abc-123.jsonl"),
    );
    try std.testing.expectEqualStrings(
        "abc-123",
        sessionIdFromTranscript("C:\\x\\agent-transcripts\\abc-123\\abc-123.jsonl"),
    );
}

test "projectFromTranscriptPath" {
    try std.testing.expectEqualStrings(
        "agentcord",
        projectFromTranscriptPath("C:\\Users\\p\\.cursor\\projects\\D-Workspace-agentcord\\agent-transcripts\\a\\a.jsonl"),
    );
}

test "activity prefers newer of transcript and updatedAtMs" {
    const json =
        \\{"schemaVersion":1,"createdAtMs":1000,"updatedAtMs":2000,"cwd":"D:\\Workspace\\agentcord"}
    ;
    var info: SessionInfo = .{};
    applyMetaFromJson(json, &info, 5000);
    try std.testing.expectEqual(@as(i64, 5000), info.activity_ms);
    try std.testing.expectEqualStrings("agentcord", info.project());

    applyMetaFromJson(json, &info, 1500);
    try std.testing.expectEqual(@as(i64, 2000), info.activity_ms);
}

fn applyMetaFromJson(json: []const u8, info: *SessionInfo, transcript_mtime: i64) void {
    if (json_lite.extractString(json, "cwd")) |cwd_raw| {
        var cwd_buf: [260]u8 = undefined;
        const cwd = json_lite.jsonUnescape(cwd_raw, &cwd_buf).?;
        SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);
        SessionInfo.setField(&info.project_name, &info.project_len, win32_fs.basename(cwd));
    }
    if (json_lite.extractI64(json, "createdAtMs")) |created| {
        if (created > 0) info.start_epoch_ms = created;
    }
    var activity = transcript_mtime;
    if (json_lite.extractI64(json, "updatedAtMs")) |updated| {
        if (updated > activity) activity = updated;
    }
    info.activity_ms = activity;
}
