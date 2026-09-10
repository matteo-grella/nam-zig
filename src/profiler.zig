//! The profiling pipeline shared by the terminal commands and the window:
//! the level check and the reamp capture (play the standardized signal
//! through the rig, record what comes back), and training an (input,
//! reamp) pair into an exported `.nam` profile. Progress flows through a
//! Reporter, so the terminal prints lines and the window drives a wizard;
//! the Reporter's stop hook lets the window advance, finish early (keeping
//! the best epoch so far), or cancel.

const std = @import("std");
const fucina = @import("fucina");
const nam_file = @import("nam_file.zig");
const wav = @import("wav.zig");
const data = @import("data.zig");
const train_mod = @import("train.zig");
const wavenet_mod = @import("wavenet.zig");
const nam_export = @import("nam_export.zig");
const audio_mod = @import("audio.zig");
const ui = @import("ui.zig");

const rng = fucina.rng;

pub const sample_rate: u32 = 48000;

/// The v3 capture signal: 190 s at 48 kHz.
pub const v3_signal_frames: usize = 9_120_000;

// ---------------------------------------------------------------------------
// Progress reporting
// ---------------------------------------------------------------------------

/// What the caller wants the pipeline to do at the next check point.
pub const Stop = enum {
    none,
    /// Level check: proceed to the capture.
    advance,
    /// Training: stop after the current step and export the best epoch so
    /// far (or after the first epoch when none has completed yet).
    finish,
    cancel,
};

/// Where the training run is; the window shows a different screen per stage.
pub const Stage = enum { checking, training, exporting };

pub const EpochInfo = struct {
    /// 1-based, just completed.
    epoch: usize,
    epochs: usize,
    train_loss: f64,
    val_esr: f64,
    best_esr: f64,
    improved: bool,
    seconds: f64,
};

pub const CaptureInfo = struct {
    position: usize,
    total: usize,
    /// Peak |input| since the previous report.
    peak: f32,
    /// Input samples at or above the clip level since the start.
    clipped: usize,
};

pub const Reporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        note: *const fn (ptr: *anyopaque, text: []const u8) void,
        stage: *const fn (ptr: *anyopaque, stage: Stage) void,
        epoch: *const fn (ptr: *anyopaque, info: EpochInfo) void,
        capture: *const fn (ptr: *anyopaque, info: CaptureInfo) void,
        stop: *const fn (ptr: *anyopaque) Stop,
    };

    /// A human-facing line: notes, warnings, and `error: ...` explanations
    /// that precede a returned error.
    pub fn note(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
        self.vtable.note(self.ptr, text);
    }

    pub fn stage(self: Reporter, s: Stage) void {
        self.vtable.stage(self.ptr, s);
    }

    pub fn epoch(self: Reporter, info: EpochInfo) void {
        self.vtable.epoch(self.ptr, info);
    }

    pub fn capture(self: Reporter, info: CaptureInfo) void {
        self.vtable.capture(self.ptr, info);
    }

    pub fn stop(self: Reporter) Stop {
        return self.vtable.stop(self.ptr);
    }
};

/// The terminal's reporter: one line per note and per epoch, a rewriting
/// status line during the capture, never stops on its own.
pub const StdoutReporter = struct {
    io: std.Io,
    stdout: *std.Io.Writer,
    capture_peak: f32 = 0,
    /// A capture status line is on the terminal's current line.
    status_active: bool = false,

    const vtable = Reporter.VTable{
        .note = note,
        .stage = stage,
        .epoch = epoch,
        .capture = capture,
        .stop = stop,
    };

    pub fn reporter(self: *StdoutReporter) Reporter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn note(ptr: *anyopaque, text: []const u8) void {
        const self: *StdoutReporter = @ptrCast(@alignCast(ptr));
        if (self.status_active) {
            self.status_active = false;
            self.stdout.writeAll("\n") catch {};
        }
        self.stdout.print("{s}\n", .{text}) catch {};
        self.stdout.flush() catch {};
    }

    fn stage(_: *anyopaque, _: Stage) void {}

    fn epoch(ptr: *anyopaque, info: EpochInfo) void {
        const self: *StdoutReporter = @ptrCast(@alignCast(ptr));
        self.stdout.print("epoch {d:>3}/{d}: train loss {d:.6}  val ESR {d:.6}{s}  ({d:.1}s)\n", .{
            info.epoch, info.epochs, info.train_loss, info.val_esr, if (info.improved) " *" else "", info.seconds,
        }) catch {};
        self.stdout.flush() catch {};
    }

    fn capture(ptr: *anyopaque, info: CaptureInfo) void {
        const self: *StdoutReporter = @ptrCast(@alignCast(ptr));
        self.capture_peak = @max(self.capture_peak, info.peak);
        self.stdout.flush() catch {};
        self.status_active = true;
        ui.statusLine(self.io, "capturing {d:>5.1}s / {d:.1}s   input peak {d:>6.1} dB", .{
            @as(f64, @floatFromInt(info.position)) / 48000.0, @as(f64, @floatFromInt(info.total)) / 48000.0, ui.dbfs(self.capture_peak),
        });
    }

    fn stop(_: *anyopaque) Stop {
        return .none;
    }
};

// ---------------------------------------------------------------------------
// Levels
// ---------------------------------------------------------------------------

/// Where a return level sits, for the window's level check. `hold_db` is
/// the recent peak (peak-hold with decay); `clipped_recently` latches a
/// clip indicator for a moment after any full-scale sample.
pub const LevelBand = enum { silent, low, good, hot, clipping };

