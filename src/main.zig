// creamery/src/main.zig — Creamery core (Zig, wasm32-freestanding).
//
// Tiger Style (tiger-style-zig, 0.15 delta applied): explicit contracts,
// bounded work, no hidden behaviour, no allocation after init. The core is
// a fixed-step deterministic simulation: the shell calls step() at 60 Hz
// with a fixed dt; the core never reads a wall clock, never touches the
// DOM, and reports everything it wants drawn as a draw list in a static
// buffer.
//
// Game: a rhythm game on Alma's signature tool, the Milking Pump. The
// pump runs cycles; each cycle is a small score — draw-in, counted
// strokes, a peak, a let-down, a rest. The player taps on the strokes
// and on the peak. THE SYNC DESIGN (the thing W8 exists to prove): the
// core keeps a sample clock for a nominal 48 kHz audio stream, and the
// pump's animation phase is DERIVED from that clock, never from a
// separate timeline — the same design the engine research pins for
// sokol_audio (stream position as master clock). Animation and audio
// cues therefore cannot drift apart; both read one counter.

const std = @import("std");

// ---------------------------------------------------------------------------
// Domain constants
// ---------------------------------------------------------------------------

/// Logical canvas is 960x960 (program contract). All draw coordinates are
/// integer logical pixels.
pub const canvas_px: i32 = 960;

/// Hard bound on draw ops per frame. The emitter drops (and counts) any op
/// past the bound instead of writing out of the buffer.
pub const max_ops: usize = 1024;

/// Serialised draw-list buffer: one op per line, e.g. "r 10 20 30 40 2".
pub const draw_buffer_bytes: usize = 64 * 1024;

/// Fixed step the shell is contracted to deliver.
pub const step_ms: u32 = 16;

/// The master clock. A nominal 48 kHz stream (WebAudio's common rate):
/// one 16 ms step is exactly 768 samples, so the sample counter and the
/// millisecond simulation advance in exact lockstep.
pub const sample_rate: u32 = 48_000;
pub const samples_per_step: u32 = sample_rate * step_ms / 1000; // 768

/// Chart ledger bound (the book of record, stub form): entries past the
/// bound are dropped and counted, never silently overwritten.
pub const max_chart_entries: usize = 24;

/// Chart bars drawn on the end screens (the most recent entries).
pub const chart_bars_shown: usize = 12;

/// Palette indices (shell + rasteriser share this table; index 0 is the
/// background and always paints first).
pub const Palette = struct {
    pub const bg: u8 = 0; // #0d0208 near-black plum
    pub const pink: u8 = 1; // #ff2e88 hot pink (NTRanch accent)
    pub const skin: u8 = 2; // #f8f0ed pale skin / fresh yield
    pub const mauve: u8 = 3; // #ac9393 shadow mauve
    pub const plum: u8 = 4; // #540e46 deep plum
    pub const rose: u8 = 5; // #ec8584 warm rose
    pub const paper: u8 = 6; // #eaeaea paper white
    pub const dim: u8 = 7; // #68636c dim grey-violet
    pub const gold: u8 = 8; // #ffd166 sparse gold
    pub const deep: u8 = 9; // #1a0510 panel deep
};

/// The palette as hex strings, for the shell/book to quote. Comptime-known.
pub const palette_hex = [_][]const u8{
    "#0d0208", "#ff2e88", "#f8f0ed", "#ac9393", "#540e46",
    "#ec8584", "#eaeaea", "#68636c", "#ffd166", "#1a0510",
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Alma's face states for this entry. Order is arousal order; the face is
/// COUPLED to the pump cycle: it warms through the strokes, peaks at the
/// cycle peak, and glows in the rest after a completed cycle.
pub const FaceState = enum(u8) {
    rest = 0,
    warm = 1,
    peak = 2,
    glow = 3,

    pub fn label(self: FaceState) []const u8 {
        return switch (self) {
            .rest => "AT REST",
            .warm => "WARMING",
            .peak => "AT PEAK",
            .glow => "AFTERGLOW",
        };
    }
};

/// Continuous face parameters. States are keyframes over these; transitions
/// interpolate. Posture (head_tilt, head_sink, shoulder_y) moves WITH the
/// expression — the Séraphine standard: posture AND expression change.
/// (Same keyframe struct shape W1 validated; it ports as one unit.)
pub const FaceParams = struct {
    eye_open: f32, // 1 = open, 0 = closed
    gaze_x: f32, // -1..1, full-disc centre offset (gaze §1.7)
    gaze_y: f32, // -1..1
    mouth_open: f32, // 0..1
    blush: f32, // 0..1
    brow_lift: f32, // 0..1
    head_tilt: f32, // logical px, + = her left
    head_sink: f32, // logical px, + = down
    shoulder_y: f32, // logical px offset, + = down (posture slump)
};

/// Keyframe parameter set per face state (the performance score).
pub const face_keyframes = [4]FaceParams{
    .{ .eye_open = 0.92, .gaze_x = 0.0, .gaze_y = 0.05, .mouth_open = 0.10, .blush = 0.18, .brow_lift = 0.35, .head_tilt = 0, .head_sink = 0, .shoulder_y = 0 }, // rest
    .{ .eye_open = 0.55, .gaze_x = 0.15, .gaze_y = 0.28, .mouth_open = 0.38, .blush = 0.60, .brow_lift = 0.60, .head_tilt = 6, .head_sink = 12, .shoulder_y = 8 }, // warm
    .{ .eye_open = 0.18, .gaze_x = 0.0, .gaze_y = 0.60, .mouth_open = 0.88, .blush = 0.97, .brow_lift = 0.90, .head_tilt = -5, .head_sink = 28, .shoulder_y = 20 }, // peak
    .{ .eye_open = 0.38, .gaze_x = -0.08, .gaze_y = 0.40, .mouth_open = 0.48, .blush = 0.75, .brow_lift = 0.25, .head_tilt = 10, .head_sink = 38, .shoulder_y = 28 }, // glow
};

/// One cell of the transition timing table.
pub const Transition = struct {
    duration_ms: u32,
    /// True when the path must pass through the intermediate keyframe(s)
    /// (expression continuity: never jump rest -> peak in one blend).
    via_intermediate: bool,
};

/// THE TRANSITION TIMING TABLE (W1's validated table, second use — the
/// port-back artifact in both directions). Comptime-generated, total over
/// ordered state pairs: every (from, to) has an entry; same-state is a
/// zero-duration no-op. Escalation is slower than recovery; any path
/// skipping a state goes via the intermediate keyframes.
pub const transition_table: [4][4]Transition = build_table: {
    var t: [4][4]Transition = undefined;
    for (0..4) |from| {
        for (0..4) |to| {
            if (from == to) {
                t[from][to] = .{ .duration_ms = 0, .via_intermediate = false };
            } else if (to > from) {
                const steps = to - from;
                t[from][to] = .{ .duration_ms = 900 * @as(u32, @intCast(steps)), .via_intermediate = steps > 1 };
            } else {
                const steps = from - to;
                t[from][to] = .{ .duration_ms = 500 * @as(u32, @intCast(steps)), .via_intermediate = steps > 1 };
            }
        }
    }
    break :build_table t;
};

/// The pump's comfort presets (the tool's T1 tier). Comfort is a real
/// trade, stated on the panel: GENTLE judges wide and yields slowly,
/// DEEP judges narrow and yields fast. Presets are NEVER gated behind
/// progression — they are changeable before and between cycles.
pub const Preset = enum(u8) {
    gentle = 0,
    standard = 1,
    deep = 2,

    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .gentle => "GENTLE",
            .standard => "STANDARD",
            .deep => "DEEP",
        };
    }
};

/// One row of the preset table: judge window, cycle base yield, per-hit
/// yield. All yields are whole millilitres; the let-down multiplier is
/// applied in integer percent so the accounting is exact.
pub const PresetSpec = struct {
    window_ms: u32,
    base_ml: u32,
    per_hit_ml: u32,
};

pub const preset_table = [3]PresetSpec{
    .{ .window_ms = 320, .base_ml = 10, .per_hit_ml = 6 }, // gentle
    .{ .window_ms = 260, .base_ml = 12, .per_hit_ml = 8 }, // standard
    .{ .window_ms = 200, .base_ml = 14, .per_hit_ml = 11 }, // deep
};

/// Let-down multipliers, in percent: a cycle whose peak beat lands gets
/// the full let-down; a missed peak still yields, at the partial rate.
pub const letdown_full_pct: u32 = 125;
pub const letdown_partial_pct: u32 = 70;

/// The yield of one completed cycle, in whole ml. Pure and exact:
/// (base + hits * per_hit) scaled by the let-down multiplier, rounded
/// down. This is the reservoir model of the design in one function.
pub fn cycle_yield(spec: PresetSpec, hits: u32, peak_hit: bool) u32 {
    const raw = spec.base_ml + hits * spec.per_hit_ml;
    const pct: u32 = if (peak_hit) letdown_full_pct else letdown_partial_pct;
    return raw * pct / 100;
}

/// One entry in the book of record. Append-only; the shape is the
/// port-back artifact for Torogao's ledger: a witnessed cycle, the
/// preset it ran under, what landed, and what it yielded.
pub const ChartEntry = struct {
    cycle: u16, // 1-based cycle number within the session
    preset: Preset,
    hits: u8, // stroke beats hit (the peak is the `full` flag)
    strokes: u8, // stroke beats offered
    yield_ml: u16,
    full: bool, // peak beat landed -> full let-down
};

