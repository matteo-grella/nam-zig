//! Amp-profile discovery in a folder and the chain builder shared by the
//! terminal player, the amp menu, and the window.

const std = @import("std");
const fucina = @import("fucina");
const nam_file = @import("nam_file.zig");
const engine_mod = @import("engine.zig");
const gguf_compat = @import("gguf_compat.zig");
const ir_cab = @import("ir_cab.zig");
const wav = @import("wav.zig");
const chain_mod = @import("chain.zig");
const live_mod = @import("live.zig");

pub fn loadModel(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, path: []const u8) !nam_file.NamModel {
    const model = try gguf_compat.loadAny(io, allocator, path);
    if (model.partial_support) {
        try stdout.print("note: {s} has a newer patch version than 0.7.0; loading with partial support (same as upstream)\n", .{path});
    }
    return model;
}

pub fn stripProfileExt(name: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(name, ".nam")) return name[0 .. name.len - 4];
    if (std.ascii.endsWithIgnoreCase(name, ".gguf")) return name[0 .. name.len - 5];
    return name;
}

pub fn isNamGguf(io: std.Io, allocator: std.mem.Allocator, path: []const u8) bool {
    var file = fucina.gguf.File.loadMmap(allocator, io, path) catch return false;
    defer file.deinit();
    return file.getString(gguf_compat.file_json_key) != null;
}

/// Collects .nam/.gguf files under `dir` up to `depth` levels deep.
pub fn discoverProfiles(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory and depth > 1) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            if (std.mem.eql(u8, dir_path, ".") and (std.mem.eql(u8, entry.name, "nam-profiles") or std.mem.eql(u8, entry.name, "models"))) continue;
            if (std.mem.eql(u8, dir_path, ".") and !std.mem.eql(u8, entry.name, "models")) continue;
            const sub = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverProfiles(io, allocator, sub, depth - 1, out);
            continue;
        }
        if (entry.kind != .file) continue;
        const is_nam = std.ascii.endsWithIgnoreCase(entry.name, ".nam");
        const is_gguf = std.ascii.endsWithIgnoreCase(entry.name, ".gguf");
        if (!is_nam and !is_gguf) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        // .gguf is also the LLM weights format — only list NAM containers
        // (metadata-only mmap peek; tensor data is never touched).
        if (is_gguf and !isNamGguf(io, allocator, path)) continue;
        try out.append(allocator, path);
    }
}

/// Collects `.chain` manifests under `dir` up to `depth` levels deep.
pub fn discoverChains(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory and depth > 1) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            const sub = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try discoverChains(io, allocator, sub, depth - 1, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".chain")) continue;
        try out.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }
}

/// Sorts by base name (case-insensitive) and drops the `.gguf` twin of a
/// `.nam` with the same stem.
pub fn sortAndDedupe(paths: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(std.fs.path.basename(a), std.fs.path.basename(b));
        }
    }.lessThan);
    var deduped: usize = 0;
    for (paths.items) |path| {
        const name = stripProfileExt(std.fs.path.basename(path));
        if (deduped > 0) {
            const previous = stripProfileExt(std.fs.path.basename(paths.items[deduped - 1]));
            if (std.ascii.eqlIgnoreCase(name, previous)) {
                if (std.ascii.endsWithIgnoreCase(path, ".nam")) paths.items[deduped - 1] = path;
                continue;
            }
        }
        paths.items[deduped] = path;
        deduped += 1;
    }
    paths.items.len = deduped;
}

pub const BuiltStage = struct { cs: live_mod.ChainStage, norm_gain: f32 };

