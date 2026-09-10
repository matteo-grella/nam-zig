//! The window's application: the live session over the home folder's
//! profiles, the saved settings, the microphone permission, the JSON view
//! the page polls, and the controls it posts. Driven by web.zig.

const std = @import("std");
const builtin = @import("builtin");
const live_mod = @import("live.zig");
const audio_mod = @import("audio.zig");
const ui = @import("ui.zig");
const home_mod = @import("home.zig");
const profiles_mod = @import("profiles.zig");
const profile_job = @import("profile_job.zig");

extern fn nam_mic_status() c_int;
extern fn nam_mic_request(timeout_ms: c_uint) c_int;
extern fn nam_window_supported() c_int;
extern fn nam_window_open(url: [*:0]const u8, title: [*:0]const u8, width: c_int, height: c_int) c_int;
extern fn nam_window_close() void;

/// Whether a native window (WebKit on macOS, GTK + WebKitGTK found at
/// runtime on Linux) is available; otherwise the page opens in the browser.
pub fn windowSupported() bool {
    return nam_window_supported() != 0;
}

/// Runs the native window's event loop on the calling (main) thread until
/// the window closes.
pub fn windowOpen(url: [*:0]const u8, title: [*:0]const u8, width: u32, height: u32) void {
    _ = nam_window_open(url, title, @intCast(width), @intCast(height));
}

/// Closes the native window from any thread.
pub fn windowClose() void {
    nam_window_close();
}

