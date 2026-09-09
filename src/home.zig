//! The user's nam-zig folder: amp profiles, captures, the standardized
//! capture signal, and the saved settings. Resolved from `NAM_ZIG_HOME`,
//! else `<Music>/nam-zig` in the user's home directory.

const std = @import("std");
const builtin = @import("builtin");
const data = @import("data.zig");

pub const Env = std.process.Environ.Map;

pub const Home = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    profiles: []const u8,
    captures: []const u8,
    config_path: []const u8,
    signal_path: []const u8,

    pub fn resolve(allocator: std.mem.Allocator, io: std.Io, env: *const Env) !Home {
        const root = if (env.get("NAM_ZIG_HOME")) |explicit|
            try allocator.dupe(u8, explicit)
        else blk: {
            const base = env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return error.NoHomeDirectory;
            break :blk try std.fs.path.join(allocator, &.{ base, "Music", "nam-zig" });
        };
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .profiles = try std.fs.path.join(allocator, &.{ root, "profiles" }),
            .captures = try std.fs.path.join(allocator, &.{ root, "captures" }),
            .config_path = try std.fs.path.join(allocator, &.{ root, "config.txt" }),
            .signal_path = try std.fs.path.join(allocator, &.{ root, "v3_0_0.wav" }),
        };
    }

    /// Creates the folder tree when missing.
    pub fn ensure(self: *const Home) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.root);
        try std.Io.Dir.cwd().createDirPath(self.io, self.profiles);
        try std.Io.Dir.cwd().createDirPath(self.io, self.captures);
    }

    pub fn exists(self: *const Home, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Opens `path` in the desktop file manager (Finder, the XDG default,
    /// Explorer); best effort.
    pub fn openInFileManager(self: *const Home, path: []const u8) void {
        openExternal(self.io, path);
    }

    /// The standardized v3 capture signal: the file in the home folder when
    /// present and byte-exact, else downloaded through curl and verified by
    /// MD5. Returns the path.
    pub fn ensureCaptureSignal(self: *const Home, stdout: *std.Io.Writer) ![]const u8 {
        if (self.exists(self.signal_path)) {
            if (try self.signalIsExact(self.signal_path)) return self.signal_path;
            try stdout.print("note: {s} is not the exact v3 capture file; downloading a fresh copy\n", .{self.signal_path});
        }
        try stdout.print("downloading the standardized capture signal (v3_0_0.wav, about 27 MB) to {s} ...\n", .{self.signal_path});
        try stdout.flush();
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.part", .{self.signal_path});
        defer self.allocator.free(tmp);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "curl", "-sSL", "--max-time", "900", "-o", tmp, capture_signal_url },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| {
            try stdout.print("error: could not run curl ({s}). Download v3_0_0.wav yourself from {s} and save it as {s}\n", .{ @errorName(err), capture_signal_page, self.signal_path });
            return error.DownloadFailed;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            try stdout.print("error: download failed ({s}). Download v3_0_0.wav yourself from {s} and save it as {s}\n", .{ std.mem.trim(u8, result.stderr, " \r\n"), capture_signal_page, self.signal_path });
            return error.DownloadFailed;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, tmp, self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(bytes);
        std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        if (data.detectInputVersion(bytes) != .v3_0_0) {
            try stdout.print("error: the downloaded file is not the v3 capture signal (checksum mismatch). Download it yourself from {s} and save it as {s}\n", .{ capture_signal_page, self.signal_path });
            return error.DownloadFailed;
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.signal_path, .data = bytes });
        try stdout.print("saved {s} (checksum verified)\n", .{self.signal_path});
        return self.signal_path;
    }

    fn signalIsExact(self: *const Home, path: []const u8) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024 * 1024)) catch return false;
        defer self.allocator.free(bytes);
        return data.detectInputVersion(bytes) == .v3_0_0;
    }
};

pub const capture_signal_url = "https://drive.google.com/uc?export=download&id=1Pgf8PdE0rKB1TD4TRPKbpNo1ByR3IOm9";
pub const capture_signal_page = "https://drive.google.com/file/d/1Pgf8PdE0rKB1TD4TRPKbpNo1ByR3IOm9/view";

/// Opens a path or URL with the desktop's default handler; best effort,
/// waits for the launcher to return.
pub fn openExternal(io: std.Io, target: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", target },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", target },
        else => &.{ "xdg-open", target },
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