/// Loads one stage instance (NAM model or cab IR) for `spec`, sized to
/// `frame_cap` and prewarmed. The instance is heap-allocated for a stable
/// pointer in the chain; on error it is fully cleaned up. `norm_gain` is the
/// NAM stage's loudness comp to -18 dBFS (1.0 for a cab).
pub fn buildStage(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, spec: chain_mod.StageSpec, sample_rate: u32, frame_cap: usize) !BuiltStage {
    const trim = std.math.pow(f32, 10.0, spec.trim_db / 20.0);
    switch (spec.kind) {
        .nam => {
            var model = try loadModel(io, allocator, stdout, spec.path);
            defer model.deinit();
            if (model.sample_rate > 0 and model.sample_rate != @as(f64, @floatFromInt(sample_rate))) {
                try stdout.print("error: {s} expects {d} Hz but the stream is {d} Hz (no resampling; pass --rate)\n", .{ spec.path, model.sample_rate, sample_rate });
                return error.SampleRateMismatch;
            }
            const engine = try allocator.create(engine_mod.Engine);
            errdefer allocator.destroy(engine);
            engine.* = try engine_mod.Engine.init(allocator, &model);
            errdefer engine.deinit();
            try engine.reset(frame_cap, true);
            // Player-style loudness normalization to the -18 dBFS target (capped
            // so bogus metadata can't blast the output). The engine itself never
            // applies loudness, same as the upstream core.
            var norm_gain: f32 = 1.0;
            if (model.metadata.loudness) |loudness| {
                const boost_db = std.math.clamp(-18.0 - loudness, -40.0, 20.0);
                norm_gain = std.math.pow(f32, 10.0, @as(f32, @floatCast(boost_db)) / 20.0);
            }
            const gear = classifyGearModel(&model);
            return .{ .cs = .{ .stage = .{ .nam = .{ .engine = engine, .gear = gear } }, .in_trim = trim }, .norm_gain = norm_gain };
        },
        .cab => {
            const cab = try allocator.create(ir_cab.IrCab);
            errdefer allocator.destroy(cab);
            cab.* = ir_cab.IrCab.loadFile(io, allocator, spec.path, sample_rate, frame_cap) catch |err| {
                try stdout.print("error: could not load cab IR {s}: {s}\n", .{ spec.path, @errorName(err) });
                return err;
            };
            errdefer cab.deinit();
            try stdout.print("cab IR: {s} ({d} taps @ {d} Hz)\n", .{ spec.path, cab.taps, sample_rate });
            return .{ .cs = .{ .stage = .{ .cab = cab }, .in_trim = trim }, .norm_gain = 1.0 };
        },
    }
}

/// Assembles all chains: bare profiles first (each a 1-stage chain, plus a cab
/// stage when --ir is given), then explicit --chain manifests. Every stage is
/// duplicate-loaded into its own instance (single-owner — see live.zig). On any
/// failure everything built so far is freed.
pub const BuildRequest = struct {
    profile_paths: []const []const u8,
    /// Appended as a cab stage after every bare profile.
    ir_path: ?[]const u8 = null,
    chain_paths: []const []const u8 = &.{},
    sample_rate: u32,
    frame_cap: usize,
    /// Report and skip a profile or manifest that fails to load instead of
    /// failing the whole set (the window's folder scan).
    lenient: bool = false,
};