/// Closes the window once the page's Quit button flags the Gui.
pub const QuitWatcher = struct {
    gui: *Gui,

    pub fn run(self: *QuitWatcher) void {
        while (!self.gui.quit.load(.acquire)) {
            std.Io.sleep(self.gui.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        windowClose();
    }
};

pub const MicStatus = enum { undetermined, authorized, denied };

/// The microphone permission (macOS); other platforms report authorized.
pub fn micStatus() MicStatus {
    return switch (nam_mic_status()) {
        1 => .authorized,
        2 => .denied,
        else => .undetermined,
    };
}

/// Shows the system prompt when the status is undetermined and waits up to
/// `timeout_ms` for the answer.
pub fn micRequest(timeout_ms: u32) MicStatus {
    return switch (nam_mic_request(timeout_ms)) {
        1 => .authorized,
        2 => .denied,
        else => .undetermined,
    };
}

pub fn lock(m: *std.Io.Mutex) void {
    std.Io.Threaded.mutexLock(m);
}

pub fn unlock(m: *std.Io.Mutex) void {
    std.Io.Threaded.mutexUnlock(m);
}

fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

fn findDevice(devices: []const audio_mod.DeviceInfo, name: ?[]const u8) ?usize {
    const wanted = name orelse return null;
    for (devices, 0..) |*info, index| {
        if (std.mem.eql(u8, info.nameSlice(), wanted)) return index;
    }
    return null;
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
}

fn parseIndex(value: []const u8) ?usize {
    const n = std.fmt.parseInt(i64, value, 10) catch return null;
    if (n < 0) return null;
    return @intCast(n);
}

pub const Gui = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    home: home_mod.Home,
    config_arena: std.heap.ArenaAllocator,
    config: home_mod.Config,
    sample_rate: u32 = 48000,
    frame_cap: usize,
    scratch_in: []f32,
    gate_gains: []f32,
    ping0: []f32,
    ping1: []f32,
    /// Stable address: the audio callback keeps a pointer to it.
    shared: live_mod.Shared,
    audio: audio_mod.Audio,
    set: live_mod.ChainSet,
    session: *live_mod.Session,
    mutex: std.Io.Mutex = .init,
    view: ?ui.View = null,
    quit: std.atomic.Value(bool) = .init(false),
    mic: MicStatus = .undetermined,
    /// The amp capture wizard's worker (stable address: the Gui is heap-allocated).
    job: profile_job.Job,

    pub const Options = struct {
        period: ?u32 = null,
        /// Ask for the microphone permission up front (macOS) so the prompt
        /// carries the app's name before the first stream opens.
        request_mic: bool = true,
    };

    pub fn create(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, env: *const home_mod.Env, opts: Options) !*Gui {
        const home = try home_mod.Home.resolve(allocator, io, env);
        try home.ensure();
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer config_arena.deinit();
        const config = try home_mod.Config.load(config_arena.allocator(), io, home.config_path);
        const period = opts.period orelse config.period;
        // Audio-thread scratch sized like the terminal player: input trim
        // buffer + gate gains + two inter-stage ping buffers; the device may
        // deliver blocks above the requested period.
        const frame_cap = @max(@as(usize, 2048), @as(usize, period) * 4);
        const scratch_in = try allocator.alloc(f32, frame_cap);
        errdefer allocator.free(scratch_in);
        const gate_gains = try allocator.alloc(f32, frame_cap);
        errdefer allocator.free(gate_gains);
        const ping0 = try allocator.alloc(f32, frame_cap);
        errdefer allocator.free(ping0);
        const ping1 = try allocator.alloc(f32, frame_cap);
        errdefer allocator.free(ping1);

        const self = try allocator.create(Gui);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .stdout = stdout,
            .home = home,
            .config_arena = config_arena,
            .config = config,
            .frame_cap = frame_cap,
            .scratch_in = scratch_in,
            .gate_gains = gate_gains,
            .ping0 = ping0,
            .ping1 = ping1,
            .shared = .{
                .period = frame_cap,
                .scratch_in = scratch_in,
                .gate_gains = gate_gains,
                .ping = .{ ping0, ping1 },
            },
            .audio = undefined,
            .set = undefined,
            .session = undefined,
            .job = undefined,
        };
        self.job = profile_job.Job.init(self);
        self.mic = if (opts.request_mic) micRequest(30_000) else micStatus();

        self.audio = try audio_mod.Audio.init();
        errdefer self.audio.deinit();
        self.set = try self.buildSet();
        errdefer self.set.deinit();
        self.shared.chains = self.set.chains;
        self.shared.setGain(dbToLinear(config.out_gain_db));
        self.shared.setInputGain(dbToLinear(config.in_trim_db));
        self.shared.normalize.store(config.normalize, .monotonic);

        var capture_storage: [audio_mod.max_devices]audio_mod.DeviceInfo = undefined;
        var playback_storage: [audio_mod.max_devices]audio_mod.DeviceInfo = undefined;
        const capture_devices = try self.audio.listDevices(.capture, &capture_storage);
        const playback_devices = try self.audio.listDevices(.playback, &playback_storage);
        const options = live_mod.Options{
            .capture = findDevice(capture_devices, config.capture),
            .playback = findDevice(playback_devices, config.playback),
            .sample_rate = self.sample_rate,
            .period = period,
            .gain_db = config.out_gain_db,
            .input_gain_db = config.in_trim_db,
            .normalize = config.normalize,
            .gate_db = if (config.gate_on) config.gate_db else null,
        };
        self.session = try live_mod.Session.create(io, allocator, &self.shared, &self.audio, options);
        if (!config.gate_on) self.session.setGateDb(config.gate_db);
        if (config.chain) |name| self.selectChainByName(name);
        return self;
    }

    pub fn destroy(self: *Gui) void {
        self.job.shutdown();
        self.session.destroy();
        self.set.deinit();
        self.audio.deinit();
        self.allocator.free(self.scratch_in);
        self.allocator.free(self.gate_gains);
        self.allocator.free(self.ping0);
        self.allocator.free(self.ping1);
        self.config_arena.deinit();
        self.allocator.destroy(self);
    }

    /// Every profile (and `.chain` manifest) under the home folder's
    /// profiles directory, as preloaded chains. A file that fails to load is
    /// reported and skipped.
    fn buildSet(self: *Gui) !live_mod.ChainSet {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        try profiles_mod.discoverProfiles(self.io, a, self.home.profiles, 3, &paths);
        profiles_mod.sortAndDedupe(&paths);
        var chain_paths: std.ArrayList([]const u8) = .empty;
        try profiles_mod.discoverChains(self.io, a, self.home.profiles, 3, &chain_paths);
        const set = try profiles_mod.buildChains(self.io, self.allocator, self.stdout, .{
            .profile_paths = paths.items,
            .chain_paths = chain_paths.items,
            .sample_rate = self.sample_rate,
            .frame_cap = self.frame_cap,
            .lenient = true,
        });
        self.stdout.flush() catch {};
        return set;
    }

    pub fn selectChainByName(self: *Gui, name: []const u8) void {
        for (self.set.chains, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) {
                self.session.selectChain(i);
                return;
            }
        }
    }

    /// Reloads the profiles folder (new files appear, removed ones go) and
    /// keeps the current chain by name when it still exists. With
    /// `restart_audio` false the stream stays stopped (the amp capture
    /// holds the devices).
    pub fn rescanLocked(self: *Gui, restart_audio: bool) !void {
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (self.set.chains.len > 0) {
            const current = self.set.chains[self.shared.current.load(.monotonic)].name;
            name_len = @min(current.len, name_buf.len);
            @memcpy(name_buf[0..name_len], current[0..name_len]);
        }
        var new_set = try self.buildSet();
        errdefer new_set.deinit();
        if (restart_audio) try self.session.swapChains(new_set.chains) else self.session.replaceChains(new_set.chains);
        var old = self.set;
        self.set = new_set;
        old.deinit();
        self.view = null;
        if (name_len > 0) self.selectChainByName(name_buf[0..name_len]);
    }

    /// The control thread: ~30 Hz session ticks under the lock.
    pub fn tickLoop(self: *Gui) void {
        while (!self.quit.load(.acquire)) {
            lock(&self.mutex);
            self.view = self.session.tick();
            unlock(&self.mutex);
            std.Io.sleep(self.io, .{ .nanoseconds = 33 * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    pub fn requestQuit(self: *Gui) void {
        self.quit.store(true, .release);
    }

    /// Ends a running amp capture (keeping a training run's best epoch)
    /// before the app quits.
    pub fn shutdownJob(self: *Gui) void {
        self.job.shutdown();
    }

    pub fn saveConfig(self: *Gui) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        self.saveConfigLocked();
    }

    fn saveConfigLocked(self: *Gui) void {
        const s = self.session;
        self.config.capture = if (s.capture_index) |i| s.capture_devices[i].nameSlice() else null;
        self.config.playback = if (s.playback_index) |i| s.playback_devices[i].nameSlice() else null;
        self.config.chain = if (self.set.chains.len > 0) self.set.chains[self.shared.current.load(.monotonic)].name else null;
        self.config.out_gain_db = 20.0 * std.math.log10(@max(self.shared.gain(), 1e-6));
        self.config.in_trim_db = 20.0 * std.math.log10(@max(self.shared.inputGain(), 1e-6));
        self.config.normalize = self.shared.normalize.load(.monotonic);
        self.config.gate_on = self.shared.gate_on.load(.monotonic);
        self.config.gate_db = s.gate_db;
        self.config.period = s.options.period;
        self.config.save(self.allocator, self.io, self.home.config_path) catch |err| {
            ui.plainLine(self.io, "settings: could not save {s} ({s})", .{ self.home.config_path, @errorName(err) });
        };
    }

    /// Applies `key=value&...` controls from the page.
    pub fn apply(self: *Gui, query: []const u8) !void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        const s = self.session;
        var save = false;
        // While the amp capture holds the devices, controls that would
        // reopen the stream are ignored (the page hides them too).
        const devices_locked = self.job.audio_held;
        var request = profile_job.Request{};
        var start_job = false;
        var train_anyway = false;
        var retry = false;
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "bypass")) {
                s.setBypass(parseBool(value));
            } else if (std.mem.eql(u8, key, "mute")) {
                s.setMute(parseBool(value));
            } else if (std.mem.eql(u8, key, "normalize")) {
                s.setNormalize(parseBool(value));
                save = true;
            } else if (std.mem.eql(u8, key, "gate")) {
                s.setGate(parseBool(value));
                save = true;
            } else if (std.mem.eql(u8, key, "tuner")) {
                s.setTuner(parseBool(value));
            } else if (std.mem.eql(u8, key, "in_trim_db")) {
                s.setInputGainDb(std.fmt.parseFloat(f32, value) catch continue);
                save = true;
            } else if (std.mem.eql(u8, key, "out_gain_db")) {
                s.setGainDb(std.fmt.parseFloat(f32, value) catch continue);
                save = true;
            } else if (std.mem.eql(u8, key, "gate_db")) {
                s.setGateDb(std.fmt.parseFloat(f32, value) catch continue);
                save = true;
            } else if (std.mem.eql(u8, key, "chain")) {
                s.selectChain(parseIndex(value) orelse continue);
                save = true;
            } else if (std.mem.eql(u8, key, "capture")) {
                if (devices_locked) continue;
                s.selectCapture(parseIndex(value));
                save = true;
            } else if (std.mem.eql(u8, key, "playback")) {
                if (devices_locked) continue;
                s.selectPlayback(parseIndex(value));
                save = true;
            } else if (std.mem.eql(u8, key, "auto_input")) {
                if (devices_locked) continue;
                s.autoInput();
                save = true;
            } else if (std.mem.eql(u8, key, "accept_twin")) {
                if (devices_locked) continue;
                s.acceptSuggestion();
                save = true;
            } else if (std.mem.eql(u8, key, "clear")) {
                s.clearWarnings();
            } else if (std.mem.eql(u8, key, "rescan")) {
                try self.rescanLocked(!devices_locked);
            } else if (std.mem.eql(u8, key, "open_folder")) {
                self.home.openInFileManager(self.home.profiles);
            } else if (std.mem.eql(u8, key, "open_home")) {
                self.home.openInFileManager(self.home.root);
            } else if (std.mem.eql(u8, key, "open_url")) {
                // Only the capture signal's download page.
                var buf: [512]u8 = undefined;
                if (std.mem.eql(u8, profile_job.percentDecode(value, &buf), home_mod.capture_signal_page)) home_mod.openExternal(self.io, home_mod.capture_signal_page);
            } else if (std.mem.startsWith(u8, key, "profile_")) {
                const sub = key["profile_".len..];
                if (std.mem.eql(u8, sub, "open")) {
                    self.job.ensureEstimate();
                } else if (std.mem.eql(u8, sub, "start")) {
                    start_job = true;
                } else if (std.mem.eql(u8, sub, "capture")) {
                    self.job.send(.advance);
                } else if (std.mem.eql(u8, sub, "finish")) {
                    self.job.send(.finish);
                } else if (std.mem.eql(u8, sub, "cancel")) {
                    self.job.send(.cancel);
                } else if (std.mem.eql(u8, sub, "dismiss")) {
                    self.job.dismissLocked();
                } else if (std.mem.eql(u8, sub, "train_anyway")) {
                    train_anyway = true;
                } else if (std.mem.eql(u8, sub, "retry")) {
                    retry = true;
                } else {
                    _ = request.setField(sub, value);
                }
            }
        }
        if (start_job) try self.job.start(request);
        if (train_anyway) try self.job.startTrainAnyway();
        if (retry) try self.job.restart();
        // The reply carries the new state, not the last tick's snapshot.
        self.view = null;
        if (save) self.saveConfigLocked();
    }

    fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    }

    fn jsonBool(b: bool) []const u8 {
        return if (b) "true" else "false";
    }

    /// The page's state document.
    pub fn writeState(self: *Gui, w: *std.Io.Writer) !void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        const s = self.session;
        const v = self.view orelse s.tick();
        try w.writeAll("{");
        try w.print("\"chain_index\":{d},\"chain_count\":{d},\"chain_name\":", .{ v.chain_index, v.chain_count });
        try jsonString(w, v.chain_name);
        try w.print(",\"stage_count\":{d},\"chains\":[", .{v.stage_count});
        for (self.set.chains, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try jsonString(w, c.name);
        }
        try w.print("],\"in_db\":{d:.1},\"out_db\":{d:.1},\"in_trim_db\":{d:.1},\"out_gain_db\":{d:.1},\"gate_db\":{d:.1},", .{ v.in_db, v.out_db, v.in_trim_db, v.out_gain_db, v.gate_db });
        try w.print("\"bypass\":{s},\"mute\":{s},\"normalize\":{s},\"gate\":{s},\"clipped\":{s},\"oversize\":{s},\"silent\":{s},\"audio_running\":{s},", .{
            jsonBool(v.bypass), jsonBool(v.muted), jsonBool(v.normalize), jsonBool(v.gate_on), jsonBool(v.clipped), jsonBool(v.oversize), jsonBool(v.silent), jsonBool(s.audio_running),
        });
        try w.writeAll("\"midi_label\":");
        try jsonString(w, v.midi_label);
        // tuner
        try w.print(",\"tuner\":{{\"on\":{s},\"mode\":\"{s}\",\"note\":", .{ jsonBool(v.tuner_on), @tagName(v.tuner.mode) });
        try jsonString(w, v.tuner.note);
        try w.print(",\"cents\":{d:.1},\"hz\":{d:.2},\"strings\":[", .{ v.tuner.cents, v.tuner.hz });
        for (v.tuner.strings, 0..) |st, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"active\":{s},\"cents\":{d:.1}}}", .{ jsonBool(st.active), st.cents });
        }
        try w.writeAll("]},");
        // devices
        var capture_name: [audio_mod.name_cap]u8 = undefined;
        var playback_name: [audio_mod.name_cap]u8 = undefined;
        if (s.audio_running) self.audio.runningNames(&capture_name, &playback_name) else {
            capture_name[0] = 0;
            playback_name[0] = 0;
        }
        try w.writeAll("\"devices\":{\"capture\":[");
        for (s.capture_devices, 0..) |*info, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try jsonString(w, info.nameSlice());
            try w.print(",\"default\":{s}}}", .{jsonBool(info.is_default)});
        }
        try w.writeAll("],\"playback\":[");
        for (s.playback_devices, 0..) |*info, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try jsonString(w, info.nameSlice());
            try w.print(",\"default\":{s}}}", .{jsonBool(info.is_default)});
        }
        try w.writeAll("],\"capture_index\":");
        if (s.capture_index) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
        try w.writeAll(",\"playback_index\":");
        if (s.playback_index) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
        try w.writeAll(",\"capture_name\":");
        try jsonString(w, std.mem.sliceTo(&capture_name, 0));
        try w.writeAll(",\"playback_name\":");
        try jsonString(w, std.mem.sliceTo(&playback_name, 0));
        try w.writeAll("},");
        const latency = if (s.audio_running) s.latency().total_ms else 0.0;
        try w.print("\"latency_ms\":{d:.1},\"sample_rate\":{d},\"period\":{d},\"suggested_playback\":{s},\"mic\":\"{s}\",\"note\":", .{
            latency, self.audio.actualSampleRate(), s.options.period, jsonBool(s.suggested_playback != null), @tagName(self.mic),
        });
        try jsonString(w, s.note());
        try w.writeAll(",\"home\":");
        try jsonString(w, self.home.root);
        try w.writeAll(",\"profiles_dir\":");
        try jsonString(w, self.home.profiles);
        try w.writeAll(",\"profiler\":");
        try self.job.writeJson(w);
        try w.writeAll("}");
    }
};