pub const level_silent_db: f32 = -60;
pub const level_low_db: f32 = -20;
pub const level_hot_db: f32 = -3;

pub fn levelBand(hold_db: f32, clipped_recently: bool) LevelBand {
    if (clipped_recently) return .clipping;
    if (hold_db < level_silent_db) return .silent;
    if (hold_db < level_low_db) return .low;
    if (hold_db < level_hot_db) return .good;
    return .hot;
}

/// The stretch of the v3 signal the level check loops: the latency blips
/// and the opening training passage (10 s .. 30 s), the hottest material
/// in the file (within 0.5 dB of full scale, against -5.6 dBFS for the
/// opening validation music). A level that reads fine on this loop cannot
/// clip later in the real capture.
pub const level_check_start: usize = 480_000;
pub const level_check_end: usize = 1_440_000;

pub fn levelCheckExcerpt(signal: []const f32) []const f32 {
    if (signal.len >= level_check_end) return signal[level_check_start..level_check_end];
    return signal;
}

// ---------------------------------------------------------------------------
// Capture: play the signal, record the return
// ---------------------------------------------------------------------------

/// An input sample at or above this counts as clipped: a 24-bit converter
/// pinned at full scale reads 1 - 2^-23, and the trainer refuses |y| >= 1.
pub const clip_level: f32 = 0.9999;

const CaptureState = struct {
    signal: []const f32,
    /// Empty for the level check (nothing is kept).
    recorded: []f32,
    loop: bool,
    cursor: std.atomic.Value(usize) = .init(0),
    window_peak_bits: std.atomic.Value(u32) = .init(0),
    clipped: std.atomic.Value(usize) = .init(0),
};

fn captureCallback(user: ?*anyopaque, output: ?[*]f32, input: ?[*]const f32, frame_count: c_uint) callconv(.c) void {
    const state: *CaptureState = @ptrCast(@alignCast(user.?));
    const frames: usize = frame_count;
    const out = output orelse return;
    const in = input orelse return;
    var pos = state.cursor.load(.monotonic);
    var peak: f32 = @bitCast(state.window_peak_bits.load(.monotonic));
    var clipped = state.clipped.load(.monotonic);
    for (0..frames) |i| {
        const index = if (state.loop and state.signal.len > 0) pos % state.signal.len else pos;
        out[i] = if (index < state.signal.len) state.signal[index] else 0.0;
        const v = in[i];
        if (pos < state.recorded.len) state.recorded[pos] = v;
        const magnitude = @abs(v);
        peak = @max(peak, magnitude);
        if (magnitude >= clip_level) clipped += 1;
        pos += 1;
    }
    state.window_peak_bits.store(@bitCast(peak), .monotonic);
    state.clipped.store(clipped, .monotonic);
    state.cursor.store(pos, .release);
}

pub const CaptureConfig = struct {
    capture: ?usize,
    playback: ?usize,
    period: u32 = 256,
    /// Recorded after the signal ends: the device latency plus the rig's
    /// decay (reverb, cab ring-out).
    tail_frames: usize = sample_rate,
};

const report_interval_ms: u64 = 100;
/// A capture whose return is still silent this far in is aborted: the
/// signal opens with music, so nothing back by now means a cabling,
/// device, or permission problem, not a quiet passage.
pub const silence_probe_frames: usize = 15 * sample_rate;

fn windowPeak(state: *CaptureState) f32 {
    return @bitCast(state.window_peak_bits.swap(0, .monotonic));
}

/// Plays `excerpt` in a loop through the device pair while reporting the
/// return level, until the reporter asks to advance, finish, or cancel;
/// returns that request. Nothing is recorded.
pub fn levelCheck(io: std.Io, audio: *audio_mod.Audio, reporter: Reporter, excerpt: []const f32, config: CaptureConfig) !Stop {
    var state = CaptureState{ .signal = excerpt, .recorded = &.{}, .loop = true };
    try audio.start(config.capture, config.playback, sample_rate, config.period, captureCallback, &state);
    defer audio.stop();
    while (true) {
        const request = reporter.stop();
        if (request != .none) return request;
        std.Io.sleep(io, .{ .nanoseconds = report_interval_ms * std.time.ns_per_ms }, .awake) catch {};
        reporter.capture(.{
            .position = state.cursor.load(.monotonic),
            .total = 0,
            .peak = windowPeak(&state),
            .clipped = state.clipped.load(.monotonic),
        });
    }
}

/// Plays `signal` once through the device pair and records the return,
/// `tail_frames` longer than the signal. Errors: `SilentCapture` when
/// nothing came back, `CaptureClipped` as soon as the return hits full
/// scale (the trainer would refuse it anyway), `Cancelled` on request.
/// The caller owns the returned samples.
pub fn captureReamp(io: std.Io, allocator: std.mem.Allocator, audio: *audio_mod.Audio, reporter: Reporter, signal: []const f32, config: CaptureConfig) ![]f32 {
    const total = signal.len + config.tail_frames;
    const recorded = try allocator.alloc(f32, total);
    errdefer allocator.free(recorded);
    @memset(recorded, 0);

    var state = CaptureState{ .signal = signal, .recorded = recorded, .loop = false };
    try audio.start(config.capture, config.playback, sample_rate, config.period, captureCallback, &state);
    defer audio.stop();

    var overall_peak: f32 = 0;
    while (state.cursor.load(.acquire) < total) {
        if (reporter.stop() == .cancel) return error.Cancelled;
        std.Io.sleep(io, .{ .nanoseconds = report_interval_ms * std.time.ns_per_ms }, .awake) catch {};
        const peak = windowPeak(&state);
        overall_peak = @max(overall_peak, peak);
        const clipped = state.clipped.load(.monotonic);
        reporter.capture(.{ .position = @min(state.cursor.load(.monotonic), total), .total = total, .peak = peak, .clipped = clipped });
        if (clipped > 0) {
            reporter.note("error: the return clipped ({d} samples at full scale); lower the interface input gain and capture again", .{clipped});
            return error.CaptureClipped;
        }
        if (overall_peak < 1e-4 and state.cursor.load(.monotonic) >= silence_probe_frames) {
            reporter.note("error: nothing came back in the first {d} s of the capture; check the cabling and the microphone permission", .{silence_probe_frames / sample_rate});
            return error.SilentCapture;
        }
    }
    if (overall_peak < 1e-4) {
        reporter.note("error: the capture channel recorded silence; check the cabling and the microphone permission", .{});
        return error.SilentCapture;
    }
    return recorded;
}