pub fn buildChains(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, request: BuildRequest) !live_mod.ChainSet {
    const profile_paths = request.profile_paths;
    const ir_path = request.ir_path;
    const chain_paths = request.chain_paths;
    const sample_rate = request.sample_rate;
    const frame_cap = request.frame_cap;
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const total = profile_paths.len + chain_paths.len;
    const chains = try allocator.alloc(live_mod.Chain, total);
    errdefer allocator.free(chains);

    var built: usize = 0;
    var pending: std.ArrayList(live_mod.ChainStage) = .empty;
    // Single-owner cleanup of the temporary buffer: frees exactly once on every
    // exit (including if the success-path print below fails). Registered before
    // the errdefer so on error the destroyStage loops (which read pending.items)
    // run first, then this frees the buffer.
    defer pending.deinit(allocator);
    errdefer {
        for (pending.items) |*cs| live_mod.destroyStage(allocator, cs);
        for (chains[0..built]) |*c| for (c.stages) |*cs| live_mod.destroyStage(allocator, cs);
    }

    // (1) bare profiles -> 1-stage chains (+ optional --ir cab stage).
    for (profile_paths) |ppath| {
        const r = buildStage(io, allocator, stdout, .{ .path = ppath, .kind = .nam }, sample_rate, frame_cap) catch |err| {
            if (!request.lenient) return err;
            try stdout.print("skipped {s}: {s}\n", .{ ppath, @errorName(err) });
            continue;
        };
        try pending.append(allocator, r.cs);
        if (ir_path) |irp| {
            const c = try buildStage(io, allocator, stdout, .{ .path = irp, .kind = .cab }, sample_rate, frame_cap);
            try pending.append(allocator, c.cs);
        }
        const cname = std.fs.path.basename(ppath);
        live_mod.adviseChain(stdout, cname, pending.items) catch {};
        chains[built] = .{
            .name = try arena.dupe(u8, cname),
            .stages = try arena.dupe(live_mod.ChainStage, pending.items),
            .norm_gain = r.norm_gain,
        };
        pending.clearRetainingCapacity(); // ownership moved into chains[built]
        built += 1;
    }

    // (2) explicit --chain manifests.
    for (chain_paths) |cpath| {
        const text = wav.readFileBytes(io, allocator, cpath) catch |err| {
            if (!request.lenient) return err;
            try stdout.print("skipped {s}: {s}\n", .{ cpath, @errorName(err) });
            continue;
        };
        defer allocator.free(text);
        var spec = chain_mod.parse(allocator, text) catch |err| {
            try stdout.print("error: bad chain manifest {s}: {s}\n", .{ cpath, @errorName(err) });
            if (!request.lenient) return err;
            continue;
        };
        defer spec.deinit();
        var norm: f32 = 1.0;
        var failed = false;
        for (spec.stages) |sspec| {
            const r = buildStage(io, allocator, stdout, sspec, sample_rate, frame_cap) catch |err| {
                if (!request.lenient) return err;
                try stdout.print("skipped {s}: stage {s}: {s}\n", .{ cpath, sspec.path, @errorName(err) });
                failed = true;
                break;
            };
            if (sspec.kind == .nam) norm = r.norm_gain; // last NAM stage wins
            try pending.append(allocator, r.cs);
        }
        if (failed) {
            for (pending.items) |*cs| live_mod.destroyStage(allocator, cs);
            pending.clearRetainingCapacity();
            continue;
        }
        const cname = spec.name orelse std.fs.path.stem(std.fs.path.basename(cpath));
        live_mod.adviseChain(stdout, cname, pending.items) catch {};
        chains[built] = .{
            .name = try arena.dupe(u8, cname),
            .stages = try arena.dupe(live_mod.ChainStage, pending.items),
            .norm_gain = norm,
        };
        pending.clearRetainingCapacity();
        built += 1;
    }

    try stdout.print("loaded {d} chain(s)\n", .{built});
    // Shrinks the slice to the chains actually built (lenient skips); a
    // failed shrink leaves the original allocation for the errdefers above.
    return .{ .allocator = allocator, .arena = arena_inst, .chains = if (built < total) try allocator.realloc(chains, built) else chains };
}

/// gear_type-based cab classification + a Tone3000 "full rig" name/model hint.
pub fn classifyGearModel(model: *const nam_file.NamModel) live_mod.GearClass {
    var hint = false;
    const doc = model.document();
    if (doc == .object) {
        if (doc.object.get("metadata")) |m| {
            if (m == .object) {
                for ([_][]const u8{ "name", "gear_model", "tone_type" }) |k| {
                    if (m.object.get(k)) |v| {
                        if (v == .string and hasFullRig(v.string)) hint = true;
                    }
                }
            }
        }
    }
    return live_mod.classifyGear(model.metadata.gear_type, hint);
}

fn hasFullRig(s: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(s, "full-rig") != null) return true;
    if (std.ascii.indexOfIgnoreCase(s, "full rig") != null) return true;
    return std.ascii.indexOfIgnoreCase(s, "full") != null and std.ascii.indexOfIgnoreCase(s, "rig") != null;
}