/// Screens. The core owns all screens as draw lists; the shell only
/// forwards input and paints.
pub const Screen = enum(u8) {
    gate = 0, // 18+ gate (first screen, always)
    title = 1,
    howto = 2,
    play = 3,
    pause = 4,
    settings = 5,
    victory = 6,
    gameover = 7,
};

/// Input bitmask delivered per step by the shell.
pub const Input = struct {
    pub const tap: u32 = 1 << 0; // pointer press / space (edge-triggered by shell)
    pub const confirm: u32 = 1 << 1;
    pub const back: u32 = 1 << 2;
    pub const pause_btn: u32 = 1 << 3;
    pub const up: u32 = 1 << 4;
    pub const down: u32 = 1 << 5;
};

/// Events the shell sonifies (WebAudio, generated; no assets). The core
/// sets event_code; the shell polls it after each step. Events only ever
/// answer steps the player's (or demo policy's) input drove.
pub const Event = struct {
    pub const none: u8 = 0;
    pub const stroke_good: u8 = 1;
    pub const stroke_miss: u8 = 2;
    pub const letdown: u8 = 3; // full cycle completion (the juice event)
    pub const partial: u8 = 4; // cycle completed without the peak
    pub const victory: u8 = 5;
    pub const game_over: u8 = 6;
    pub const ui_move: u8 = 7;
    pub const peak_good: u8 = 8;
};

/// One level: a morning's work at the café counter, escalating in tempo
/// and strokes. The target is a yield, reached cycle by cycle.
pub const Level = struct {
    name: []const u8,
    target_ml: u32, // session yield that completes the level
    strokes_per_cycle: u8,
    stroke_ms: u32, // spacing of the counted strokes
    time_limit_ms: u32,
};

pub const levels = [3]Level{
    .{ .name = "LEVEL 1 - FIRST DRAW", .target_ml = 150, .strokes_per_cycle = 4, .stroke_ms = 960, .time_limit_ms = 240_000 },
    .{ .name = "LEVEL 2 - THE MORNING ROUND", .target_ml = 240, .strokes_per_cycle = 5, .stroke_ms = 848, .time_limit_ms = 300_000 },
    .{ .name = "LEVEL 3 - THE FULL BOOK", .target_ml = 400, .strokes_per_cycle = 6, .stroke_ms = 768, .time_limit_ms = 330_000 },
};

/// Pump cycle phases. One cycle is a small score: the bellows draw in,
/// the counted strokes land, the peak window opens, the yield lets down
/// into the vessel, and the rig rests before the next cycle.
pub const CyclePhase = enum(u8) { draw_in, strokes, peak, release, rest };

/// Cycle phase durations that do not depend on the level. The strokes
/// segment is strokes_per_cycle * stroke_ms; the rest is fixed score.
/// EVERY duration in the cycle (these, and stroke_ms per level) is a
/// multiple of the 16 ms step: the sample clock and the cycle therefore
/// wrap on the same step, which is what makes the sync invariant exact.
pub const draw_in_ms: u32 = 896;
pub const peak_ms: u32 = 704;
pub const release_ms: u32 = 1104;
pub const rest_ms: u32 = 800;

/// Juice timings: hit-stop freezes the whole rig (sample clock included)
/// on a full let-down; the flash decays over flash_ms.
pub const hitstop_ms: u32 = 96;
pub const flash_ms: u32 = 240;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

pub const CoreError = error{ InvalidLevel, InvalidPreset };

fn validate_level(level: u8) CoreError!usize {
    if (level >= levels.len) return CoreError.InvalidLevel;
    return level;
}

fn validate_preset(preset: u8) CoreError!Preset {
    if (preset > @intFromEnum(Preset.deep)) return CoreError.InvalidPreset;
    return @enumFromInt(preset);
}

// ---------------------------------------------------------------------------
// Private leaf work: RNG, easing
// ---------------------------------------------------------------------------

/// SplitMix64: tiny, deterministic, seedable. One stream per game.
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed | 1 };
    }
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    /// Uniform in [0, 1).
    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / 16_777_216.0;
    }
    /// Uniform int in [0, n). Contract: n > 0.
    pub fn below(self: *Rng, n: u32) u32 {
        std.debug.assert(n > 0);
        return @intCast(self.next() % n);
    }
};

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn ease_in_out(t: f32) f32 {
    const x = clamp01(t);
    return x * x * (3.0 - 2.0 * x);
}

fn lerp_params(a: FaceParams, b: FaceParams, t: f32) FaceParams {
    return .{
        .eye_open = lerp(a.eye_open, b.eye_open, t),
        .gaze_x = lerp(a.gaze_x, b.gaze_x, t),
        .gaze_y = lerp(a.gaze_y, b.gaze_y, t),
        .mouth_open = lerp(a.mouth_open, b.mouth_open, t),
        .blush = lerp(a.blush, b.blush, t),
        .brow_lift = lerp(a.brow_lift, b.brow_lift, t),
        .head_tilt = lerp(a.head_tilt, b.head_tilt, t),
        .head_sink = lerp(a.head_sink, b.head_sink, t),
        .shoulder_y = lerp(a.shoulder_y, b.shoulder_y, t),
    };
}

// ---------------------------------------------------------------------------
// Game state and the step
// ---------------------------------------------------------------------------

const max_strokes: usize = 8;
const max_motes: usize = 40;

const BeatState = enum(u8) { pending, hit, missed };

const TransitionState = struct {
    active: bool = false,
    from: FaceParams = face_keyframes[0],
    target: FaceState = .rest,
    elapsed_ms: u32 = 0,
    duration_ms: u32 = 0,
    via: [2]?FaceState = .{ null, null },
};