/// Saved settings: `key=value` lines. Unknown keys are ignored; missing
/// keys keep their defaults, so the file can be edited by hand.
pub const Config = struct {
    capture: ?[]const u8 = null,
    playback: ?[]const u8 = null,
    chain: ?[]const u8 = null,
    out_gain_db: f32 = 0,
    in_trim_db: f32 = 0,
    normalize: bool = true,
    gate_on: bool = true,
    gate_db: f32 = -65,
    period: u32 = 64,

    /// Missing file = defaults. String values are duplicated with `allocator`.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer allocator.free(text);
        return parse(allocator, text);
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Config {
        var config: Config = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "capture")) {
                config.capture = if (value.len == 0) null else try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "playback")) {
                config.playback = if (value.len == 0) null else try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "chain")) {
                config.chain = if (value.len == 0) null else try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "out_gain_db")) {
                config.out_gain_db = std.fmt.parseFloat(f32, value) catch config.out_gain_db;
            } else if (std.mem.eql(u8, key, "in_trim_db")) {
                config.in_trim_db = std.fmt.parseFloat(f32, value) catch config.in_trim_db;
            } else if (std.mem.eql(u8, key, "gate_db")) {
                config.gate_db = std.fmt.parseFloat(f32, value) catch config.gate_db;
            } else if (std.mem.eql(u8, key, "normalize")) {
                config.normalize = parseBool(value) orelse config.normalize;
            } else if (std.mem.eql(u8, key, "gate_on")) {
                config.gate_on = parseBool(value) orelse config.gate_on;
            } else if (std.mem.eql(u8, key, "period")) {
                config.period = std.fmt.parseInt(u32, value, 10) catch config.period;
            }
        }
        return config;
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("# nam-zig settings (saved by the app; edit by hand if you like)\n");
        try w.print("capture={s}\n", .{self.capture orelse ""});
        try w.print("playback={s}\n", .{self.playback orelse ""});
        try w.print("chain={s}\n", .{self.chain orelse ""});
        try w.print("out_gain_db={d:.1}\n", .{self.out_gain_db});
        try w.print("in_trim_db={d:.1}\n", .{self.in_trim_db});
        try w.print("normalize={s}\n", .{if (self.normalize) "on" else "off"});
        try w.print("gate_on={s}\n", .{if (self.gate_on) "on" else "off"});
        try w.print("gate_db={d:.1}\n", .{self.gate_db});
        try w.print("period={d}\n", .{self.period});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
    }
};

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "on") or std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

test "config round trip through the text form" {
    const allocator = std.testing.allocator;
    var config = Config{ .capture = "Scarlett 2i2 USB", .playback = "Scarlett 2i2 USB", .chain = "Deluxe Reverb.nam", .out_gain_db = 3, .in_trim_db = -2, .normalize = false, .gate_on = true, .gate_db = -70, .period = 32 };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("capture={s}\nplayback={s}\nchain={s}\nout_gain_db={d}\nin_trim_db={d}\nnormalize=off\ngate_on=on\ngate_db={d}\nperiod={d}\n# comment\nunknown=1\n", .{ config.capture.?, config.playback.?, config.chain.?, config.out_gain_db, config.in_trim_db, config.gate_db, config.period });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try Config.parse(arena.allocator(), aw.written());
    try std.testing.expectEqualStrings(config.capture.?, parsed.capture.?);
    try std.testing.expectEqualStrings(config.playback.?, parsed.playback.?);
    try std.testing.expectEqualStrings(config.chain.?, parsed.chain.?);
    try std.testing.expectEqual(config.out_gain_db, parsed.out_gain_db);
    try std.testing.expectEqual(config.in_trim_db, parsed.in_trim_db);
    try std.testing.expectEqual(config.normalize, parsed.normalize);
    try std.testing.expectEqual(config.gate_on, parsed.gate_on);
    try std.testing.expectEqual(config.gate_db, parsed.gate_db);
    try std.testing.expectEqual(config.period, parsed.period);
    config.capture = null;
    const empty = try Config.parse(arena.allocator(), "capture=\n");
    try std.testing.expect(empty.capture == null);
    try std.testing.expect(empty.normalize);
}