// ---------------------------------------------------------------------------
// Training an (input, reamp) pair
// ---------------------------------------------------------------------------

pub const TrainSplits = struct {
    version: data.InputVersion,
    latency: i64,
    calibration: ?data.LatencyCalibration,
    checks_passed: bool,
    train_x: []const f32,
    train_y: []const f32,
    val_x: []const f32,
    val_y: []const f32,
};

pub const NormalizedOutputs = struct {
    train_y: []f32,
    val_y: []f32,
    train_scale: f32,

    pub const target_dbfs: f64 = -18.0;

    pub fn deinit(self: *NormalizedOutputs, allocator: std.mem.Allocator) void {
        allocator.free(self.train_y);
        allocator.free(self.val_y);
        self.* = undefined;
    }

    pub fn exportCompensation(self: *const NormalizedOutputs) f32 {
        return 1.0 / self.train_scale;
    }
};

pub fn normalizeJointOutput(allocator: std.mem.Allocator, train_y: []const f32, val_y: []const f32) !NormalizedOutputs {
    var sum_sq: f64 = 0;
    for (train_y) |v| sum_sq += @as(f64, v) * v;
    if (train_y.len == 0) return error.EmptyTrainingData;
    if (sum_sq == 0) return error.ZeroTrainingOutput;
    const train_rms = @sqrt(sum_sq / @as(f64, @floatFromInt(train_y.len)));
    const target_rms = std.math.pow(f64, 10.0, NormalizedOutputs.target_dbfs / 20.0);
    const scale: f32 = @floatCast(target_rms / train_rms);
    if (!std.math.isFinite(scale) or scale == 0) return error.InvalidOutputScale;

    const train_scaled = try allocator.alloc(f32, train_y.len);
    errdefer allocator.free(train_scaled);
    const val_scaled = try allocator.alloc(f32, val_y.len);
    errdefer allocator.free(val_scaled);
    for (train_scaled, train_y) |*dst, v| dst.* = scale * v;
    for (val_scaled, val_y) |*dst, v| dst.* = scale * v;
    return .{ .train_y = train_scaled, .val_y = val_scaled, .train_scale = scale };
}

fn checkV3InputPreSilence(x: []const f32) data.DataError!void {
    try data.checkInputPreSilence(x, data.v3.train_start, data.standard_sample_rate);
    try data.checkInputPreSilence(x, x.len - data.v3.t_validate, data.standard_sample_rate);
}

/// Resolves capture version, latency, checks, and the train/validation
/// splits for an (input, reamp) pair, matching the upstream
/// neural-amp-modeler trainer: latency (delay) calibration, the v3 data
/// checks, and the per-input-version train/validation split points.
pub fn resolveSplits(
    reporter: Reporter,
    input_bytes: []const u8,
    x: []const f32,
    y: []const f32,
    manual_latency: ?i64,
    ignore_checks: bool,
) !TrainSplits {
    return resolveSplitsFor(reporter, data.detectInputVersion(input_bytes), x, y, manual_latency, ignore_checks);
}