pub const Game = struct {
    screen: Screen = .gate,
    level_idx: usize = 0,
    seed: u64 = 1,
    demo: bool = false,
    frame: u64 = 0,
    elapsed_ms: u32 = 0, // play-screen clock
    screen_ms: u32 = 0, // time on current screen (demo auto-advance)

    // Face performance (coupled to the cycle, see face_target)
    face: FaceState = .rest,
    params: FaceParams = face_keyframes[0],
    transition: TransitionState = .{},

    // The pump cycle. cycle_t is milliseconds into the current cycle;
    // audio_frame is the master sample clock. Both advance only inside
    // step_play, by the same step, so they cannot drift (tested).
    audio_frame: u64 = 0,
    cycle_t: u32 = 0,
    cycle_index: u32 = 0, // completed cycles this session
    strokes: [max_strokes]BeatState = [_]BeatState{.pending} ** max_strokes,
    peak_state: BeatState = .pending,
    cycle_hits: u32 = 0,
    accounted: bool = false, // this cycle's yield has been booked
    session_done: bool = false, // target reached; victory at cycle end

    // Yield and the book of record
    total_yield_ml: u32 = 0,
    chart: [max_chart_entries]ChartEntry = undefined,
    chart_len: usize = 0,
    chart_dropped: u32 = 0,

    // Juice: hit-stop freezes the rig; flash decays after it.
    hitstop_left_ms: u32 = 0,
    flash_left_ms: u32 = 0,
    stroke_flash_ms: u32 = 0, // small ring flash on a good stroke
    peak_hold_ms: u32 = 0, // face holds peak after a landed peak beat
    glow_ms: u32 = 0, // afterglow timer after a completed cycle

    // Settings (in-core session persistence; the shell restores them at
    // boot through the bridge). Comfort and accessibility, never gated.
    preset: Preset = .standard,
    preset_next: ?Preset = null, // queued mid-cycle; applies at cycle wrap
    flash_reduced: bool = false,
    text_large: bool = false,
    menu_cursor: u8 = 0,

    // Ambient field (positions fixed at init; motion is a pure function
    // of elapsed time, so no per-frame RNG state exists to drift)
    motes: [max_motes][2]u16 = undefined,

    event_code: u8 = Event.none,
    dropped_ops: u32 = 0,

    pub fn init(seed: u64, demo: bool) Game {
        var g = Game{ .seed = seed, .demo = demo };
        var rng = Rng.init(seed ^ 0xCAFE1);
        for (0..max_motes) |i| {
            g.motes[i] = .{ @intCast(rng.below(960)), @intCast(rng.below(960)) };
        }
        return g;
    }

    pub fn level(self: *const Game) Level {
        return levels[self.level_idx];
    }

    pub fn preset_spec(self: *const Game) PresetSpec {
        return preset_table[@intFromEnum(self.preset)];
    }

    fn start_level(self: *Game, idx: usize) void {
        self.level_idx = idx;
        self.audio_frame = 0;
        self.cycle_t = 0;
        self.cycle_index = 0;
        self.strokes = [_]BeatState{.pending} ** max_strokes;
        self.peak_state = .pending;
        self.cycle_hits = 0;
        self.accounted = false;
        self.session_done = false;
        self.total_yield_ml = 0;
        self.chart_len = 0;
        self.chart_dropped = 0;
        self.elapsed_ms = 0;
        self.hitstop_left_ms = 0;
        self.flash_left_ms = 0;
        self.stroke_flash_ms = 0;
        self.peak_hold_ms = 0;
        self.glow_ms = 0;
        self.preset_next = null;
        self.face = .rest;
        self.params = face_keyframes[0];
        self.transition = .{};
        self.screen = .play;
        self.screen_ms = 0;
    }

    fn goto(self: *Game, s: Screen) void {
        self.screen = s;
        self.screen_ms = 0;
        self.menu_cursor = 0;
    }

    // -- cycle geometry (all in cycle_t coordinates) --

    pub fn cycle_total_ms(self: *const Game) u32 {
        const lvl = self.level();
        return draw_in_ms + @as(u32, lvl.strokes_per_cycle) * lvl.stroke_ms +
            peak_ms + release_ms + rest_ms;
    }

    fn strokes_start(self: *const Game) u32 {
        _ = self;
        return draw_in_ms;
    }
    fn strokes_end(self: *const Game) u32 {
        const lvl = self.level();
        return draw_in_ms + @as(u32, lvl.strokes_per_cycle) * lvl.stroke_ms;
    }
    fn peak_start(self: *const Game) u32 {
        return self.strokes_end();
    }
    fn release_start(self: *const Game) u32 {
        return self.strokes_end() + peak_ms;
    }
    fn rest_start(self: *const Game) u32 {
        return self.release_start() + release_ms;
    }

    pub fn phase(self: *const Game) CyclePhase {
        const t = self.cycle_t;
        if (t < self.strokes_start()) return .draw_in;
        if (t < self.strokes_end()) return .strokes;
        if (t < self.release_start()) return .peak;
        if (t < self.rest_start()) return .release;
        return .rest;
    }

    /// Centre time (cycle_t) of stroke k. Contract: k < strokes offered.
    fn stroke_center(self: *const Game, k: usize) u32 {
        std.debug.assert(k < self.level().strokes_per_cycle);
        return draw_in_ms + @as(u32, @intCast(k)) * self.level().stroke_ms + self.level().stroke_ms / 2;
    }

    /// Centre time (cycle_t) of the peak beat.
    fn peak_center(self: *const Game) u32 {
        return self.peak_start() + peak_ms / 2;
    }

    /// THE SYNC INVARIANT, as a function: the animation phase position
    /// derived from the master sample clock. Because audio_frame
    /// advances exactly samples_per_step per step and cycle_t advances
    /// exactly step_ms, this equals cycle_t at every step boundary —
    /// the port-back's measured tolerance is zero by construction.
    pub fn anim_phase_ms(self: *const Game) u32 {
        const cycle_samples: u64 = @as(u64, self.cycle_total_ms()) * (sample_rate / 1000);
        const pos = self.audio_frame % cycle_samples;
        return @intCast(pos / (sample_rate / 1000));
    }

    // -- face coupling --

    /// The face state the performance SHOULD be in, from the cycle.
    /// Peaks couple at the cycle peak; a completed cycle glows.
    fn face_target(self: *const Game) FaceState {
        if (self.peak_hold_ms > 0) return .peak;
        if (self.glow_ms > 0) return .glow;
        return switch (self.phase()) {
            .peak => .peak,
            .strokes, .release => .warm,
            .draw_in, .rest => if (self.progress() >= 0.5) .warm else .rest,
        };
    }

    pub fn progress(self: *const Game) f32 {
        return clamp01(@as(f32, @floatFromInt(self.total_yield_ml)) /
            @as(f32, @floatFromInt(self.level().target_ml)));
    }

    fn set_face_target(self: *Game, target: FaceState) void {
        if (target == self.face and !self.transition.active) return;
        const cell = transition_table[@intFromEnum(self.face)][@intFromEnum(target)];
        self.transition = .{
            .active = cell.duration_ms > 0,
            .from = self.params,
            .target = target,
            .elapsed_ms = 0,
            .duration_ms = cell.duration_ms,
            .via = .{ null, null },
        };
        if (cell.via_intermediate) {
            const lo = @min(@intFromEnum(self.face), @intFromEnum(target));
            const hi = @max(@intFromEnum(self.face), @intFromEnum(target));
            var slot: usize = 0;
            var s = lo + 1;
            while (s < hi and slot < 2) : (s += 1) {
                self.transition.via[slot] = @enumFromInt(s);
                slot += 1;
            }
        }
        self.face = target;
        if (cell.duration_ms == 0) self.params = face_keyframes[@intFromEnum(target)];
    }

    fn advance_transition(self: *Game, dt_ms: u32) void {
        if (!self.transition.active) return;
        self.transition.elapsed_ms += dt_ms;
        const tr = &self.transition;
        const target_params = face_keyframes[@intFromEnum(tr.target)];
        // Waypoint chain: from -> via[0] -> via[1] -> target.
        var points: [4]FaceParams = .{ tr.from, undefined, undefined, target_params };
        var n: usize = 2;
        if (tr.via[0]) |v| {
            points[1] = face_keyframes[@intFromEnum(v)];
            n = 3;
        }
        if (tr.via[1]) |v| {
            points[2] = face_keyframes[@intFromEnum(v)];
            n = 4;
        }
        if (tr.elapsed_ms >= tr.duration_ms) {
            self.params = target_params;
            tr.active = false;
            return;
        }
        const total = @as(f32, @floatFromInt(tr.duration_ms));
        const pos = @as(f32, @floatFromInt(tr.elapsed_ms)) / total * @as(f32, @floatFromInt(n - 1));
        const seg: usize = @min(@as(usize, @intFromFloat(pos)), n - 2);
        const local = ease_in_out(pos - @as(f32, @floatFromInt(seg)));
        self.params = lerp_params(points[seg], points[seg + 1], local);
    }

    // -- judging and accounting --

    /// Register a tap edge. Judged against the nearest pending beat
    /// centre (strokes at the preset window; the peak beat judges a
    /// little wider — the peak is the point of the cycle).
    fn judge_tap(self: *Game) void {
        const ph = self.phase();
        if (ph != .strokes and ph != .peak) return;
        const spec = self.preset_spec();
        if (ph == .peak) {
            if (self.peak_state != .pending) return;
            const c = self.peak_center();
            const dist = if (self.cycle_t >= c) self.cycle_t - c else c - self.cycle_t;
            if (dist <= spec.window_ms + 120) {
                self.peak_state = .hit;
                self.peak_hold_ms = 1500;
                self.event_code = Event.peak_good;
            }
            return;
        }
        const n = self.level().strokes_per_cycle;
        var best: ?usize = null;
        var best_dist: u32 = spec.window_ms + 1;
        for (0..n) |k| {
            if (self.strokes[k] != .pending) continue;
            const c = self.stroke_center(k);
            const dist = if (self.cycle_t >= c) self.cycle_t - c else c - self.cycle_t;
            if (dist < best_dist) {
                best_dist = dist;
                best = k;
            }
        }
        if (best) |k| {
            self.strokes[k] = .hit;
            self.cycle_hits += 1;
            self.stroke_flash_ms = 120;
            self.event_code = Event.stroke_good;
        }
    }

    fn close_windows(self: *Game) void {
        const spec = self.preset_spec();
        const n = self.level().strokes_per_cycle;
        for (0..n) |k| {
            if (self.strokes[k] == .pending and self.cycle_t > self.stroke_center(k) + spec.window_ms) {
                self.strokes[k] = .missed;
                self.event_code = Event.stroke_miss;
            }
        }
        if (self.phase() == .release and self.peak_state == .pending) {
            self.peak_state = .missed;
        }
    }

    /// Append one entry to the book of record. Bounded: past the bound
    /// the entry is dropped and counted (the stub's honest behaviour).
    fn append_chart(self: *Game, entry: ChartEntry) void {
        if (self.chart_len >= max_chart_entries) {
            self.chart_dropped += 1;
            return;
        }
        self.chart[self.chart_len] = entry;
        self.chart_len += 1;
    }

    /// Book the finished cycle: yield, chart entry, juice. Runs exactly
    /// once per cycle, at the release boundary.
    fn account_cycle(self: *Game) void {
        const spec = self.preset_spec();
        const full = self.peak_state == .hit;
        const gained = cycle_yield(spec, self.cycle_hits, full);
        self.total_yield_ml += gained;
        self.append_chart(.{
            .cycle = @intCast(self.cycle_index + 1),
            .preset = self.preset,
            .hits = @intCast(self.cycle_hits),
            .strokes = self.level().strokes_per_cycle,
            .yield_ml = @intCast(gained),
            .full = full,
        });
        self.cycle_index += 1;
        self.glow_ms = 1800;
        if (full) {
            // JUICE: hit-stop + flash on cycle completion.
            self.hitstop_left_ms = hitstop_ms;
            self.flash_left_ms = flash_ms;
            self.event_code = Event.letdown;
        } else {
            self.event_code = Event.partial;
        }
        if (self.total_yield_ml >= self.level().target_ml) self.session_done = true;
    }

    fn wrap_cycle(self: *Game) void {
        self.cycle_t -= self.cycle_total_ms();
        self.strokes = [_]BeatState{.pending} ** max_strokes;
        self.peak_state = .pending;
        self.cycle_hits = 0;
        self.accounted = false;
        if (self.preset_next) |p| {
            self.preset = p;
            self.preset_next = null;
        }
    }

    /// Queue a preset change (up = gentler, down = deeper on the panel's
    /// ordering gentle -> standard -> deep). Applies at the cycle wrap;
    /// the running cycle is never re-judged retroactively.
    fn queue_preset(self: *Game, delta: i32) void {
        const cur: i32 = @intFromEnum(self.preset_next orelse self.preset);
        const next = std.math.clamp(cur + delta, 0, 2);
        self.preset_next = @enumFromInt(@as(u8, @intCast(next)));
        self.event_code = Event.ui_move;
    }

    /// Demo policy: taps exactly on beat centres (with a fixed 40 ms
    /// late bias so traces show a human-ish judge), auto-confirms menus.
    fn demo_input(self: *Game) u32 {
        var input: u32 = 0;
        switch (self.screen) {
            .gate => if (self.screen_ms > 600) {
                input |= Input.confirm;
            },
            .title => if (self.screen_ms > 700) {
                input |= Input.confirm;
            },
            .play => {
                const ph = self.phase();
                if (ph == .strokes) {
                    const n = self.level().strokes_per_cycle;
                    for (0..n) |k| {
                        if (self.strokes[k] == .pending and self.cycle_t >= self.stroke_center(k) + 40) {
                            input |= Input.tap;
                        }
                    }
                } else if (ph == .peak) {
                    if (self.peak_state == .pending and self.cycle_t >= self.peak_center() + 40) {
                        input |= Input.tap;
                    }
                }
            },
            .victory, .gameover => if (self.screen_ms > 1500) {
                input |= Input.confirm;
            },
            else => {},
        }
        return input;
    }

    /// One fixed step. dt_ms is contractual (16); wild values are clamped
    /// into [0, 250] rather than trusted (adversarial boundary).
    pub fn step(self: *Game, dt_raw: u32, input_raw: u32) void {
        self.event_code = Event.none;
        const dt_ms = @min(dt_raw, 250);
        var input = input_raw;
        if (self.demo) input |= self.demo_input();
        self.frame += 1;
        self.screen_ms += dt_ms;

        switch (self.screen) {
            .gate => {
                if (input & Input.confirm != 0) self.goto(.title);
            },
            .title => self.step_title(input),
            .howto => {
                if (input & (Input.confirm | Input.back) != 0) self.goto(.title);
            },
            .settings => self.step_settings(input),
            .pause => self.step_menu(input, &pause_items),
            .play => self.step_play(dt_ms, input),
            .victory, .gameover => {
                if (input & Input.confirm != 0) self.goto(.title);
            },
        }
        self.advance_transition(dt_ms);
    }

    const MenuAction = enum { start, howto, settings, resume_game, restart, quit };
    const MenuItem = struct { label: []const u8, action: MenuAction };
    const pause_items = [_]MenuItem{
        .{ .label = "RESUME", .action = .resume_game },
        .{ .label = "RESTART", .action = .restart },
        .{ .label = "QUIT TO TITLE", .action = .quit },
    };

    fn step_menu(self: *Game, input: u32, items: []const MenuItem) void {
        if (input & Input.down != 0) {
            self.menu_cursor = @min(self.menu_cursor + 1, @as(u8, @intCast(items.len - 1)));
            self.event_code = Event.ui_move;
        }
        if (input & Input.up != 0) {
            self.menu_cursor -|= 1;
            self.event_code = Event.ui_move;
        }
        if (input & Input.confirm != 0) {
            switch (items[self.menu_cursor].action) {
                .start => self.start_level(self.level_idx),
                .howto => self.goto(.howto),
                .settings => self.goto(.settings),
                .resume_game => self.goto(.play),
                .restart => self.start_level(self.level_idx),
                .quit => self.goto(.title),
            }
        }
    }

    /// Title screen: rows 0-2 are the menu; row 3 picks the level; row 4
    /// picks the pump's comfort preset (tap or confirm cycles it).
    fn step_title(self: *Game, input: u32) void {
        if (input & Input.down != 0) {
            self.menu_cursor = @min(self.menu_cursor + 1, 4);
            self.event_code = Event.ui_move;
        }
        if (input & Input.up != 0) {
            self.menu_cursor -|= 1;
            self.event_code = Event.ui_move;
        }
        if (self.menu_cursor >= 3) {
            if (input & (Input.tap | Input.confirm) != 0) {
                if (self.menu_cursor == 3) {
                    self.level_idx = (self.level_idx + 1) % levels.len;
                } else {
                    self.preset = @enumFromInt((@intFromEnum(self.preset) + 1) % 3);
                }
                self.event_code = Event.ui_move;
            }
            return;
        }
        if (input & Input.confirm != 0) {
            switch (self.menu_cursor) {
                0 => self.start_level(self.level_idx),
                1 => self.goto(.howto),
                2 => self.goto(.settings),
                else => unreachable,
            }
        }
    }

    fn step_settings(self: *Game, input: u32) void {
        if (input & Input.down != 0) self.menu_cursor = @min(self.menu_cursor + 1, 2);
        if (input & Input.up != 0) self.menu_cursor -|= 1;
        if (input & Input.confirm != 0) {
            switch (self.menu_cursor) {
                0 => self.preset = @enumFromInt((@intFromEnum(self.preset) + 1) % 3),
                1 => self.flash_reduced = !self.flash_reduced,
                2 => self.text_large = !self.text_large,
                else => unreachable,
            }
            self.event_code = Event.ui_move;
        }
        if (input & Input.back != 0) self.goto(.title);
    }

    fn step_play(self: *Game, dt_ms: u32, input: u32) void {
        if (input & Input.pause_btn != 0) {
            self.goto(.pause);
            return;
        }
        // JUICE: hit-stop. The rig — sample clock included — freezes for
        // a breath on a full let-down; the flash decays in real steps.
        if (self.hitstop_left_ms > 0) {
            self.hitstop_left_ms -|= dt_ms;
            self.flash_left_ms -|= dt_ms;
            return;
        }
        self.flash_left_ms -|= dt_ms;
        self.stroke_flash_ms -|= dt_ms;
        self.peak_hold_ms -|= dt_ms;
        self.glow_ms -|= dt_ms;
        self.elapsed_ms += dt_ms;

        if (input & Input.up != 0) self.queue_preset(-1);
        if (input & Input.down != 0) self.queue_preset(1);
        if (input & Input.tap != 0) self.judge_tap();
        self.close_windows();

        // Advance the cycle and the master clock by the same step:
        // dt_ms of stream time is dt_ms * 48 samples, exactly.
        const prev_t = self.cycle_t;
        self.cycle_t += dt_ms;
        self.audio_frame += @as(u64, dt_ms) * (sample_rate / 1000);
        if (!self.accounted and prev_t < self.release_start() and self.cycle_t >= self.release_start()) {
            self.account_cycle();
        }
        if (self.cycle_t >= self.cycle_total_ms()) {
            if (self.session_done) {
                self.event_code = Event.victory;
                self.goto(.victory);
                return;
            }
            self.wrap_cycle();
        }
        self.set_face_target(self.face_target());

        if (self.elapsed_ms >= self.level().time_limit_ms) {
            self.event_code = Event.game_over;
            self.goto(.gameover);
        }
    }
};

