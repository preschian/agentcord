//! Tiny JSON helpers shared by session scan and billing (no full parser).

const std = @import("std");

/// Walk top-level JSON objects in an array (or bare objects).
pub fn nextObject(json: []const u8, from: *usize) ?[]const u8 {
    var i = from.*;
    while (i < json.len and json[i] != '{') : (i += 1) {}
    if (i >= json.len) return null;
    const start = i;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    const end = i + 1;
                    from.* = end;
                    return json[start..end];
                }
            },
            else => {},
        }
    }
    return null;
}

/// Decode a JSON string body (`\\` → `\`, `\"` → `"`, …) into `out`.
pub fn jsonUnescape(src: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            const mapped: u8 = switch (src[i]) {
                '"', '\\', '/' => src[i],
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => src[i],
            };
            if (o >= out.len) return null;
            out[o] = mapped;
            o += 1;
            i += 1;
        } else {
            if (o >= out.len) return null;
            out[o] = src[i];
            o += 1;
            i += 1;
        }
    }
    return out[0..o];
}

pub fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, pattern)) |key_at| {
        var i = key_at + pattern.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != ':') {
            search_from = key_at + 1;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != '"') {
            search_from = key_at + 1;
            continue;
        }
        i += 1;
        const start = i;
        var escape = false;
        while (i < json.len) : (i += 1) {
            if (escape) {
                escape = false;
                continue;
            }
            if (json[i] == '\\') {
                escape = true;
                continue;
            }
            if (json[i] == '"') {
                return json[start..i];
            }
        }
        return null;
    }
    return null;
}

pub fn extractI64(json: []const u8, key: []const u8) ?i64 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    const key_at = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = key_at + pattern.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    const start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start or (i == start + 1 and json[start] == '-')) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

pub fn extractNumber(json: []const u8, key: []const u8) ?f64 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    const key_at = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = key_at + pattern.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    const start = i;
    if (i < json.len and (json[i] == '-' or json[i] == '+')) i += 1;
    while (i < json.len and ((json[i] >= '0' and json[i] <= '9') or json[i] == '.' or json[i] == 'e' or json[i] == 'E' or json[i] == '+' or json[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, json[start..i]) catch null;
}

/// Percent-encode for paths / form values (RFC 3986 unreserved left alone).
pub fn percentEncode(input: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    for (input) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            if (i >= out.len) return null;
            out[i] = c;
            i += 1;
        } else {
            if (i + 3 > out.len) return null;
            const hex = "0123456789ABCDEF";
            out[i] = '%';
            out[i + 1] = hex[c >> 4];
            out[i + 2] = hex[c & 0xf];
            i += 3;
        }
    }
    return out[0..i];
}

test "percentEncode windows path" {
    var buf: [128]u8 = undefined;
    const enc = percentEncode("D:\\Workspace\\agentcord", &buf).?;
    try std.testing.expectEqualStrings("D%3A%5CWorkspace%5Cagentcord", enc);
}
