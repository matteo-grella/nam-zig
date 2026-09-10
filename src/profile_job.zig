//! The window's amp capture: the wizard's worker thread over the profiler
//! pipeline. It borrows the audio devices from the live session (the
//! session stays paused until the wizard is closed, because the rig is
//! wired for reamping and a restarted live stream would feed the amp's
//! output back into its input), runs the level check, the capture, the
//! checks, and the training, then rescans the profiles folder and selects
//! the new profile. The page polls its state and posts commands.

const std = @import("std");
const gui_mod = @import("gui.zig");
const profiler = @import("profiler.zig");
const nam_export = @import("nam_export.zig");
const train_mod = @import("train.zig");
const wav = @import("wav.zig");
const home_mod = @import("home.zig");
const ui = @import("ui.zig");

pub const Phase = enum(u8) {
    idle,
    preparing,
    level_check,
    capturing,
    checking,
    training,
    exporting,
    done,
    failed,
    cancelled,

    pub fn terminal(self: Phase) bool {
        return switch (self) {
            .idle, .done, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// A fixed-capacity string, so the job's state needs no allocation.
fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            self.len = @min(s.len, cap);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn optional(self: *const Self) ?[]const u8 {
            return if (self.len == 0) null else self.slice();
        }
    };
}

pub const gear_types = [_][]const u8{ "amp", "amp_cab", "pedal", "pedal_amp", "amp_pedal_cab", "preamp", "studio" };
pub const tone_types = [_][]const u8{ "clean", "overdrive", "crunch", "hi_gain", "fuzz" };
pub const max_epochs: usize = 1000;

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |a| if (std.mem.eql(u8, a, value)) return true;
    return false;
}

/// Decodes a percent-encoded page value into `buf`.
pub fn percentDecode(encoded: []const u8, buf: []u8) []const u8 {
    const n = @min(encoded.len, buf.len);
    @memcpy(buf[0..n], encoded[0..n]);
    return std.Uri.percentDecodeInPlace(buf[0..n]);
}

/// What the page's form says about the profile to make.
pub const Request = struct {
    name: Text(120) = .{},
    gear_type: Text(24) = .{},
    tone_type: Text(24) = .{},
    gear_make: Text(80) = .{},
    gear_model: Text(80) = .{},
    modeled_by: Text(80) = .{},
    epochs: usize = 100,
    ignore_checks: bool = false,
    /// Train from this saved recording instead of capturing a new one.
    reamp: Text(1024) = .{},

    /// Fills a field from a page control (`profile_<key>=<percent-encoded>`);
    /// returns false for an unknown key. Enumerated fields drop values
    /// outside the upstream vocabulary; the epoch count is clamped.
    pub fn setField(self: *Request, key: []const u8, encoded: []const u8) bool {
        var buf: [1024]u8 = undefined;
        const value = std.mem.trim(u8, percentDecode(encoded, &buf), " \t\r\n");
        if (std.mem.eql(u8, key, "name")) {
            self.name.set(value);
        } else if (std.mem.eql(u8, key, "gear_type")) {
            self.gear_type.set(if (oneOf(value, &gear_types)) value else "");
        } else if (std.mem.eql(u8, key, "tone_type")) {
            self.tone_type.set(if (oneOf(value, &tone_types)) value else "");
        } else if (std.mem.eql(u8, key, "gear_make")) {
            self.gear_make.set(value);
        } else if (std.mem.eql(u8, key, "gear_model")) {
            self.gear_model.set(value);
        } else if (std.mem.eql(u8, key, "modeled_by")) {
            self.modeled_by.set(value);
        } else if (std.mem.eql(u8, key, "epochs")) {
            const n = std.fmt.parseInt(usize, value, 10) catch return true;
            self.epochs = @max(1, @min(n, max_epochs));
        } else return false;
        return true;
    }

    pub fn displayName(self: *const Request) []const u8 {
        return self.name.optional() orelse "My amp";
    }

    pub fn userMetadata(self: *const Request) nam_export.UserMetadata {
        return .{
            .name = self.displayName(),
            .modeled_by = self.modeled_by.optional(),
            .gear_type = self.gear_type.optional(),
            .gear_make = self.gear_make.optional(),
            .gear_model = self.gear_model.optional(),
            .tone_type = self.tone_type.optional(),
        };
    }
};