// ---------------------------------------------------------------------------
// Draw-list emission (bounded writer over a static buffer)
// ---------------------------------------------------------------------------

var draw_buffer: [draw_buffer_bytes]u8 = undefined;

pub const DrawWriter = struct {
    len: usize = 0,
    ops: usize = 0,
    dropped: u32 = 0,

    pub fn reset(self: *DrawWriter) void {
        self.len = 0;
        self.ops = 0;
        self.dropped = 0;
    }

    fn line(self: *DrawWriter, comptime fmt: []const u8, args: anytype) void {
        if (self.ops >= max_ops) {
            self.dropped += 1;
            return;
        }
        const out = std.fmt.bufPrint(draw_buffer[self.len..], fmt, args) catch {
            self.dropped += 1;
            return;
        };
        self.len += out.len;
        self.ops += 1;
    }

    pub fn rect(self: *DrawWriter, x: i32, y: i32, w: i32, h: i32, c: u8) void {
        self.line("r {d} {d} {d} {d} {d}\n", .{ x, y, w, h, c });
    }
    pub fn circle(self: *DrawWriter, x: i32, y: i32, r: i32, c: u8) void {
        self.line("c {d} {d} {d} {d}\n", .{ x, y, r, c });
    }
    pub fn seg(self: *DrawWriter, x1: i32, y1: i32, x2: i32, y2: i32, w: i32, c: u8) void {
        self.line("l {d} {d} {d} {d} {d} {d}\n", .{ x1, y1, x2, y2, w, c });
    }
    pub fn tri(self: *DrawWriter, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, c: u8) void {
        self.line("p {d} {d} {d} {d} {d} {d} {d}\n", .{ x1, y1, x2, y2, x3, y3, c });
    }
    pub fn text(self: *DrawWriter, x: i32, y: i32, size: i32, c: u8, s: []const u8) void {
        // Text payloads are restricted to a printable subset by contract
        // with the shell/rasteriser; anything else becomes '?'.
        var clean: [48]u8 = undefined;
        const n = @min(s.len, clean.len);
        for (0..n) |i| {
            const ch = s[i];
            clean[i] = if ((ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
                ch == ' ' or ch == '-' or ch == '.' or ch == ':' or ch == '+' or
                ch == '!' or ch == '?' or ch == '/' or ch == '(' or ch == ')' or
                ch == '%' or ch == '&' or ch == ',')
                ch
            else if (ch >= 'a' and ch <= 'z')
                ch - 32
            else
                '?';
        }
        self.line("t {d} {d} {d} {d} {s}\n", .{ x, y, size, c, clean[0..n] });
    }
};

fn fi(x: f32) i32 {
    return @intFromFloat(@round(x));
}

// ---------------------------------------------------------------------------
// Rendering: café, pump rig, portrait, chart, screens
// ---------------------------------------------------------------------------

pub const Renderer = struct {
    pub fn render(g: *const Game, w: *DrawWriter) void {
        w.rect(0, 0, canvas_px, canvas_px, Palette.bg);
        switch (g.screen) {
            .gate => render_gate(g, w),
            .title => render_title(g, w),
            .howto => render_howto(g, w),
            .settings => render_settings(g, w),
            .play, .pause => {
                render_scene(g, w);
                if (g.screen == .pause) render_pause(g, w);
            },
            .victory => render_end(g, w, true),
            .gameover => render_end(g, w, false),
        }
    }

    fn text_size(g: *const Game, base: i32) i32 {
        return if (g.text_large) @divTrunc(base * 14, 10) else base;
    }

    fn render_gate(g: *const Game, w: *DrawWriter) void {
        w.text(330, 300, text_size(g, 64), Palette.pink, "CREAMERY");
        w.text(250, 420, text_size(g, 30), Palette.paper, "ALMA AND THE MORNING PUMP");
        w.text(240, 540, text_size(g, 28), Palette.rose, "THIS GAME IS FOR ADULTS ONLY (18+)");
        w.text(230, 600, text_size(g, 24), Palette.dim, "CONTAINS ADULT ROLEPLAY AND LACTATION THEMES");
        if ((g.frame / 30) % 2 == 0) w.text(330, 720, text_size(g, 28), Palette.paper, "PRESS CONFIRM TO ENTER");
    }

    fn render_title(g: *const Game, w: *DrawWriter) void {
        render_steam(g, w);
        w.text(320, 130, text_size(g, 72), Palette.pink, "CREAMERY");
        w.text(290, 220, text_size(g, 24), Palette.dim, "ALMA - THE TRACK IS THE SCORE");
        const items = [_][]const u8{ "START", "HOW TO PLAY", "SETTINGS" };
        for (items, 0..) |label, i| {
            const y: i32 = 360 + @as(i32, @intCast(i)) * 74;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            if (i == g.menu_cursor) w.text(240, y, text_size(g, 34), Palette.pink, ">");
            w.text(290, y, text_size(g, 34), c, label);
        }
        // Level row (cursor 3) and preset row (cursor 4): tap cycles.
        var buf: [64]u8 = undefined;
        const ls = std.fmt.bufPrint(&buf, "LEVEL: {s}", .{levels[g.level_idx].name}) catch "LEVEL";
        if (g.menu_cursor == 3) w.text(240, 600, text_size(g, 26), Palette.pink, ">");
        w.text(290, 600, text_size(g, 26), if (g.menu_cursor == 3) Palette.pink else Palette.gold, ls);
        const ps = std.fmt.bufPrint(&buf, "PUMP PRESET: {s}", .{g.preset.label()}) catch "PRESET";
        if (g.menu_cursor == 4) w.text(240, 660, text_size(g, 26), Palette.pink, ">");
        w.text(290, 660, text_size(g, 26), if (g.menu_cursor == 4) Palette.pink else Palette.gold, ps);
        w.text(260, 730, text_size(g, 20), Palette.dim, "UP/DOWN CHOOSES - CONFIRM STARTS OR CYCLES");
        w.text(300, 800, text_size(g, 20), Palette.dim, "COMFORT IS NEVER LOCKED: CHANGE IT ANY TIME");
    }

    fn render_howto(g: *const Game, w: *DrawWriter) void {
        w.text(240, 130, text_size(g, 44), Palette.pink, "HOW TO PLAY");
        const lines = [_][]const u8{
            "THE PUMP RUNS IN CYCLES. EACH CYCLE:",
            "IT DRAWS IN, THEN COUNTS ITS STROKES.",
            "TAP (OR SPACE) ON EACH STROKE BEAT,",
            "AND AGAIN ON THE PEAK AT THE TOP.",
            "",
            "HIT STROKES FILL THE CYCLE. A HIT PEAK",
            "LETS THE WHOLE CYCLE DOWN AT FULL RATE.",
            "EVERY CYCLE IS WRITTEN IN THE BOOK.",
            "REACH THE TARGET YIELD BEFORE TIME.",
            "",
            "PRESETS TRADE COMFORT FOR RATE:",
            "GENTLE WIDE + SLOW, DEEP NARROW + FAST.",
            "UP/DOWN IN PLAY QUEUES A NEW PRESET",
            "FOR THE NEXT CYCLE - NEVER MID-CYCLE.",
        };
        for (lines, 0..) |ln, i| {
            w.text(150, 220 + @as(i32, @intCast(i)) * 44, text_size(g, 24), Palette.paper, ln);
        }
        if ((g.frame / 30) % 2 == 0) w.text(300, 880, text_size(g, 24), Palette.dim, "CONFIRM TO RETURN");
    }

    fn render_settings(g: *const Game, w: *DrawWriter) void {
        w.text(300, 160, text_size(g, 44), Palette.pink, "SETTINGS");
        var buf: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "PUMP PRESET: {s}", .{g.preset.label()}) catch "";
        const rows = [_][]const u8{
            p,
            if (g.flash_reduced) "FLASH: REDUCED" else "FLASH: FULL",
            if (g.text_large) "TEXT SIZE: LARGE" else "TEXT SIZE: NORMAL",
        };
        for (rows, 0..) |row, i| {
            const y: i32 = 320 + @as(i32, @intCast(i)) * 90;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            if (i == g.menu_cursor) w.text(150, y, text_size(g, 30), Palette.pink, ">");
            w.text(200, y, text_size(g, 30), c, row);
        }
        w.text(240, 700, text_size(g, 22), Palette.dim, "CONFIRM CYCLES OR TOGGLES - BACK RETURNS");
        w.text(210, 750, text_size(g, 22), Palette.dim, "THESE SETTINGS ARE NEVER GATED BY PROGRESS");
    }

    fn render_pause(g: *const Game, w: *DrawWriter) void {
        w.rect(180, 240, 600, 440, Palette.deep);
        w.text(360, 290, text_size(g, 40), Palette.pink, "PAUSED");
        const items = [_][]const u8{ "RESUME", "RESTART", "QUIT TO TITLE" };
        for (items, 0..) |label, i| {
            const y: i32 = 390 + @as(i32, @intCast(i)) * 80;
            const c: u8 = if (i == g.menu_cursor) Palette.pink else Palette.paper;
            if (i == g.menu_cursor) w.text(280, y, text_size(g, 30), Palette.pink, ">");
            w.text(330, y, text_size(g, 30), c, label);
        }
    }

    /// The book of record, charted: one bar per booked cycle (latest
    /// chart_bars_shown), pink for a full let-down, mauve for partial.
    fn render_end(g: *const Game, w: *DrawWriter, won: bool) void {
        render_steam(g, w);
        if (won) {
            w.text(280, 90, text_size(g, 52), Palette.pink, "THE BOOK IS FULL");
            w.text(300, 170, text_size(g, 28), Palette.paper, "TARGET REACHED - SHE IS CONTENT");
        } else {
            w.text(230, 90, text_size(g, 52), Palette.mauve, "THE MORNING ENDS SHORT");
            w.text(360, 170, text_size(g, 28), Palette.paper, "TIME RAN OUT");
        }
        w.text(330, 250, text_size(g, 30), Palette.gold, "THE BOOK OF RECORD");
        const shown = @min(g.chart_len, chart_bars_shown);
        const start = g.chart_len - shown;
        var max_yield: u32 = 1;
        for (g.chart[start..g.chart_len]) |e| max_yield = @max(max_yield, e.yield_ml);
        // Baseline + bars
        w.seg(150, 700, 830, 700, 3, Palette.dim);
        for (0..shown) |i| {
            const e = g.chart[start + i];
            const h: i32 = @intCast(@as(u32, e.yield_ml) * 300 / max_yield);
            const x: i32 = 170 + @as(i32, @intCast(i)) * 54;
            w.rect(x, 700 - h, 38, h, if (e.full) Palette.pink else Palette.mauve);
            var buf: [16]u8 = undefined;
            const cs = std.fmt.bufPrint(&buf, "{d}", .{e.cycle}) catch "";
            w.text(x + 8, 716, 18, Palette.dim, cs);
            const ys = std.fmt.bufPrint(&buf, "{d}", .{e.yield_ml}) catch "";
            w.text(x + 2, 668 - h, 18, Palette.paper, ys);
        }
        if (shown == 0) w.text(330, 500, text_size(g, 26), Palette.dim, "NO CYCLES BOOKED YET");
        var buf: [64]u8 = undefined;
        const ts = std.fmt.bufPrint(&buf, "TOTAL {d} ML IN {d} CYCLES", .{ g.total_yield_ml, g.cycle_index }) catch "";
        w.text(300, 780, text_size(g, 28), Palette.gold, ts);
        if ((g.frame / 30) % 2 == 0) w.text(310, 860, text_size(g, 24), Palette.dim, "CONFIRM FOR TITLE");
    }

    /// Steam and lamplight: ambient life, all positions pure functions
    /// of elapsed time. Lamp glow breathes with the pump pulse. Lamps
    /// hang only on the non-play screens: in play they would sit inside
    /// the HUD text block (found by D-221 frame inspection, B-2).
    fn render_steam(g: *const Game, w: *DrawWriter) void {
        const t = @as(f32, @floatFromInt(g.elapsed_ms + g.screen_ms)) / 1000.0;
        const pulse = if (g.screen == .play or g.screen == .pause) pump_pulse(g) else 0.0;
        if (g.screen == .play or g.screen == .pause) {
            // steam only; skip the lamp loop
        } else for ([_]i32{ 190, 770 }) |lx| {
            w.seg(lx, 0, lx, 74, 3, Palette.dim);
            w.circle(lx, 96, 26 + fi(pulse * 8.0), Palette.gold);
            w.circle(lx, 96, 15, Palette.paper);
        }
        var i: usize = 0;
        while (i < max_motes) : (i += 1) {
            const base = g.motes[i];
            const x = @mod(@as(f32, @floatFromInt(base[0])) + @sin(t * 0.7 + @as(f32, @floatFromInt(i))) * 12.0, 960.0);
            const y = @mod(@as(f32, @floatFromInt(base[1])) - t * 16.0, 960.0);
            w.circle(fi(x), fi(y), 3, if (i % 3 == 0) Palette.rose else Palette.dim);
        }
    }

    /// The pump's stroke pulse, 0..1: the animation value the whole
    /// scene locks to. Derived from cycle position (hence, through the
    /// step lockstep, from the sample clock).
    fn pump_pulse(g: *const Game) f32 {
        const ph = g.phase();
        return switch (ph) {
            .draw_in => ease_in_out(@as(f32, @floatFromInt(g.cycle_t)) / @as(f32, @floatFromInt(draw_in_ms))),
            .strokes => blk: {
                const local = g.cycle_t - draw_in_ms;
                const seg: f32 = @as(f32, @floatFromInt(local % g.level().stroke_ms)) /
                    @as(f32, @floatFromInt(g.level().stroke_ms));
                break :blk @sin(seg * 3.14159);
            },
            .peak => 1.0,
            .release => 1.0 - ease_in_out(@as(f32, @floatFromInt(g.cycle_t - g.release_start())) / @as(f32, @floatFromInt(release_ms))),
            .rest => 0.0,
        };
    }

    fn render_scene(g: *const Game, w: *DrawWriter) void {
        render_steam(g, w);
        render_pump(g, w);
        render_portrait(g, w);
        render_hud(g, w);
        render_flash(g, w);
    }

    /// The pump rig: column, bellows (height = pulse), collection cup
    /// for the running cycle, the session vessel, and the phase ring.
    fn render_pump(g: *const Game, w: *DrawWriter) void {
        const pulse = pump_pulse(g);
        // Counter and base
        w.rect(90, 824, 480, 14, Palette.plum);
        w.rect(120, 720, 300, 104, Palette.deep);
        w.rect(120, 720, 300, 10, Palette.mauve);
        // Column + bellows
        w.rect(252, 470, 36, 250, Palette.mauve);
        const bellows_h: i32 = 56 + fi(pulse * 74.0);
        var s: i32 = 0;
        while (s < 4) : (s += 1) {
            const y: i32 = 470 - bellows_h + @divTrunc(s * bellows_h, 4);
            w.rect(196, y, 148, @divTrunc(bellows_h, 4) - 4, if (@rem(s, 2) == 0) Palette.plum else Palette.pink);
        }
        w.rect(186, 470 - bellows_h - 16, 168, 16, Palette.gold);
        // Phase ring around the bellows: arc fraction = cycle progress.
        const frac = @as(f32, @floatFromInt(g.cycle_t)) / @as(f32, @floatFromInt(g.cycle_total_ms()));
        const ring_c: u8 = switch (g.phase()) {
            .draw_in => Palette.dim,
            .strokes => Palette.paper,
            .peak => Palette.pink,
            .release => Palette.gold,
            .rest => Palette.mauve,
        };
        var k: usize = 0;
        const segs: usize = 36;
        while (k < segs) : (k += 1) {
            if (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(segs)) > frac) break;
            const a1 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(segs)) * 6.2832 - 1.5708;
            const a2 = @as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(segs)) * 6.2832 - 1.5708;
            w.seg(270 + fi(@cos(a1) * 128.0), 400 + fi(@sin(a1) * 128.0), 270 + fi(@cos(a2) * 128.0), 400 + fi(@sin(a2) * 128.0), 4, ring_c);
        }
        if (g.stroke_flash_ms > 0) {
            // A ring, not a disc: a filled circle swallows the rig
            // whole (found by D-221 frame inspection, B-2).
            var fk: usize = 0;
            while (fk < segs) : (fk += 1) {
                const a1 = @as(f32, @floatFromInt(fk)) / @as(f32, @floatFromInt(segs)) * 6.2832;
                const a2 = @as(f32, @floatFromInt(fk + 1)) / @as(f32, @floatFromInt(segs)) * 6.2832;
                w.seg(270 + fi(@cos(a1) * 148.0), 400 + fi(@sin(a1) * 148.0), 270 + fi(@cos(a2) * 148.0), 400 + fi(@sin(a2) * 148.0), 5, Palette.pink);
            }
        }
        // Tubing from the rig toward her (a soft arc of dots that travel
        // with the strokes — secondary motion locked to the same clock)
        var d: usize = 0;
        while (d < 7) : (d += 1) {
            const u = @mod(@as(f32, @floatFromInt(d)) / 7.0 + pulse * 0.12, 1.0);
            const x = lerp(340.0, 600.0, u);
            const y = 400.0 + @sin(u * 3.14159) * 90.0 + u * 120.0;
            w.circle(fi(x), fi(y), 4, Palette.rose);
        }
        // Running-cycle cup under the spout: fills with hit strokes.
        const n = g.level().strokes_per_cycle;
        const cup_frac = @as(f32, @floatFromInt(g.cycle_hits)) / @as(f32, @floatFromInt(n));
        w.rect(196, 640, 148, 64, Palette.deep);
        w.rect(196, 640 + fi((1.0 - cup_frac) * 64.0), 148, fi(cup_frac * 64.0), Palette.rose);
        w.seg(196, 640, 344, 640, 3, Palette.mauve);
        // Session vessel: the morning's yield against the target line.
        w.rect(470, 470, 92, 354, Palette.deep);
        const fill_h = fi(g.progress() * 354.0);
        w.rect(470, 824 - fill_h, 92, fill_h, Palette.skin);
        w.seg(462, 470, 570, 470, 4, Palette.gold);
        w.text(452, 428, 20, Palette.gold, "TARGET");
    }

    /// Abstract-symbolic portrait: posture (shoulders, head sink/tilt)
    /// and expression (lids, iris discs, brows, mouth, blush) both read
    /// from the interpolated FaceParams — the same renderer shape W1
    /// validated, staged at the café counter.
    fn render_portrait(g: *const Game, w: *DrawWriter) void {
        const p = g.params;
        const cx: i32 = 742 + fi(p.head_tilt);
        const cy: i32 = 452 + fi(p.head_sink);
        // Shoulders / apron (posture)
        const sy: i32 = 800 + fi(p.shoulder_y);
        w.tri(560, 960, 924, 960, 742, sy, Palette.plum);
        w.tri(600, 960, 884, 960, 742, sy + 60, Palette.paper); // apron
        w.rect(cx - 26, cy + 148, 52, 70, Palette.skin);
        // Hair mass behind the head
        w.circle(cx - 94, cy - 30, 94, Palette.plum);
        w.circle(cx + 94, cy - 30, 94, Palette.plum);
        w.circle(cx, cy - 70, 118, Palette.plum);
        // Head
        w.circle(cx, cy, 130, Palette.skin);
        // Hair fringe
        w.tri(cx - 130, cy - 46, cx + 130, cy - 46, cx, cy - 148, Palette.plum);
        // Blush (banded by intensity; palette steps stand in for alpha)
        if (p.blush > 0.25) {
            const bc: u8 = if (p.blush > 0.66) Palette.rose else Palette.mauve;
            w.circle(cx - 74, cy + 48, 24, bc);
            w.circle(cx + 74, cy + 48, 24, bc);
        }
        // Eyes: white, iris disc (full-disc centre = gaze), lids
        for ([_]i32{ -56, 56 }) |dx| {
            const ex = cx + dx;
            const ey = cy - 8;
            w.circle(ex, ey, 24, Palette.paper);
            const gx = ex + fi(p.gaze_x * 10.0);
            const gy = ey + fi(p.gaze_y * 10.0);
            w.circle(gx, gy, 12, Palette.plum);
            w.circle(gx, gy, 5, Palette.bg);
            if (p.gaze_y > 0.5 and p.eye_open < 0.3) {
                // High-arousal marker: the peak state's warm iris ring.
                w.circle(gx, gy, 14, Palette.rose);
                w.circle(gx, gy, 12, Palette.plum);
            }
            const lid = fi((1.0 - p.eye_open) * 27.0);
            if (lid > 0) w.rect(ex - 26, ey - 26, 52, lid, Palette.skin);
            // Brow
            const by = ey - 42 - fi(p.brow_lift * 8.0);
            w.seg(ex - 24, by, ex + 24, by - 3, 4, Palette.plum);
        }
        // Nose + mouth
        w.seg(cx, cy + 22, cx - 5, cy + 38, 3, Palette.mauve);
        if (p.mouth_open > 0.25) {
            w.circle(cx, cy + 74, 6 + fi(p.mouth_open * 13.0), Palette.plum);
        } else {
            w.seg(cx - 17, cy + 74, cx + 17, cy + 74, 4, Palette.plum);
        }
    }

    fn render_hud(g: *const Game, w: *DrawWriter) void {
        const lvl = g.level();
        w.text(36, 36, text_size(g, 22), Palette.dim, lvl.name);
        w.text(36, 72, text_size(g, 22), Palette.paper, g.face.label());
        var buf: [64]u8 = undefined;
        const ys = std.fmt.bufPrint(&buf, "YIELD {d} / {d} ML", .{ g.total_yield_ml, lvl.target_ml }) catch "";
        w.text(36, 140, text_size(g, 24), Palette.gold, ys);
        const cs = std.fmt.bufPrint(&buf, "CYCLE {d}", .{g.cycle_index + 1}) catch "";
        w.text(36, 178, text_size(g, 20), Palette.dim, cs);
        const ps = if (g.preset_next) |p|
            std.fmt.bufPrint(&buf, "PRESET {s} - NEXT {s}", .{ g.preset.label(), p.label() }) catch ""
        else
            std.fmt.bufPrint(&buf, "PRESET {s}", .{g.preset.label()}) catch "";
        w.text(36, 106, text_size(g, 20), Palette.rose, ps);
        // Time left
        const remain = lvl.time_limit_ms -| g.elapsed_ms;
        const ts = std.fmt.bufPrint(&buf, "TIME {d}:{d:0>2}", .{ remain / 60000, (remain / 1000) % 60 }) catch "";
        w.text(790, 36, text_size(g, 22), Palette.dim, ts);
        // Phase label + stroke pips
        const ph = g.phase();
        const label: []const u8 = switch (ph) {
            .draw_in => "DRAWING IN",
            .strokes => "TAP ON THE STROKES",
            .peak => "THE PEAK - TAP NOW",
            .release => "LETTING DOWN",
            .rest => "RESTING",
        };
        // Left column, under the rig: centred, this text would run
        // across her white apron and vanish (D-221 frame check, B-2).
        w.text(110, 856, text_size(g, 26), if (ph == .peak) Palette.pink else Palette.paper, label);
        const n = lvl.strokes_per_cycle;
        for (0..n) |k| {
            const x: i32 = 384 + @as(i32, @intCast(k)) * 44;
            const c: u8 = switch (g.strokes[k]) {
                .hit => Palette.pink,
                .missed => Palette.mauve,
                .pending => Palette.paper,
            };
            w.circle(x, 916, 13, c);
        }
        // The peak pip: a diamond after the stroke pips.
        const px: i32 = 384 + @as(i32, @intCast(n)) * 44;
        const pc: u8 = switch (g.peak_state) {
            .hit => Palette.gold,
            .missed => Palette.mauve,
            .pending => Palette.rose,
        };
        w.tri(px, 898, px + 15, 916, px, 934, pc);
        w.tri(px, 934, px - 15, 916, px, 898, pc);
    }

    /// The completion flash. Levels by remaining time; the reduced
    /// setting caps it to a border (accessibility, never gated).
    fn render_flash(g: *const Game, w: *DrawWriter) void {
        if (g.flash_left_ms == 0) return;
        if (g.flash_reduced) {
            w.rect(0, 0, canvas_px, 12, Palette.pink);
            w.rect(0, canvas_px - 12, canvas_px, 12, Palette.pink);
            w.rect(0, 0, 12, canvas_px, Palette.pink);
            w.rect(canvas_px - 12, 0, 12, canvas_px, Palette.pink);
            return;
        }
        if (g.flash_left_ms > flash_ms * 2 / 3) {
            w.rect(0, 0, canvas_px, canvas_px, Palette.paper);
        } else if (g.flash_left_ms > flash_ms / 3) {
            w.rect(0, 0, canvas_px, canvas_px, Palette.rose);
        } else {
            w.rect(0, 0, canvas_px, 10, Palette.pink);
            w.rect(0, canvas_px - 10, canvas_px, 10, Palette.pink);
            w.rect(0, 0, 10, canvas_px, Palette.pink);
            w.rect(canvas_px - 10, 0, 10, canvas_px, Palette.pink);
        }
    }
};