/// `resolveSplits` with the capture version already known.
pub fn resolveSplitsFor(
    reporter: Reporter,
    version: data.InputVersion,
    x_full: []const f32,
    y_full: []const f32,
    manual_latency: ?i64,
    ignore_checks: bool,
) !TrainSplits {
    switch (version) {
        .v1_0_0, .v1_1_1, .v2_0_0, .v4_0_0 => {
            reporter.note("error: v1/v2/v4 capture files are deprecated upstream; re-record with the v3 input file", .{});
            return error.DeprecatedInputVersion;
        },
        else => {},
    }

    // The pair is end-cropped to the shorter file (upstream does the same
    // in its v3 check): a reamp recorded with a latency/decay tail would
    // otherwise put the end-relative validation window at different
    // absolute positions in x and y.
    const n = @min(x_full.len, y_full.len);
    const x = x_full[0..n];
    const y = y_full[0..n];
    if (y_full.len > x_full.len) {
        reporter.note("note: the recording is {d:.2} s longer than the signal; the tail beyond the signal is ignored", .{@as(f64, @floatFromInt(y_full.len - x_full.len)) / data.standard_sample_rate});
    } else if (x_full.len > y_full.len) {
        reporter.note("warning: the recording is {d:.2} s shorter than the signal; is it complete?", .{@as(f64, @floatFromInt(x_full.len - y_full.len)) / data.standard_sample_rate});
    }

    var calibration: ?data.LatencyCalibration = null;
    var latency: i64 = manual_latency orelse 0;
    var checks_passed = true;

    if (version == .v3_0_0) {
        const cal = data.calibrateLatencyV3(y_full);
        calibration = cal;
        if (manual_latency == null) {
            latency = cal.recommended orelse {
                reporter.note("error: latency blips not detected; pass --latency or re-record", .{});
                return error.LatencyNotDetected;
            };
        }
        if (cal.warn_matches_lookahead) reporter.note("warning: latency trigger fired at the scan start (noisy capture?)", .{});

        const check = data.checkV3(x.len, y);
        checks_passed = check.passed;
        reporter.note("v3 capture detected; latency {d} samples; replicate self-ESR {d:.6} ({s})", .{ latency, check.replicate_esr, if (check.passed) "ok" else "FAILED" });
        if (!check.passed and !ignore_checks) {
            reporter.note("error: validation replicates disagree (> 0.01 self-ESR): noise/gate/time-based FX or drift. Use --ignore-checks to proceed anyway.", .{});
            return error.DataChecksFailed;
        }
        // The v3 split slices x/y as [train_start .. len - t_validate] and
        // [len - t_validate ..]; a reamp shorter than train_start + t_validate
        // would make the train end precede its start (and underflow the usize
        // subtraction). checkV3 only sizes the validation windows, so guard here.
        const v3_min = data.v3.train_start + data.v3.t_validate;
        if (n < v3_min) {
            reporter.note("error: capture too short — the v3 input/reamp is missing the training/validation tail; re-record the full file", .{});
            return error.CaptureTooShort;
        }
        try checkV3InputPreSilence(x);

        const train_pair = try data.applyDelay(x[data.v3.train_start .. n - data.v3.t_validate], y[data.v3.train_start .. n - data.v3.t_validate], latency);
        const val_pair = try data.applyDelay(x[n - data.v3.t_validate ..], y[n - data.v3.t_validate ..], latency);
        try data.checkOutputNotClipped(train_pair.y);
        try data.checkOutputNotClipped(val_pair.y);
        return .{ .version = version, .latency = latency, .calibration = calibration, .checks_passed = checks_passed, .train_x = train_pair.x, .train_y = train_pair.y, .val_x = val_pair.x, .val_y = val_pair.y };
    }

    // Generic pair: -9 s validation tail (single_pair.json), manual latency.
    if (manual_latency == null) {
        reporter.note("note: unrecognized capture signal; assuming --latency 0 (pass it explicitly if your interface has loopback delay)", .{});
    }
    var val_len: usize = @intFromFloat(9.0 * data.standard_sample_rate);
    if (val_len * 2 > n) {
        val_len = n / 4; // short clips: hold out the last quarter
        reporter.note("note: short capture; holding out the last 25% for validation instead of 9 s", .{});
    }
    const train_pair = try data.applyDelay(x[0 .. n - val_len], y[0 .. n - val_len], latency);
    const val_pair = try data.applyDelay(x[n - val_len .. n], y[n - val_len .. n], latency);
    try data.checkOutputNotClipped(train_pair.y);
    try data.checkOutputNotClipped(val_pair.y);
    return .{ .version = version, .latency = latency, .calibration = calibration, .checks_passed = checks_passed, .train_x = train_pair.x, .train_y = train_pair.y, .val_x = val_pair.x, .val_y = val_pair.y };
}

fn validationEsrConfig(allocator: std.mem.Allocator, config: *const nam_file.WaveNetConfig, weights: []const f32, val_x: []const f32, val_y: []const f32, nx: usize) !f64 {
    const pred = try allocator.alloc(f32, val_x.len);
    defer allocator.free(pred);
    try train_mod.renderWaveNetConfig(allocator, config, weights, val_x, pred);
    return data.esr(pred[nx - 1 ..], val_y[nx - 1 ..]);
}

fn validationEsrLstm(allocator: std.mem.Allocator, config: *const nam_file.LstmConfig, weights: []const f32, val_x: []const f32, val_y: []const f32, nx: usize) !f64 {
    const pred = try allocator.alloc(f32, val_x.len);
    defer allocator.free(pred);
    try train_mod.renderLstmConfig(allocator, config, weights, val_x, pred);
    return data.esr(pred[nx - 1 ..], val_y[nx - 1 ..]);
}

fn validationEsrSnapshot(allocator: std.mem.Allocator, snapshot: *const train_mod.TrainingSnapshot, val_x: []const f32, val_y: []const f32, nx: usize) !f64 {
    return switch (snapshot.*) {
        .wavenet => |*s| try validationEsrConfig(allocator, &s.config, s.weights, val_x, val_y, nx),
        .lstm => |*s| try validationEsrLstm(allocator, &s.config, s.weights, val_x, val_y, nx),
        .packed_wavenet => |*packed_snapshot| blk: {
            var total: f64 = 0;
            for (packed_snapshot.submodels) |*submodel| {
                total += try validationEsrConfig(allocator, &submodel.config, submodel.weights, val_x, val_y, nx);
            }
            break :blk total / @as(f64, @floatFromInt(packed_snapshot.submodels.len));
        },
    };
}

/// Everything `train` takes on the command line, with the same defaults.
pub const TrainConfig = struct {
    input_path: []const u8,
    output_path: []const u8,
    out_path: []const u8,
    /// Fine-tune this WaveNet profile instead of training `spec` from scratch.
    init_path: ?[]const u8 = null,
    spec: train_mod.TrainingSpec = .{ .classic = train_mod.ModelSpec.classic },
    /// null = the spec's default.
    epochs: ?usize = null,
    batch_size: usize = 16,
    ny: usize = 8192,
    lr: ?f32 = null,
    weight_decay: ?f32 = null,
    gamma: ?f32 = null,
    mrstft_weight: ?f32 = null,
    seed: u64 = 0,
    /// null = calibrated from the v3 blips (0 for other signals).
    latency: ?i64 = null,
    ignore_checks: bool = false,
    user: nam_export.UserMetadata = .{},
};