/// Peak-hold decay per capture report (100 ms): 5 dB/s, so a lowered gain
/// shows within a couple of seconds.
const hold_decay_db: f32 = 0.5;
/// Reports the clip indicator stays lit after a full-scale sample (3 s).
const clip_latch_reports: u32 = 30;

const inf_bits: u64 = @bitCast(std.math.inf(f64));
const floor_db_bits: u32 = @bitCast(@as(f32, -140.0));

pub const Job = struct {
    gui: *gui_mod.Gui,
    io: std.Io,
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.idle)),
    command: std.atomic.Value(u8) = .init(@intFromEnum(profiler.Stop.none)),
    /// The live stream is stopped for the job (guarded by the Gui mutex).
    audio_held: bool = false,
    /// The v3 capture signal is in the folder (refreshed by the worker).
    signal_ready: std.atomic.Value(bool) = .init(false),

    // Level check / capture, written by the worker's reporter.
    position: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    peak_db_bits: std.atomic.Value(u32) = .init(floor_db_bits),
    hold_db_bits: std.atomic.Value(u32) = .init(floor_db_bits),
    clip_age: std.atomic.Value(u32) = .init(clip_latch_reports),
    clipped_total: std.atomic.Value(usize) = .init(0),

    // Training.
    epoch: std.atomic.Value(usize) = .init(0),
    epochs: std.atomic.Value(usize) = .init(0),
    best_esr_bits: std.atomic.Value(u64) = .init(inf_bits),
    last_esr_bits: std.atomic.Value(u64) = .init(inf_bits),
    /// Mean seconds per completed epoch (f64 bits); 0 before the first.
    epoch_seconds_bits: std.atomic.Value(u64) = .init(0),
    stopped_early: std.atomic.Value(bool) = .init(false),
    /// Seconds per epoch from a measured training step; 0 = not measured.
    epoch_estimate_s: f64 = 0,

    // Text, guarded by `mutex`.
    mutex: std.Io.Mutex = .init,
    message: Text(320) = .{},
    detail: Text(512) = .{},
    error_name: Text(64) = .{},
    result_path: Text(1024) = .{},
    result_name: Text(256) = .{},
    reamp_path: Text(1024) = .{},
    request: Request = .{},

    pub fn init(gui: *gui_mod.Gui) Job {
        var job = Job{ .gui = gui, .io = gui.io, .allocator = gui.allocator };
        job.signal_ready.store(gui.home.captureSignalReady(), .monotonic);
        return job;
    }

    pub fn phaseNow(self: *const Job) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    fn setPhase(self: *Job, phase: Phase) void {
        self.phase.store(@intFromEnum(phase), .release);
    }

    /// A worker thread exists and has not reached a terminal phase.
    pub fn active(self: *const Job) bool {
        return self.thread != null and !self.phaseNow().terminal();
    }

    fn lock(self: *Job) void {
        std.Io.Threaded.mutexLock(&self.mutex);
    }

    fn unlock(self: *Job) void {
        std.Io.Threaded.mutexUnlock(&self.mutex);
    }

    fn setMessage(self: *Job, message: []const u8, detail: []const u8) void {
        self.lock();
        defer self.unlock();
        self.message.set(message);
        self.detail.set(detail);
    }

    fn setDetail(self: *Job, detail: []const u8) void {
        self.lock();
        defer self.unlock();
        self.detail.set(detail);
    }

    /// Measures one training step once, for the "about N minutes" the form
    /// shows before training starts. Cheap (a few hundred milliseconds).
    pub fn ensureEstimate(self: *Job) void {
        if (self.epoch_estimate_s > 0) return;
        const spec = train_mod.TrainingSpec{ .classic = train_mod.ModelSpec.classic };
        const cost = profiler.measureTrainStep(self.io, self.allocator, spec, 8192) catch return;
        self.epoch_estimate_s = profiler.estimateEpochSeconds(cost.ms, profiler.v3_signal_frames, spec, 8192, 16);
    }

    /// Posts a command for the worker; `cancel` always wins.
    pub fn send(self: *Job, command: profiler.Stop) void {
        if (command != .cancel and self.phaseNow() == .cancelled) return;
        const current: profiler.Stop = @enumFromInt(self.command.load(.monotonic));
        if (current == .cancel) return;
        self.command.store(@intFromEnum(command), .release);
    }

    fn joinFinished(self: *Job) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn resetProgress(self: *Job) void {
        self.command.store(@intFromEnum(profiler.Stop.none), .monotonic);
        self.position.store(0, .monotonic);
        self.total.store(0, .monotonic);
        self.resetMeter();
        self.epoch.store(0, .monotonic);
        self.epochs.store(0, .monotonic);
        self.best_esr_bits.store(inf_bits, .monotonic);
        self.last_esr_bits.store(inf_bits, .monotonic);
        self.epoch_seconds_bits.store(0, .monotonic);
        self.stopped_early.store(false, .monotonic);
        self.lock();
        defer self.unlock();
        self.message.set("");
        self.detail.set("");
        self.error_name.set("");
        self.result_path.set("");
        self.result_name.set("");
    }

    fn resetMeter(self: *Job) void {
        self.peak_db_bits.store(floor_db_bits, .monotonic);
        self.hold_db_bits.store(floor_db_bits, .monotonic);
        self.clip_age.store(clip_latch_reports, .monotonic);
        self.clipped_total.store(0, .monotonic);
    }

    /// Starts the capture + training for `request` (under the Gui mutex).
    pub fn start(self: *Job, request: Request) !void {
        if (self.active()) return error.Busy;
        self.joinFinished();
        self.resetProgress();
        self.request = request;
        if (request.reamp.len == 0) {
            self.lock();
            self.reamp_path.set("");
            self.unlock();
        }
        self.setPhase(.preparing);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Runs the last request again from the top (a fresh capture), for the
    /// wizard's "Try again" after a failure or a cancel.
    pub fn restart(self: *Job) !void {
        var request = self.request;
        request.reamp.set("");
        request.ignore_checks = false;
        try self.start(request);
    }

    /// After a failed data check: train from the saved recording with the
    /// checks ignored (the CLI's `--ignore-checks`).
    pub fn startTrainAnyway(self: *Job) !void {
        if (!self.canTrainAnyway()) return error.NothingToRetry;
        var request = self.request;
        request.ignore_checks = true;
        self.lock();
        request.reamp.set(self.reamp_path.slice());
        self.unlock();
        try self.start(request);
    }

    fn canTrainAnyway(self: *Job) bool {
        if (self.phaseNow() != .failed) return false;
        self.lock();
        defer self.unlock();
        return std.mem.eql(u8, self.error_name.slice(), "DataChecksFailed") and self.reamp_path.len > 0;
    }

    /// Closes a finished job (under the Gui mutex): joins the worker and
    /// gives the audio devices back to the live session.
    pub fn dismissLocked(self: *Job) void {
        if (self.active()) return;
        self.joinFinished();
        self.setPhase(.idle);
        self.setMessage("", "");
        self.releaseAudioLocked();
    }

    /// Ends the job for the app to quit: a training run keeps its best
    /// epoch, anything else is cancelled. Blocks until the worker returns.
    pub fn shutdown(self: *Job) void {
        if (self.thread == null) return;
        if (self.active()) {
            const keep = self.phaseNow() == .training and self.epoch.load(.monotonic) > 0;
            self.send(if (keep) .finish else .cancel);
        }
        self.joinFinished();
    }

    // ---- audio ownership ----

    fn acquireAudio(self: *Job) profiler.CaptureConfig {
        gui_mod.lock(&self.gui.mutex);
        defer gui_mod.unlock(&self.gui.mutex);
        const session = self.gui.session;
        session.stopAudio();
        self.audio_held = true;
        return .{ .capture = session.capture_index, .playback = session.playback_index, .period = 256 };
    }

    /// Restarts the live stream when the job had stopped it (Gui mutex held).
    pub fn releaseAudioLocked(self: *Job) void {
        if (!self.audio_held) return;
        self.audio_held = false;
        const session = self.gui.session;
        if (self.gui.shared.chains.len == 0) return;
        session.startAudio() catch |err| ui.plainLine(self.io, "profile: could not restart the live stream ({s}); pick the devices again", .{@errorName(err)});
    }

    // ---- the worker ----

    fn run(self: *Job) void {
        self.runSteps() catch |err| self.finishWith(err);
    }

    fn runSteps(self: *Job) !void {
        const io = self.io;
        const allocator = self.allocator;
        const home = &self.gui.home;
        self.setMessage("Getting ready...", "");

        if (self.request.reamp.len == 0 and !home.captureSignalReady()) {
            self.setMessage("Downloading the capture signal (27 MB, only this once)...", "");
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            _ = home.ensureCaptureSignal(&aw.writer) catch |err| {
                self.setDetail(lastLine(aw.written()));
                return err;
            };
        }
        self.signal_ready.store(home.captureSignalReady(), .monotonic);

        var signal_wav = try wav.readFile(io, allocator, home.signal_path);
        defer signal_wav.deinit();
        const signal = try signal_wav.requireMono();
        if (signal_wav.sample_rate != profiler.sample_rate) return error.SampleRateMismatch;

        const slug = try profiler.slugify(allocator, self.request.displayName());
        defer allocator.free(slug);

        if (self.request.reamp.len == 0) {
            const config = self.acquireAudio();
            self.setPhase(.level_check);
            self.setMessage("The test signal is playing through your amp. Turn the input gain on your interface until the level reads Good, then press Start capture.", "");
            const request = try profiler.levelCheck(io, &self.gui.audio, self.reporter(), profiler.levelCheckExcerpt(signal), config);
            self.command.store(@intFromEnum(profiler.Stop.none), .monotonic);
            if (request == .cancel) return error.Cancelled;

            self.resetMeter();
            self.setPhase(.capturing);
            self.setMessage("Recording. Keep every knob still and stay quiet near the amp.", "");
            const recorded = try profiler.captureReamp(io, allocator, &self.gui.audio, self.reporter(), signal, config);
            defer allocator.free(recorded);

            self.setPhase(.checking);
            self.setMessage("Saving the recording...", "");
            const reamp_path = try profiler.uniquePath(allocator, io, home.captures, slug, "-reamp.wav");
            defer allocator.free(reamp_path);
            try wav.writeMono(io, allocator, reamp_path, recorded, profiler.sample_rate, .float32);
            self.lock();
            self.reamp_path.set(reamp_path);
            self.unlock();
        }

        var reamp_buf: [1024]u8 = undefined;
        const reamp = blk: {
            self.lock();
            defer self.unlock();
            const path = if (self.request.reamp.len > 0) self.request.reamp.slice() else self.reamp_path.slice();
            @memcpy(reamp_buf[0..path.len], path);
            break :blk reamp_buf[0..path.len];
        };
        const out_path = try profiler.uniquePath(allocator, io, home.profiles, slug, ".nam");
        defer allocator.free(out_path);

        self.setPhase(.checking);
        self.setMessage("Checking the recording...", "");
        const outcome = try profiler.trainPair(io, allocator, self.reporter(), .{
            .input_path = home.signal_path,
            .output_path = reamp,
            .out_path = out_path,
            .epochs = self.request.epochs,
            .ignore_checks = self.request.ignore_checks,
            .user = self.request.userMetadata(),
        });
        self.stopped_early.store(outcome.stopped_early, .monotonic);

        // The new profile shows up in the list, selected; the live stream
        // stays paused until the wizard is closed (see the module doc).
        const file_name = std.fs.path.basename(out_path);
        {
            gui_mod.lock(&self.gui.mutex);
            defer gui_mod.unlock(&self.gui.mutex);
            self.gui.rescanLocked(false) catch |err| ui.plainLine(io, "profile: rescan failed ({s}); press Rescan", .{@errorName(err)});
            self.gui.selectChainByName(file_name);
        }
        self.lock();
        self.result_path.set(out_path);
        self.result_name.set(file_name);
        self.unlock();
        const v = profiler.verdict(outcome.best_esr);
        self.setMessage(v.label(), v.advice());
        self.setPhase(.done);
    }

    fn finishWith(self: *Job, err: anyerror) void {
        if (err == error.Cancelled) {
            self.setMessage("Cancelled. Nothing was saved.", "");
            self.setPhase(.cancelled);
            return;
        }
        var buf: [320]u8 = undefined;
        const text: []const u8 = switch (err) {
            error.SilentCapture => "Nothing came back from the amp. Check the cable from the amp (or the load box, or the microphone) into the interface input, and that the amp is switched on.",
            error.CaptureClipped, error.OutputClipped => "The return was too loud and clipped. Lower the input gain on your interface, then capture again.",
            error.LatencyNotDetected => "The timing clicks at the start of the signal were not found in the recording. Make sure the interface output really reaches the amp input, and that the amp's output comes back on the selected input. Then capture again.",
            error.DataChecksFailed => "The recording is not consistent from start to end: background noise, a noise gate, reverb or delay, or a knob that moved. Switch off gates and time-based effects, keep every knob still, and capture again. You can also train anyway.",
            error.CaptureTooShort, error.NotEnoughTrainingData, error.NotEnoughValidationData => "The recording is too short to train on. Capture again.",
            error.DownloadFailed => "The capture signal could not be downloaded. Check the internet connection and try again, or download it yourself with the link below and put it in the nam-zig folder.",
            error.MicrophoneDenied => "Microphone access is denied. Allow nam-zig in System Settings, Privacy & Security, Microphone, then restart the app.",
            error.DeviceInit, error.DeviceStart, error.AudioStart, error.DeviceIndexOutOfRange, error.CaptureStart => "The audio devices could not be opened. Pick your interface as both the input and the output in the Devices section, then try again.",
            error.NoEpochsRun => "Training stopped before the first round completed, so there is nothing to save.",
            error.OutOfMemory => "The computer ran out of memory.",
            else => std.fmt.bufPrint(&buf, "Something went wrong ({s}).", .{@errorName(err)}) catch "Something went wrong.",
        };
        self.lock();
        self.message.set(text);
        self.error_name.set(@errorName(err));
        self.unlock();
        self.setPhase(.failed);
    }

    // ---- the pipeline's reporter ----

    const vtable = profiler.Reporter.VTable{
        .note = reportNote,
        .stage = reportStage,
        .epoch = reportEpoch,
        .capture = reportCapture,
        .stop = reportStop,
    };

    fn reporter(self: *Job) profiler.Reporter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reportNote(ptr: *anyopaque, text: []const u8) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.setDetail(text);
    }

    fn reportStage(ptr: *anyopaque, stage: profiler.Stage) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        switch (stage) {
            .checking => {
                self.setPhase(.checking);
                self.setMessage("Checking the recording...", "");
            },
            .training => {
                self.setPhase(.training);
                self.lock();
                self.message.set("Training. You can stop at any time and keep the best result so far.");
                self.unlock();
            },
            .exporting => {
                self.setPhase(.exporting);
                self.lock();
                self.message.set("Saving the profile...");
                self.unlock();
            },
        }
    }

    fn reportEpoch(ptr: *anyopaque, info: profiler.EpochInfo) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.epochs.store(info.epochs, .monotonic);
        self.best_esr_bits.store(@bitCast(info.best_esr), .monotonic);
        self.last_esr_bits.store(@bitCast(info.val_esr), .monotonic);
        const previous: f64 = @bitCast(self.epoch_seconds_bits.load(.monotonic));
        const n: f64 = @floatFromInt(info.epoch);
        const mean = if (info.epoch <= 1) info.seconds else previous + (info.seconds - previous) / n;
        self.epoch_seconds_bits.store(@bitCast(mean), .monotonic);
        self.epoch.store(info.epoch, .release);
    }

    fn reportCapture(ptr: *anyopaque, info: profiler.CaptureInfo) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.position.store(info.position, .monotonic);
        self.total.store(info.total, .monotonic);
        const peak_db = ui.dbfs(info.peak);
        const hold: f32 = @bitCast(self.hold_db_bits.load(.monotonic));
        self.peak_db_bits.store(@bitCast(peak_db), .monotonic);
        self.hold_db_bits.store(@bitCast(@max(peak_db, hold - hold_decay_db)), .monotonic);
        if (info.clipped > self.clipped_total.load(.monotonic)) {
            self.clipped_total.store(info.clipped, .monotonic);
            self.clip_age.store(0, .monotonic);
        } else {
            const age = self.clip_age.load(.monotonic);
            if (age < clip_latch_reports) self.clip_age.store(age + 1, .monotonic);
        }
    }

    fn reportStop(ptr: *anyopaque) profiler.Stop {
        const self: *Job = @ptrCast(@alignCast(ptr));
        return @enumFromInt(self.command.load(.acquire));
    }

    // ---- the page's view ----

    fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
        try std.json.Stringify.encodeJsonString(s, .{}, w);
    }

    fn jsonEsr(w: *std.Io.Writer, bits: u64) !void {
        const value: f64 = @bitCast(bits);
        if (std.math.isFinite(value)) try w.print("{d:.6}", .{value}) else try w.writeAll("null");
    }

    /// The `profiler` object of the page's state document.
    pub fn writeJson(self: *Job, w: *std.Io.Writer) !void {
        const phase = self.phaseNow();
        const position = self.position.load(.monotonic);
        const total = self.total.load(.monotonic);
        const epoch = self.epoch.load(.acquire);
        const epochs = self.epochs.load(.monotonic);
        const epoch_seconds: f64 = @bitCast(self.epoch_seconds_bits.load(.monotonic));
        const hold_db: f32 = @bitCast(self.hold_db_bits.load(.monotonic));
        const peak_db: f32 = @bitCast(self.peak_db_bits.load(.monotonic));
        const clipped_recently = self.clip_age.load(.monotonic) < clip_latch_reports;
        const band = profiler.levelBand(hold_db, clipped_recently);
        const seconds_left: f64 = switch (phase) {
            .capturing => @as(f64, @floatFromInt(total -| position)) / @as(f64, @floatFromInt(profiler.sample_rate)),
            .training => @as(f64, @floatFromInt(epochs -| epoch)) * (if (epoch > 0) epoch_seconds else self.epoch_estimate_s),
            else => 0,
        };
        const best_bits = self.best_esr_bits.load(.monotonic);
        const best: f64 = @bitCast(best_bits);
        const verdict: ?profiler.Verdict = if (std.math.isFinite(best)) profiler.verdict(best) else null;

        self.lock();
        defer self.unlock();
        try w.print("{{\"phase\":\"{s}\",\"message\":", .{@tagName(phase)});
        try jsonString(w, self.message.slice());
        try w.writeAll(",\"detail\":");
        try jsonString(w, self.detail.slice());
        try w.writeAll(",\"error\":");
        try jsonString(w, self.error_name.slice());
        try w.print(",\"position\":{d},\"total\":{d},\"seconds_left\":{d:.1},\"peak_db\":{d:.1},\"hold_db\":{d:.1},\"band\":\"{s}\",\"clipped\":{s},", .{
            position, total, seconds_left, peak_db, hold_db, @tagName(band), if (clipped_recently) "true" else "false",
        });
        try w.print("\"epoch\":{d},\"epochs\":{d},\"best_esr\":", .{ epoch, epochs });
        try jsonEsr(w, best_bits);
        try w.writeAll(",\"last_esr\":");
        try jsonEsr(w, self.last_esr_bits.load(.monotonic));
        try w.print(",\"epoch_seconds\":{d:.1},\"epoch_estimate_s\":{d:.1},\"stopped_early\":{s},\"requested_epochs\":{d},", .{
            epoch_seconds, self.epoch_estimate_s, if (self.stopped_early.load(.monotonic)) "true" else "false", self.request.epochs,
        });
        try w.writeAll("\"verdict\":");
        try jsonString(w, if (verdict) |v| @tagName(v) else "");
        try w.writeAll(",\"result_name\":");
        try jsonString(w, self.result_name.slice());
        try w.writeAll(",\"result_path\":");
        try jsonString(w, self.result_path.slice());
        try w.writeAll(",\"reamp_path\":");
        try jsonString(w, self.reamp_path.slice());
        const can_train_anyway = phase == .failed and std.mem.eql(u8, self.error_name.slice(), "DataChecksFailed") and self.reamp_path.len > 0;
        try w.print(",\"can_train_anyway\":{s},\"audio_held\":{s},\"signal_ready\":{s},\"download_page\":", .{
            if (can_train_anyway) "true" else "false", if (self.audio_held) "true" else "false", if (self.signal_ready.load(.monotonic)) "true" else "false",
        });
        try jsonString(w, home_mod.capture_signal_page);
        try w.writeAll(",\"name\":");
        try jsonString(w, self.request.displayName());
        try w.writeAll("}");
    }
};

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return trimmed[start..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "request fields decode the page's percent-encoding and validate the vocabularies" {
    var request = Request{};
    try std.testing.expect(request.setField("name", "Deluxe%20Reverb%20%2B%20boost"));
    try std.testing.expectEqualStrings("Deluxe Reverb + boost", request.name.slice());
    try std.testing.expect(request.setField("gear_type", "amp_cab"));
    try std.testing.expectEqualStrings("amp_cab", request.gear_type.slice());
    try std.testing.expect(request.setField("gear_type", "toaster"));
    try std.testing.expectEqual(@as(usize, 0), request.gear_type.len);
    try std.testing.expect(request.setField("tone_type", "hi_gain"));
    try std.testing.expect(request.setField("epochs", "20"));
    try std.testing.expectEqual(@as(usize, 20), request.epochs);
    try std.testing.expect(request.setField("epochs", "0"));
    try std.testing.expectEqual(@as(usize, 1), request.epochs);
    try std.testing.expect(request.setField("epochs", "5000"));
    try std.testing.expectEqual(max_epochs, request.epochs);
    try std.testing.expect(request.setField("epochs", "abc"));
    try std.testing.expectEqual(max_epochs, request.epochs);
    try std.testing.expect(!request.setField("bogus", "1"));
    try std.testing.expect(request.setField("name", "%20%20"));
    try std.testing.expectEqualStrings("My amp", request.displayName());
    const meta = request.userMetadata();
    try std.testing.expectEqualStrings("hi_gain", meta.tone_type.?);
    try std.testing.expect(meta.gear_make == null);
}

test "lastLine picks the final non-empty line" {
    try std.testing.expectEqualStrings("second", lastLine("first\nsecond\n"));
    try std.testing.expectEqualStrings("only", lastLine("only"));
    try std.testing.expectEqualStrings("", lastLine("\n\n"));
}