// ---------------------------------------------------------------------------
// Public orchestration: the wasm boundary
// ---------------------------------------------------------------------------

var game: Game = Game.init(1, false);
var writer: DrawWriter = .{};
var current_draw_len: usize = 0;

/// Initialise (or reset) the game. Returns 0 on success, -1 on an invalid
/// level (the game is still initialised, at level 0 — the shell must not
/// pass unchecked user input here; the level comes from the title screen).
export fn init(seed: u32, level: u8) i32 {
    return init_mode(seed, level, false);
}

/// Demo-mode init: the core auto-plays (menus auto-confirm, taps land on
/// beat centres). Used by the preview capture harness; also reachable in
/// the shipped page as ?demo=<level>&seed=<n>.
export fn init_demo(seed: u32, level: u8) i32 {
    return init_mode(seed, level, true);
}

fn init_mode(seed: u32, level: u8, demo: bool) i32 {
    const idx = validate_level(level) catch {
        game = Game.init(seed, demo);
        return -1;
    };
    game = Game.init(seed, demo);
    game.level_idx = idx;
    return 0;
}

/// Jump straight into a level (capture harness + shell "quick start").
export fn start_level(level: u8) i32 {
    const idx = validate_level(level) catch return -1;
    game.start_level(idx);
    return 0;
}