pub const TrainOutcome = struct {
    best_esr: f64,
    epochs_run: usize,
    /// The reporter asked to finish before the last epoch.
    stopped_early: bool,
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// Trains `config.spec` (or fine-tunes `config.init_path`) on the pair and
/// exports the best epoch to `config.out_path`. Errors are preceded by an
/// `error: ...` note where the cause needs words.
pub fn trainPair(io: std.Io, allocator: std.mem.Allocator, reporter: Reporter, config: TrainConfig) !TrainOutcome {
    if (config.batch_size == 0) {
        reporter.note("error: --batch must be > 0", .{});
        return error.InvalidBatchSize;
    }
    if (config.ny == 0) {
        reporter.note("error: --ny must be > 0", .{});
        return error.InvalidNy;
    }
    const spec = config.spec;
    const epochs = config.epochs orelse spec.defaultEpochs();
    const lr0 = config.lr orelse spec.defaultLr();
    const weight_decay = config.weight_decay orelse spec.defaultWeightDecay();
    const gamma = config.gamma orelse spec.defaultGamma();
    const mrstft_weight = config.mrstft_weight orelse spec.defaultMrstftWeight();
    const loss_options = train_mod.LossOptions{ .mrstft_weight = mrstft_weight };
    const batch_size = config.batch_size;
    const ny = config.ny;

    reporter.stage(.checking);
    const input_bytes = try wav.readFileBytes(io, allocator, config.input_path);
    defer allocator.free(input_bytes);
    var input_wav = try wav.parse(allocator, input_bytes);
    defer input_wav.deinit();
    var output_wav = try wav.readFile(io, allocator, config.output_path);
    defer output_wav.deinit();
    const x = try input_wav.requireMono();
    const y = try output_wav.requireMono();
    if (input_wav.sample_rate != output_wav.sample_rate) return error.SampleRateMismatch;
    if (input_wav.sample_rate != sample_rate) {
        reporter.note("error: training expects 48 kHz captures (got {d} Hz)", .{input_wav.sample_rate});
        return error.SampleRateMismatch;
    }

    var init_model: ?nam_file.NamModel = null;
    defer if (init_model) |*model| model.deinit();
    var owned_template_config: ?nam_file.WaveNetConfig = null;
    defer if (owned_template_config) |*template| train_mod.freeEngineConfig(allocator, template);
    var template_config: ?*const nam_file.WaveNetConfig = null;
    var train_name: []const u8 = undefined;
    if (config.init_path) |path| {
        init_model = try nam_file.loadFile(io, allocator, path);
        const loaded = &init_model.?;
        switch (loaded.config) {
            .wavenet => |*wavenet_config| {
                template_config = wavenet_config;
                train_name = "loaded-wavenet";
            },
            else => {
                reporter.note("error: --init currently trains WaveNet .nam files only", .{});
                return error.UnsupportedArchitecture;
            },
        }
    } else {
        switch (spec) {
            .packed_wavenet, .lstm => {
                train_name = spec.name();
            },
            else => {
                owned_template_config = try spec.makeEngineConfig(allocator);
                template_config = &owned_template_config.?;
                train_name = spec.name();
            },
        }
    }

    const splits = try resolveSplits(reporter, input_bytes, x, y, config.latency, config.ignore_checks);
    var normalized = try normalizeJointOutput(allocator, splits.train_y, splits.val_y);
    defer normalized.deinit(allocator);
    const nx = if (template_config) |template| template.receptiveField() else spec.receptiveField();
    const dataset = data.Dataset{ .x = splits.train_x, .y = normalized.train_y, .nx = nx, .ny = ny };
    const example_count = dataset.len();
    const steps_per_epoch = example_count / batch_size;
    if (steps_per_epoch == 0) return error.NotEnoughTrainingData;
    if (splits.val_x.len <= nx) return error.NotEnoughValidationData;

    reporter.note("training {s} spec: {d} examples (ny {d}), {d} steps/epoch x {d} epochs, batch {d}, lr {d}, gamma {d}, wd {d}, mrstft {d}, output scale {d}", .{
        train_name, example_count, ny, steps_per_epoch, epochs, batch_size, lr0, gamma, weight_decay, mrstft_weight, normalized.train_scale,
    });
    reporter.stage(.training);

    var ctx: fucina.ExecContext = undefined;
    ctx.init(allocator);
    defer ctx.deinit();

    var model: train_mod.ActiveTrainable = undefined;
    if (init_model) |*loaded| {
        model = .{ .wavenet = try wavenet_mod.WaveNet.init(allocator, &ctx, template_config.?, loaded.weights, .{ .trainable = true }) };
    } else {
        model = try spec.initTrainable(allocator, &ctx, config.seed);
    }
    defer model.deinit();
    var opt = try fucina.optim.Adam.init(allocator, .{ .lr = lr0, .weight_decay = weight_decay });
    defer opt.deinit();
    try model.registerParams(&opt);

    const order = try allocator.alloc(usize, example_count);
    defer allocator.free(order);
    for (order, 0..) |*v, idx| v.* = idx;

    var best_snapshot: ?train_mod.TrainingSnapshot = null;
    defer if (best_snapshot) |*snapshot| snapshot.deinit(allocator);
    var best_esr = std.math.inf(f64);
    var epochs_run: usize = 0;
    var stopped_early = false;
    var finish_after_epoch = false;
    const seed = config.seed;

    epochs: for (0..epochs) |epoch| {
        opt.config.lr = lr0 * std.math.pow(f32, gamma, @floatFromInt(epoch));
        // Deterministic shuffle (Fisher-Yates over rng.at counters).
        for (0..example_count) |idx| {
            const j = idx + rng.at(seed +% 0x5851f42d4c957f2d, epoch * example_count + idx) % (example_count - idx);
            std.mem.swap(usize, &order[idx], &order[j]);
        }

        const epoch_start = nowNs(io);
        var loss_sum: f64 = 0;
        for (0..steps_per_epoch) |step_index| {
            switch (reporter.stop()) {
                .cancel => return error.Cancelled,
                .finish => {
                    stopped_early = true;
                    // Nothing to keep before the first validation; finish
                    // this epoch so an early stop still exports a profile.
                    if (best_snapshot != null) break :epochs;
                    finish_after_epoch = true;
                },
                else => {},
            }
            for (order[step_index * batch_size ..][0..batch_size]) |example_index| {
                const example = dataset.get(example_index);
                const scope = ctx.openExecScope();
                defer ctx.closeExecScope(scope);
                const loss = try model.segmentLossWithOptions(&ctx, example.input, example.target, loss_options);
                var scaled = try loss.scale(&ctx, 1.0 / @as(f32, @floatFromInt(batch_size)));
                loss_sum += try loss.item();
                try scaled.backward(&ctx);
            }
            try opt.step(&ctx);
            opt.zeroGrad();
        }

        var snapshot = try model.extractTrainingSnapshot(&ctx, allocator, template_config);
        const val_esr = try validationEsrSnapshot(allocator, &snapshot, splits.val_x, normalized.val_y, nx);
        const epoch_seconds = @as(f64, @floatFromInt(@as(u64, @intCast(nowNs(io) - epoch_start)))) / 1e9;
        const improved = val_esr < best_esr;
        if (improved) {
            best_esr = val_esr;
            if (best_snapshot) |*old| old.deinit(allocator);
            best_snapshot = snapshot;
        } else {
            snapshot.deinit(allocator);
        }
        epochs_run = epoch + 1;
        reporter.epoch(.{
            .epoch = epoch + 1,
            .epochs = epochs,
            .train_loss = loss_sum / @as(f64, @floatFromInt(steps_per_epoch * batch_size)),
            .val_esr = val_esr,
            .best_esr = best_esr,
            .improved = improved,
            .seconds = epoch_seconds,
        });
        if (finish_after_epoch) break;
    }

    const final_snapshot = if (best_snapshot) |*snapshot| snapshot else return error.NoEpochsRun;
    reporter.note("validation ESR {d:.6} — {s}", .{ best_esr, data.esrComment(best_esr) });
    reporter.stage(.exporting);

    const unix_seconds: u64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const export_info = nam_export.ExportInfo{
        .user = config.user,
        .training = .{
            .ignore_checks = config.ignore_checks,
            .latency_manual = config.latency,
            .calibration = splits.calibration,
            .checks_version = 3,
            .checks_passed = splits.checks_passed,
            .validation_esr = best_esr,
        },
        .unix_seconds = unix_seconds,
        .sample_rate = 48000.0,
        .output_scale_compensation = normalized.exportCompensation(),
    };
    switch (final_snapshot.*) {
        .wavenet => |*snapshot| try nam_export.exportWaveNetConfig(io, allocator, config.out_path, &snapshot.config, snapshot.weights, export_info),
        .packed_wavenet => |*snapshot| try nam_export.exportSlimmableContainer(io, allocator, config.out_path, snapshot.submodels, export_info),
        .lstm => |*snapshot| try nam_export.exportLstmConfig(io, allocator, config.out_path, &snapshot.config, snapshot.weights, export_info),
    }
    reporter.note("exported {s}", .{config.out_path});
    return .{ .best_esr = best_esr, .epochs_run = epochs_run, .stopped_early = stopped_early };
}

// ---------------------------------------------------------------------------
// Cost estimate
// ---------------------------------------------------------------------------

pub const StepCost = struct {
    nx: usize,
    ny: usize,
    /// One segment's loss + backward, best of the timed runs.
    ms: f64,
};

/// Times one training step at the trainer's window shape (`bench
/// --train-step`, and the window's "about N minutes" before training).
pub fn measureTrainStep(io: std.Io, allocator: std.mem.Allocator, spec: train_mod.TrainingSpec, ny: usize) !StepCost {
    if (ny == 0) return error.InvalidArgument;
    const rf = spec.receptiveField();
    const nx = rf - 1 + ny;
    const window = try allocator.alloc(f32, nx);
    defer allocator.free(window);
    wavenet_mod.fillSignal(window, 9);
    const target = try allocator.alloc(f32, ny);
    defer allocator.free(target);
    for (target, window[nx - ny ..]) |*dst, v| dst.* = 0.5 * std.math.tanh(2.0 * v);

    var ctx: fucina.ExecContext = undefined;
    ctx.init(allocator);
    defer ctx.deinit();
    var model = try spec.initTrainable(allocator, &ctx, 5);
    defer model.deinit();
    var opt = try fucina.optim.Adam.init(allocator, .{ .lr = 0.001, .weight_decay = 0 });
    defer opt.deinit();
    try model.registerParams(&opt);
    var best: f64 = std.math.inf(f64);
    for (0..5) |iter| {
        const start = nowNs(io);
        {
            const scope = ctx.openExecScope();
            defer ctx.closeExecScope(scope);
            var loss = try model.segmentLoss(&ctx, window, target);
            try loss.backward(&ctx);
        }
        opt.zeroGrad();
        const ns: f64 = @floatFromInt(nowNs(io) - start);
        if (iter >= 2) best = @min(best, ns);
    }
    return .{ .nx = nx, .ny = ny, .ms = best / 1e6 };
}

/// Seconds per epoch for the v3 layout from a measured step cost: every
/// example is one loss + backward, plus about a second to render the
/// validation split.
pub fn estimateEpochSeconds(step_ms: f64, signal_frames: usize, spec: train_mod.TrainingSpec, ny: usize, batch_size: usize) f64 {
    const train_frames = signal_frames -| (data.v3.train_start + data.v3.t_validate);
    const nx = spec.receptiveField();
    const examples = if (train_frames >= nx) (train_frames - nx + 1) / ny else 0;
    const steps = if (batch_size > 0) examples / batch_size else 0;
    return @as(f64, @floatFromInt(steps * batch_size)) * step_ms / 1000.0 + 1.0;
}

// ---------------------------------------------------------------------------
// Plain-language quality
// ---------------------------------------------------------------------------

/// The upstream ESR bands, in words for the window.
pub const Verdict = enum {
    great,
    good,
    fair,
    poor,
    failed,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .great => "Excellent match",
            .good => "Good match",
            .fair => "Fair match",
            .poor => "Weak match",
            .failed => "Something went wrong",
        };
    }

    pub fn advice(self: Verdict) []const u8 {
        return switch (self) {
            .great => "The profile is indistinguishable from the amp on the test material.",
            .good => "Close to the amp. More training rounds usually tighten it further.",
            .fair => "Usable, but noticeably off. Check the levels and try the full training length.",
            .poor => "Far from the amp. Check the wiring (a clean return, no gate, no reverb or delay) and capture again.",
            .failed => "The recording did not describe the amp: check the wiring and capture again.",
        };
    }
};

