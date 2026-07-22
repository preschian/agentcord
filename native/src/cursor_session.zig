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
    /// Transcript / meta activity time — used to pick among agents.
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
        const n = @min(value.len, buf.len);
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
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
    walkDir(projects, 0, &walk);

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
};

const ChildName = struct {
    name: [260]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,
};

fn collectChildren(dir: []const u8, out: []ChildName) usize {
    var name_buf: [260]u8 = undefined;
    var count: usize = 0;
    const Ctx = struct {
        out: []ChildName,
        count: *usize,
        fn onEntry(self: @This(), entry: win32_fs.DirEntry) void {
            if (self.count.* >= self.out.len) return;
            const n = @min(entry.name.len, self.out[self.count.*].name.len);
            @memcpy(self.out[self.count.*].name[0..n], entry.name[0..n]);
            self.out[self.count.*].len = n;
            self.out[self.count.*].is_dir = entry.kind == .directory;
            self.count.* += 1;
        }
    };
    win32_fs.forEachChild(dir, &name_buf, Ctx{ .out = out, .count = &count }, Ctx.onEntry);
    return count;
}

fn walkDir(dir: []const u8, depth: u8, walk: *WalkNewest) void {
    if (depth > 12) return;
    var child_names: [64]ChildName = undefined;
    const child_count = collectChildren(dir, &child_names);

    for (child_names[0..child_count]) |child| {
        const name = child.name[0..child.len];
        var path_buf: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, name }) catch continue;
        if (child.is_dir) {
            walkDir(path, depth + 1, walk);
            continue;
        }
        if (!std.mem.endsWith(u8, name, ".jsonl")) continue;
        if (!pathContains(path, "agent-transcripts")) continue;
        const mtime = win32_fs.fileMtimeMs(path) orelse continue;
        if (walk.newest_len.* == 0 or mtime > walk.newest_mtime.*) {
            const n = @min(path.len, walk.newest_path.len);
            @memcpy(walk.newest_path[0..n], path[0..n]);
            walk.newest_len.* = n;
            walk.newest_mtime.* = mtime;
        }
    }
}

fn pathContains(path: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, path, needle) != null;
}

fn sessionIdFromTranscript(path: []const u8) []const u8 {
    const base = basename(path);
    if (std.mem.endsWith(u8, base, ".jsonl")) {
        return base[0 .. base.len - ".jsonl".len];
    }
    return base;
}

fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    if (end == 0) return path;
    if (std.mem.lastIndexOfAny(u8, path[0..end], "\\/")) |idx| {
        return path[idx + 1 .. end];
    }
    return path[0..end];
}

fn findMetaPath(chats_root: []const u8, session_id: []const u8, out: []u8) ?[]const u8 {
    var found: [700]u8 = undefined;
    var found_len: usize = 0;
    var search = MetaSearch{
        .session_id = session_id,
        .found = &found,
        .found_len = &found_len,
    };
    walkMeta(chats_root, 0, &search);
    if (found_len == 0) return null;
    const n = @min(found_len, out.len);
    @memcpy(out[0..n], found[0..n]);
    return out[0..n];
}

const MetaSearch = struct {
    session_id: []const u8,
    found: []u8,
    found_len: *usize,
};

fn walkMeta(dir: []const u8, depth: u8, search: *MetaSearch) void {
    if (depth > 8 or search.found_len.* > 0) return;
    var child_names: [64]ChildName = undefined;
    const child_count = collectChildren(dir, &child_names);

    for (child_names[0..child_count]) |child| {
        const name = child.name[0..child.len];
        var path_buf: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, name }) catch continue;
        if (child.is_dir) {
            walkMeta(path, depth + 1, search);
            continue;
        }
        if (!std.mem.eql(u8, name, "meta.json")) continue;
        const parent = basename(dir);
        if (!std.mem.eql(u8, parent, search.session_id)) continue;
        const n = @min(path.len, search.found.len);
        @memcpy(search.found[0..n], path[0..n]);
        search.found_len.* = n;
        return;
    }
}

fn applyMeta(meta_path: []const u8, info: *SessionInfo, transcript_mtime: i64) void {
    var buf: [8 * 1024]u8 = undefined;
    const json = win32_fs.readFile(meta_path, &buf) orelse return;

    if (json_lite.extractString(json, "cwd")) |cwd_raw| {
        var cwd_buf: [260]u8 = undefined;
        if (json_lite.jsonUnescape(cwd_raw, &cwd_buf)) |cwd| {
            SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);
            const base = basename(cwd);
            if (base.len > 0) {
                SessionInfo.setField(&info.project_name, &info.project_len, base);
            }
        }
    }
    if (json_lite.extractI64(json, "createdAtMs")) |created| {
        if (created > 0) info.start_epoch_ms = created;
    }
    if (json_lite.extractI64(json, "updatedAtMs")) |updated| {
        if (updated > 0) info.activity_ms = updated;
    } else {
        info.activity_ms = transcript_mtime;
    }
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

test "applyMeta parses cwd and timestamps" {
    // Unit-level: parse the same shape as real meta.json via json_lite.
    const json =
        \\{"schemaVersion":1,"createdAtMs":1000,"updatedAtMs":2000,"cwd":"D:\\Workspace\\agentcord"}
    ;
    var info: SessionInfo = .{};
    if (json_lite.extractString(json, "cwd")) |cwd_raw| {
        var cwd_buf: [260]u8 = undefined;
        const cwd = json_lite.jsonUnescape(cwd_raw, &cwd_buf).?;
        SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);
        SessionInfo.setField(&info.project_name, &info.project_len, basename(cwd));
    }
    info.start_epoch_ms = json_lite.extractI64(json, "createdAtMs").?;
    info.activity_ms = json_lite.extractI64(json, "updatedAtMs").?;
    try std.testing.expectEqualStrings("agentcord", info.project());
    try std.testing.expectEqual(@as(i64, 1000), info.start_epoch_ms);
    try std.testing.expectEqual(@as(i64, 2000), info.activity_ms);
}