/// One fixed step + render. dt_ms contractual 16; clamped inside.
export fn step(dt_ms: u32, input: u32) void {
    game.step(dt_ms, input);
    writer.reset();
    Renderer.render(&game, &writer);
    game.dropped_ops = writer.dropped;
    current_draw_len = writer.len;
}

export fn draw_ptr() [*]const u8 {
    return &draw_buffer;
}
export fn draw_len() usize {
    return current_draw_len;
}
export fn screen() u8 {
    return @intFromEnum(game.screen);
}
export fn event_code() u8 {
    return game.event_code;
}
export fn level_idx() u8 {
    return @intCast(game.level_idx);
}

/// Session yield so far, whole ml (the shell's record of the morning).
export fn yield_ml() u32 {
    return game.total_yield_ml;
}

/// Session progress toward the level target, in thousandths.
export fn progress_milli() u32 {
    return @intFromFloat(game.progress() * 1000.0);
}

/// Persistence bridge: the shell owns localStorage and restores the
/// settings at boot through here (the core itself performs no I/O).
/// An out-of-range preset is ignored, never clamped into a wrong one.
export fn apply_settings(preset: u8, flash_reduced: u8, text_large: u8) void {
    if (validate_preset(preset)) |p| {
        game.preset = p;
    } else |_| {}
    game.flash_reduced = flash_reduced != 0;
    game.text_large = text_large != 0;
}