pub fn verdict(esr: f64) Verdict {
    if (esr < 0.01) return .great;
    if (esr < 0.035) return .good;
    if (esr < 0.1) return .fair;
    if (esr < 0.3) return .poor;
    return .failed;
}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

/// A file stem from a display name: letters, digits, and underscores
/// kept; everything else folded into single dashes.
pub fn slugify(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = try allocator.alloc(u8, @max(name.len, 1));
    var n: usize = 0;
    var last_dash = true;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            out[n] = c;
            n += 1;
            last_dash = false;
        } else if (!last_dash) {
            out[n] = '-';
            n += 1;
            last_dash = true;
        }
    }
    while (n > 0 and out[n - 1] == '-') n -= 1;
    if (n == 0) {
        out[0] = 'p';
        n = 1;
    }
    return allocator.realloc(out, n);
}

/// `<dir>/<stem><suffix>`, or `<stem>-2<suffix>`, `-3`, ... when taken.
pub fn uniquePath(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, stem: []const u8, suffix: []const u8) ![]const u8 {
    var attempt: usize = 1;
    while (attempt < 1000) : (attempt += 1) {
        const file = if (attempt == 1)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, suffix })
        else
            try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ stem, attempt, suffix });
        defer allocator.free(file);
        const path = try std.fs.path.join(allocator, &.{ dir, file });
        std.Io.Dir.cwd().access(io, path, .{}) catch return path;
        allocator.free(path);
    }
    return error.TooManyFiles;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A reporter for tests: keeps the last note, never stops.
const QuietReporter = struct {
    last: [1024]u8 = undefined,
    last_len: usize = 0,

    const vtable = Reporter.VTable{
        .note = note,
        .stage = stage,
        .epoch = epoch,
        .capture = capture,
        .stop = stop,
    };

    fn reporter(self: *QuietReporter) Reporter {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn note(ptr: *anyopaque, text: []const u8) void {
        const self: *QuietReporter = @ptrCast(@alignCast(ptr));
        self.last_len = @min(text.len, self.last.len);
        @memcpy(self.last[0..self.last_len], text[0..self.last_len]);
    }
    fn stage(_: *anyopaque, _: Stage) void {}
    fn epoch(_: *anyopaque, _: EpochInfo) void {}
    fn capture(_: *anyopaque, _: CaptureInfo) void {}
    fn stop(_: *anyopaque) Stop {
        return .none;
    }
};

test "normalizeJointOutput scales train and validation from training RMS" {
    const allocator = std.testing.allocator;
    const train_y = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    const val_y = [_]f32{ 0.125, -0.125 };
    var normalized = try normalizeJointOutput(allocator, &train_y, &val_y);
    defer normalized.deinit(allocator);

    const train_rms = @sqrt((4.0 * 0.25 * 0.25 + 4.0 * 0.5 * 0.5) / 8.0);
    const target_rms = std.math.pow(f64, 10.0, NormalizedOutputs.target_dbfs / 20.0);
    const expected_scale: f32 = @floatCast(target_rms / train_rms);
    try std.testing.expectApproxEqAbs(expected_scale, normalized.train_scale, 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 * expected_scale), normalized.train_y[0], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5 * expected_scale), normalized.train_y[3], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125 * expected_scale), normalized.val_y[0], 1e-7);
    try std.testing.expectApproxEqAbs(1.0 / expected_scale, normalized.exportCompensation(), 1e-7);
}