/// Current settings as bits (bits 0-1 preset, bit 2 flash_reduced,
/// bit 3 text_large) so the shell can persist them when they change.
export fn settings_bits() u8 {
    return @intFromEnum(game.preset) |
        (@as(u8, if (game.flash_reduced) 1 else 0) << 2) |
        (@as(u8, if (game.text_large) 1 else 0) << 3);
}

// ---------------------------------------------------------------------------
// Tests — half validation, half adversarial (estate rule)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "preset table trades window for yield monotonically" {
    const t = preset_table;
    try testing.expect(t[0].window_ms > t[1].window_ms and t[1].window_ms > t[2].window_ms);
    try testing.expect(t[0].per_hit_ml < t[1].per_hit_ml and t[1].per_hit_ml < t[2].per_hit_ml);
    try testing.expect(t[0].base_ml < t[1].base_ml and t[1].base_ml < t[2].base_ml);
    for (t) |spec| {
        try testing.expect(spec.window_ms >= 2 * step_ms); // judgeable at step grain
        try testing.expect(spec.base_ml > 0 and spec.per_hit_ml > 0);
    }
}

test "cycle yield accounting is exact" {
    const std_spec = preset_table[1];
    // Standard, all four strokes + peak: (12 + 4*8) * 125% = 55 exactly.
    try testing.expectEqual(@as(u32, 55), cycle_yield(std_spec, 4, true));
    // Same strokes, missed peak: 44 * 70% = 30 (30.8 floored).
    try testing.expectEqual(@as(u32, 30), cycle_yield(std_spec, 4, false));
    // Gentle, no strokes, missed peak: the base still yields, 10*70% = 7.
    try testing.expectEqual(@as(u32, 7), cycle_yield(preset_table[0], 0, false));
    // Deep, six strokes + peak: (14 + 6*11) * 125% = 100 exactly.
    try testing.expectEqual(@as(u32, 100), cycle_yield(preset_table[2], 6, true));
}

test "transition table is total and shaped as specified" {
    for (0..4) |from| {
        for (0..4) |to| {
            const cell = transition_table[from][to];
            if (from == to) {
                try testing.expectEqual(@as(u32, 0), cell.duration_ms);
                try testing.expect(!cell.via_intermediate);
            } else if (to > from) {
                try testing.expectEqual(@as(u32, 900) * @as(u32, @intCast(to - from)), cell.duration_ms);
                try testing.expectEqual(to - from > 1, cell.via_intermediate);
            } else {
                try testing.expectEqual(@as(u32, 500) * @as(u32, @intCast(from - to)), cell.duration_ms);
                try testing.expectEqual(from - to > 1, cell.via_intermediate);
            }
        }
    }
}

test "keyframes move posture AND expression monotonically rest to peak" {
    const k = face_keyframes;
    try testing.expect(k[0].eye_open > k[1].eye_open and k[1].eye_open > k[2].eye_open);
    try testing.expect(k[0].blush < k[1].blush and k[1].blush < k[2].blush);
    try testing.expect(k[0].mouth_open < k[1].mouth_open and k[1].mouth_open < k[2].mouth_open);
    try testing.expect(k[0].head_sink < k[1].head_sink and k[1].head_sink < k[2].head_sink and k[2].head_sink < k[3].head_sink);
    try testing.expect(k[0].shoulder_y < k[1].shoulder_y and k[1].shoulder_y < k[2].shoulder_y and k[2].shoulder_y < k[3].shoulder_y);
    for (k) |p| {
        try testing.expect(p.eye_open >= 0 and p.eye_open <= 1);
        try testing.expect(p.blush >= 0 and p.blush <= 1);
        try testing.expect(p.gaze_x >= -1 and p.gaze_x <= 1 and p.gaze_y >= -1 and p.gaze_y <= 1);
    }
}

test "cycle geometry: every duration is a whole number of steps" {
    // The exactness the sync invariant rests on: all boundaries land on
    // step boundaries, so the sample clock and the cycle wrap together.
    try testing.expect(draw_in_ms % step_ms == 0);
    try testing.expect(peak_ms % step_ms == 0);
    try testing.expect(release_ms % step_ms == 0);
    try testing.expect(rest_ms % step_ms == 0);
    for (levels) |lvl| {
        try testing.expect(lvl.stroke_ms % step_ms == 0);
    }
    var g = Game.init(3, false);
    for (0..3) |i| {
        g.level_idx = i;
        try testing.expect(g.cycle_total_ms() % step_ms == 0);
        try testing.expect(g.release_start() % step_ms == 0);
    }
}

test "demo policy completes all three levels and books every cycle" {
    for (0..3) |lvl| {
        var g = Game.init(12345, true);
        g.start_level(lvl);
        var saw_peak = false;
        var steps: usize = 0;
        const max_steps = levels[lvl].time_limit_ms / step_ms;
        while (g.screen != .victory and steps < max_steps) : (steps += 1) {
            g.step(step_ms, 0);
            if (g.face == .peak) saw_peak = true;
        }
        try testing.expectEqual(Screen.victory, g.screen);
        try testing.expect(saw_peak);
        // The book of record: one entry per completed cycle, and the
        // session total is exactly the sum of the booked entries.
        try testing.expectEqual(@as(usize, @intCast(g.cycle_index)), g.chart_len);
        var sum: u32 = 0;
        for (g.chart[0..g.chart_len]) |e| {
            sum += e.yield_ml;
            try testing.expect(e.full); // the demo policy lands its peaks
            try testing.expectEqual(@as(u8, @intCast(levels[lvl].strokes_per_cycle)), e.hits);
        }
        try testing.expectEqual(g.total_yield_ml, sum);
        try testing.expect(g.total_yield_ml >= levels[lvl].target_ml);
    }
}

test "audio clock and cycle never drift" {
    var g = Game.init(777, true);
    g.start_level(1);
    var steps: usize = 0;
    while (g.screen == .play and steps < 20_000) : (steps += 1) {
        g.step(step_ms, 0);
        // The animation phase derived from the sample clock equals the
        // simulation's cycle position at EVERY step: tolerance zero.
        // (On the victory step itself cycle_t sits at the cycle total —
        // the wrap the clock reports as position 0 — so the invariant is
        // stated for play steps, which is where animation runs.)
        if (g.screen == .play) try testing.expectEqual(g.cycle_t, g.anim_phase_ms());
    }
    try testing.expectEqual(Screen.victory, g.screen);
}

test "preset queued mid-cycle applies at the wrap, never before" {
    var g = Game.init(9, false);
    g.start_level(0);
    g.cycle_t = g.strokes_start() + 100; // mid-strokes
    g.step(step_ms, Input.down); // queue DEEP
    try testing.expectEqual(Preset.standard, g.preset);
    try testing.expectEqual(Preset.deep, g.preset_next.?);
    // Jump to the last step of the cycle; the wrap applies the queue.
    g.cycle_t = g.cycle_total_ms() - step_ms;
    g.accounted = true; // this synthetic cycle was already booked
    g.step(step_ms, 0);
    try testing.expectEqual(Preset.deep, g.preset);
    try testing.expect(g.preset_next == null);
    try testing.expectEqual(@as(u32, 0), g.cycle_t);
}

test "determinism: same seed and inputs give identical draw lists" {
    var a = Game.init(777, true);
    var b = Game.init(777, true);
    a.start_level(1);
    b.start_level(1);
    var wa: DrawWriter = .{};
    var wb: DrawWriter = .{};
    for (0..2000) |i| {
        a.step(step_ms, 0);
        b.step(step_ms, 0);
        if (i % 100 == 0) {
            // Both renders share the one static buffer: snapshot a's bytes
            // before rendering b, or the comparison compares a to itself.
            var snapshot: [draw_buffer_bytes]u8 = undefined;
            wa.reset();
            Renderer.render(&a, &wa);
            @memcpy(snapshot[0..wa.len], draw_buffer[0..wa.len]);
            wb.reset();
            Renderer.render(&b, &wb);
            try testing.expectEqual(wa.len, wb.len);
            try testing.expectEqualSlices(u8, snapshot[0..wa.len], draw_buffer[0..wb.len]);
            try testing.expectEqual(a.total_yield_ml, b.total_yield_ml);
            try testing.expectEqual(a.audio_frame, b.audio_frame);
        }
    }
}

test "rng: identical seeds give identical streams" {
    var a = Rng.init(5);
    var b = Rng.init(5);
    for (0..100) |_| try testing.expectEqual(a.next(), b.next());
    var c = Rng.init(5);
    for (0..100) |_| {
        const u = c.unit();
        try testing.expect(u >= 0 and u < 1);
    }
}

// --- adversarial ---

test "adversarial: dt of zero and dt of billions do not break the step" {
    var g = Game.init(9, false);
    g.start_level(0);
    g.step(0, 0);
    try testing.expectEqual(CyclePhase.draw_in, g.phase());
    g.step(4_000_000_000, 0); // clamped to 250 ms internally
    try testing.expectEqual(CyclePhase.draw_in, g.phase());
    try testing.expect(g.cycle_t <= 250);
    try testing.expectEqual(g.cycle_t, g.anim_phase_ms());
    try testing.expect(g.total_yield_ml <= levels[0].target_ml + 100);
}

test "adversarial: tap spam outside the beat phases earns nothing" {
    var g = Game.init(9, false);
    g.start_level(0);
    for (0..50) |_| g.step(step_ms, Input.tap); // 800 ms: still drawing in
    try testing.expectEqual(CyclePhase.draw_in, g.phase());
    try testing.expectEqual(@as(u32, 0), g.cycle_hits);
    try testing.expectEqual(@as(u32, 0), g.total_yield_ml);
    for (g.strokes) |s| try testing.expectEqual(BeatState.pending, s);
    try testing.expectEqual(BeatState.pending, g.peak_state);
}

test "adversarial: invalid level and invalid preset are rejected at the boundary" {
    try testing.expectEqual(@as(i32, -1), init(1, 99));
    try testing.expectEqual(@as(usize, 0), game.level_idx);
    try testing.expectEqual(@as(i32, -1), start_level(200));
    // A wild preset value must not move the stored settings at all.
    apply_settings(1, 0, 0);
    try testing.expectEqual(@as(u8, 1), settings_bits());
    apply_settings(9, 0, 0);
    try testing.expectEqual(@as(u8, 1), settings_bits());
    apply_settings(2, 1, 1);
    try testing.expectEqual(@as(u8, 2 | 4 | 8), settings_bits());
}

test "adversarial: chart ledger is bounded and drops are counted" {
    var g = Game.init(9, false);
    g.start_level(0);
    for (0..(max_chart_entries + 6)) |i| {
        g.append_chart(.{
            .cycle = @intCast(i + 1),
            .preset = .standard,
            .hits = 4,
            .strokes = 4,
            .yield_ml = 55,
            .full = true,
        });
    }
    try testing.expectEqual(max_chart_entries, g.chart_len);
    try testing.expectEqual(@as(u32, 6), g.chart_dropped);
    // The kept entries are the FIRST ones: append-only, never rewritten.
    try testing.expectEqual(@as(u16, 1), g.chart[0].cycle);
    try testing.expectEqual(@as(u16, @intCast(max_chart_entries)), g.chart[max_chart_entries - 1].cycle);
}

test "adversarial: judge window edge — at the window hits, one past does not" {
    var g = Game.init(9, false);
    g.start_level(0);
    g.cycle_t = g.stroke_center(0) + preset_table[1].window_ms;
    g.judge_tap();
    try testing.expectEqual(BeatState.hit, g.strokes[0]);

    var h = Game.init(9, false);
    h.start_level(0);
    h.cycle_t = h.stroke_center(0) + preset_table[1].window_ms + 1;
    h.judge_tap();
    try testing.expectEqual(BeatState.pending, h.strokes[0]);
}

test "adversarial: pause freezes the master clock and the cycle" {
    var g = Game.init(9, false);
    g.start_level(0);
    for (0..100) |_| g.step(step_ms, 0);
    const frame_at_pause = g.audio_frame;
    const t_at_pause = g.cycle_t;
    g.step(step_ms, Input.pause_btn);
    try testing.expectEqual(Screen.pause, g.screen);
    for (0..50) |_| g.step(step_ms, 0);
    try testing.expectEqual(frame_at_pause, g.audio_frame);
    try testing.expectEqual(t_at_pause, g.cycle_t);
}

test "adversarial: draw output stays inside its bounds at peak with full flash" {
    var g = Game.init(4242, false);
    g.start_level(2);
    g.set_face_target(.peak);
    g.advance_transition(10_000);
    g.flash_left_ms = flash_ms;
    var w: DrawWriter = .{};
    Renderer.render(&g, &w);
    try testing.expect(w.ops <= max_ops);
    try testing.expect(w.len < draw_buffer_bytes);
}