test "normalizeJointOutput rejects empty or zero training output" {
    const allocator = std.testing.allocator;
    const val_y = [_]f32{0.125};
    try std.testing.expectError(error.EmptyTrainingData, normalizeJointOutput(allocator, &.{}, &val_y));
    const zero_train = [_]f32{ 0, 0, 0 };
    try std.testing.expectError(error.ZeroTrainingOutput, normalizeJointOutput(allocator, &zero_train, &val_y));
}

test "v3 input pre-silence is required before train and validation splits" {
    const allocator = std.testing.allocator;
    const n = data.v3.train_start + data.v3.t_validate + @as(usize, 48_000);
    const x = try allocator.alloc(f32, n);
    defer allocator.free(x);

    @memset(x, 0);
    try checkV3InputPreSilence(x);

    x[data.v3.train_start - 1] = 0.125;
    try std.testing.expectError(data.DataError.InputPreSilenceMissing, checkV3InputPreSilence(x));

    @memset(x, 0);
    const validation_start = x.len - data.v3.t_validate;
    x[validation_start - 1] = 0.125;
    try std.testing.expectError(data.DataError.InputPreSilenceMissing, checkV3InputPreSilence(x));
}

test "v3 splits end-crop a reamp longer than the signal (the recorded tail)" {
    const allocator = std.testing.allocator;
    const n = data.v3.train_start + data.v3.t_validate + @as(usize, 96_000);
    const x = try allocator.alloc(f32, n);
    defer allocator.free(x);
    @memset(x, 0);
    // A one-second tail past the signal, as the capture records it.
    const y_long = try allocator.alloc(f32, n + 48_000);
    defer allocator.free(y_long);
    @memset(y_long, 0);
    // Identical validation replicates at the signal's start and end (the
    // v3 self-check), and a distinct training stretch in between.
    for (0..data.v3.t_validate) |i| {
        const v: f32 = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.01);
        y_long[i] = v;
        y_long[n - data.v3.t_validate + i] = v;
    }
    for (data.v3.train_start..n - data.v3.t_validate) |i| y_long[i] = 0.1;

    var quiet = QuietReporter{};
    const long = try resolveSplitsFor(quiet.reporter(), .v3_0_0, x, y_long, 0, false);
    const exact = try resolveSplitsFor(quiet.reporter(), .v3_0_0, x, y_long[0..n], 0, false);
    try std.testing.expectEqual(data.v3.t_validate, long.val_y.len);
    try std.testing.expectEqualSlices(f32, exact.val_y, long.val_y);
    try std.testing.expectEqualSlices(f32, exact.train_y, long.train_y);
    // The window is the signal's last 9 s, not the recording's (which
    // would begin one second later, inside the silent tail).
    try std.testing.expectEqual(@as(f32, 0.3 * @sin(@as(f32, 1.0) * 0.01)), long.val_y[1]);
    try std.testing.expectEqual(@as(f32, 0.1), long.train_y[0]);
}

test "level bands and the clip latch" {
    try std.testing.expectEqual(LevelBand.silent, levelBand(-140, false));
    try std.testing.expectEqual(LevelBand.silent, levelBand(-61, false));
    try std.testing.expectEqual(LevelBand.low, levelBand(-40, false));
    try std.testing.expectEqual(LevelBand.good, levelBand(-19, false));
    try std.testing.expectEqual(LevelBand.good, levelBand(-6, false));
    try std.testing.expectEqual(LevelBand.hot, levelBand(-2, false));
    try std.testing.expectEqual(LevelBand.hot, levelBand(0, false));
    try std.testing.expectEqual(LevelBand.clipping, levelBand(-6, true));
}

test "the level check loops the hottest passage when the signal is long enough" {
    const long = try std.testing.allocator.alloc(f32, level_check_end + 10);
    defer std.testing.allocator.free(long);
    const excerpt = levelCheckExcerpt(long);
    try std.testing.expectEqual(level_check_end - level_check_start, excerpt.len);
    try std.testing.expect(excerpt.ptr == long.ptr + level_check_start);
    const short = [_]f32{ 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 3), levelCheckExcerpt(&short).len);
}

test "verdict follows the upstream ESR bands" {
    try std.testing.expectEqual(Verdict.great, verdict(0.005));
    try std.testing.expectEqual(Verdict.good, verdict(0.02));
    try std.testing.expectEqual(Verdict.fair, verdict(0.05));
    try std.testing.expectEqual(Verdict.poor, verdict(0.2));
    try std.testing.expectEqual(Verdict.failed, verdict(0.5));
}

test "epoch estimate follows the v3 layout" {
    const spec = train_mod.TrainingSpec{ .classic = train_mod.ModelSpec.classic };
    // 190 s signal, standard spec: 1001 examples -> 62 steps of 16.
    const seconds = estimateEpochSeconds(40.0, 9_120_000, spec, 8192, 16);
    try std.testing.expectApproxEqAbs(@as(f64, 992.0 * 0.04 + 1.0), seconds, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), estimateEpochSeconds(40.0, 1000, spec, 8192, 16), 1e-9);
}

test "slugify keeps letters, digits, underscores; folds the rest into single dashes" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "My Amp", "My-Amp" },
        .{ "  Deluxe / Reverb (crunch)!! ", "Deluxe-Reverb-crunch" },
        .{ "plain_name", "plain_name" },
        .{ "///", "p" },
    };
    for (cases) |c| {
        const got = try slugify(allocator, c[0]);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}
