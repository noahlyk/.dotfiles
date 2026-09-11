//! micproc-jack — the dedicated mic processor node.
//!
//! Ports: `in_L`/`in_R` (input, wired standard left->left / right->right
//! from the physical mic) and TWO output lanes, each its own independent
//! chain of stages from the same `preamp`-scaled input onward (a stage can
//! opt out of one lane via `disable-output-fast`/`disable-output-good` in
//! `micproc.ron`, default false = runs on both):
//!   - `out_good_L`/`out_good_R` -- ALSO RNNoise spectral denoising, when
//!     enabled (see below), a fixed ~10ms delay when on. Feeds vmic_good
//!     (what other apps/listeners capture as the mic).
//!   - `out_fast_L`/`out_fast_R` -- sub-1ms latency (unless RNNoise is
//!     explicitly enabled on this lane too, see below). Feeds vmic_fast
//!     (self-monitoring only; summed onto speakers/headphones by pw-links,
//!     never captured by other apps).
//!
//! Stage 0 is STEREO→MONO, configured in `micproc.ron` as the first stage
//! of whichever mode is active (`type = "stereo2mono"`): it owns the input
//! fold (`mode` picks peak / average / left / right) and the duplication of
//! the mono result onto both outputs, so a mono mic wired standard L->L /
//! R->R stays at unit level. Disabled (`enabled = false`) it becomes plain
//! stereo passthrough. The rest of the stages are the scalar strip.
//!
//! The chain is defined in `micproc.ron` and hot-reloaded via an inotify
//! watch on its directory (`notify`, debounced ~50ms) -- purely event-driven,
//! no polling loop, no idle CPU between edits. Swap is lock-free (`arc-swap`)
//! so the realtime thread never locks.
//!
//! `micproc.ron` holds any number of named `[modes.<name>]` tables, each its
//! own complete `stages` list (e.g. `vocals`, `instrumental`, `raw`); exactly
//! one is live at a time, picked by the top-level `active-mode` key. Since
//! this is hot-reloaded, switching modes is just editing `active-mode` and
//! saving -- live within ~50ms, no restart. There's nothing special about
//! any mode name, "raw"/bypass included -- a mode with an empty or
//! all-`enabled = false` `stages` list IS the bypass, same mechanism as
//! every other mode. Built-ins usable in any mode's `stages` list:
//!   - expander   kills low-level background noise (downward expansion,
//!                floored at `range-db` so it's a gentle noise-reducer,
//!                not a mute hole)
//!   - compressor brings the level up to the "correct area" and glues the
//!                signal (soft knee + makeup, both optional)
//!   - gate       a SMART SOFT gate: hysteresis (no chatter around one
//!                threshold), a hold window (no syllable-head/tail chopping),
//!                a steep but *floored* downward expansion (soft, never
//!                muting). Keys on an earlier stage (`detector`, default
//!                "expander") so compressor makeup gain can't push residual
//!                noise back past the threshold — no feedback loop.
//!   - eq         final tone shaping (parametric biquads).
//!   - rnnoise    spectral denoiser -- `out_good_*` lane only, see above.

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use arc_swap::ArcSwap;
use jack::{AudioIn, AudioOut, Client, ClientOptions, Port, ProcessHandler, ProcessScope};
use nnnoiseless::DenoiseState;
use notify::{RecursiveMode, Watcher};
use serde::Deserialize;

static RATE: AtomicU32 = AtomicU32::new(96000);
static VERSION: AtomicU64 = AtomicU64::new(0);

const DEFAULT_CONF: &str = "micproc.ron";

// ────────────────────────────────────────────────────────────────────────────
// CONFIG — RON, not TOML: field names are used as-is (snake_case, matching
// the Rust structs below 1:1 -- no `rename_all` needed anywhere except
// `type`, a reserved word). `Option<T>` fields are written bare (`foo: 1.0`,
// not `foo: Some(1.0)`) via the `IMPLICIT_SOME` extension enabled in
// `ron_options()` below, so optional per-stage knobs stay as terse as they
// were in the old TOML.
// ────────────────────────────────────────────────────────────────────────────

/// Parser used for every `micproc.ron` read -- the one place `IMPLICIT_SOME`
/// is turned on.
fn ron_options() -> ron::Options {
    ron::Options::default().with_default_extension(ron::extensions::Extensions::IMPLICIT_SOME)
}

#[derive(Debug, Clone, Default, Deserialize)]
struct MicProcConf {
    #[serde(default)]
    preamp_db: f32,
    /// Which `[modes.*]` table is live. Hot-reloaded like everything else --
    /// edit this and save to switch modes within ~50ms.
    active_mode: String,
    /// Every named mode, keyed by the name used in `[modes.<name>]` and
    /// referenced by `active-mode`. Each is a complete, independent stage
    /// list -- there's no inheritance/merging between modes, by design (a
    /// mode is a whole chain, not a diff).
    #[serde(default)]
    modes: std::collections::HashMap<String, ModeConf>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ModeConf {
    /// This mode's whole chain, in order: array order = the order the
    /// stages run. Omit a stage to drop it; `enabled = false` bypasses it in
    /// place without removing it. An empty (or all-disabled) list is a
    /// complete bypass -- that's not a separate flag, just a mode like any
    /// other.
    #[serde(default)]
    stages: Vec<StageConf>,
}

/// The active mode's stage list, or `&[]` (a silent bypass, not a crash) if
/// `active-mode` names a mode that isn't in `modes` -- e.g. mid-edit, or a
/// typo. Mirrors `load_config_at`'s existing "bad config -> empty chain"
/// fallback philosophy rather than refusing to run.
fn active_stages(conf: &MicProcConf) -> &[StageConf] {
    match conf.modes.get(&conf.active_mode) {
        Some(m) => &m.stages,
        None => {
            eprintln!(
                "[micproc] active-mode \"{}\" not found in [modes.*] (have: {:?}); running empty chain",
                conf.active_mode,
                conf.modes.keys().collect::<Vec<_>>()
            );
            &[]
        }
    }
}

/// `type = "rnnoise"` in a mode's `stages` list, same `enabled`/
/// `disable-output-fast`/`disable-output-good` fields as any other stage.
/// Not a per-sample `Stage` though -- it's `nnnoiseless`, a frame-based
/// spectral denoiser with a fixed ~10ms latency, applied after the rest of
/// the chain runs (`MicDsp::process`), independently per lane.
fn rnnoise_lanes(stages: &[StageConf]) -> (bool, bool) {
    let Some(s) = stages.iter().find(|s| s.ty == "rnnoise" && s.enabled) else { return (false, false) };
    (!s.disable_output_fast, !s.disable_output_good)
}

/// One stage. Only the keys relevant to `type` are read; the rest of the list
/// exists so each stage's settings live right next to its `type` line.
#[derive(Debug, Clone, Deserialize)]
struct StageConf {
    #[serde(rename = "type")]
    ty: String,
    #[serde(default = "default_true")]
    enabled: bool,
    threshold_db: Option<f32>,
    ratio: Option<f32>,
    knee_db: Option<f32>,
    attack_ms: Option<f32>,
    release_ms: Option<f32>,
    /// Level-detector smoothing, separate from `attack-ms`/`release-ms`
    /// (which smooth the resulting GAIN, not the level driving it). Without
    /// this the threshold comparison reacts to one raw sample at a time,
    /// which on a fast attack can track individual cycles of a low-pitched
    /// voice, audible as a gritty/buzzy modulation. Defaults to 3ms if
    /// unset -- raise it if a stage still sounds grainy, lower it if it
    /// feels sluggish to real level changes.
    detector_ms: Option<f32>,
    range_db: Option<f32>,
    makeup_db: Option<f32>,
    hysteresis_db: Option<f32>,
    hold_ms: Option<f32>,
    /// Gate sidechain: `"input"` keys on the gate's own input, anything else
    /// names an earlier stage `type` to key on (`"expander"` keeps the
    /// compressor's makeup gain out of the key signal).
    detector: Option<String>,
    /// Skip this stage on the out_fast_* lane only (default false = runs on
    /// both lanes, same as today). The two lanes fork into fully
    /// independent chains from the preamp onward, so a stage disabled on
    /// one lane doesn't affect the other's sidechain/gate-detector state.
    #[serde(default)]
    disable_output_fast: bool,
    /// Skip this stage on the out_good_* lane only (default false).
    #[serde(default)]
    disable_output_good: bool,
    /// `stereo2mono` fold mode: `"peak"` | `"average"` | `"left"` | `"right"`.
    mode: Option<String>,
    /// `eq` output trim.
    preamp_db: Option<f32>,
    /// `eq` band list (LS/PK/HS).
    band: Option<Vec<EqBand>>,
}

#[derive(Debug, Clone, Deserialize)]
struct EqBand {
    #[serde(rename = "type")]
    ty: String,
    freq: f32,
    gain_db: f32,
    #[serde(default = "default_q")]
    q: f32,
}

fn default_true() -> bool {
    true
}

fn default_q() -> f32 {
    0.7071
}

// ────────────────────────────────────────────────────────────────────────────
// EQ (shared biquad, ported from spa/plugins/audioconvert/biquad.c so the
// sound matches PipeWire's own filter-chain EQ)
// ────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
enum BiquadType {
    LowShelf,
    HighShelf,
    Peaking,
}

impl BiquadType {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "LS" | "LSC" => Some(BiquadType::LowShelf),
            "HS" | "HSC" => Some(BiquadType::HighShelf),
            "PK" => Some(BiquadType::Peaking),
            _ => None,
        }
    }
}

#[derive(Clone, Copy)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Biquad {
    fn identity() -> Self {
        Biquad { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0, x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0 }
    }

    fn set(&mut self, ty: BiquadType, fc: f32, q: f32, gain_db: f32, rate: u32) {
        let freq = fc * 2.0 / rate as f32;
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = std::f32::consts::PI * freq;
        let alpha = w0.sin() / (2.0 * q).max(1e-6);
        let k = w0.cos();
        let k2 = 2.0 * a.sqrt() * alpha;
        let ap = a + 1.0;
        let am = a - 1.0;

        let (b0, b1, b2, a1, a2): (f32, f32, f32, f32, f32) = match ty {
            BiquadType::Peaking => (1.0 + alpha * a, -2.0 * k, 1.0 - alpha * a, -2.0 * k, 1.0 - alpha / a),
            BiquadType::LowShelf => (
                a * (ap - am * k + k2),
                2.0 * a * (am - ap * k),
                a * (ap - am * k - k2),
                -2.0 * (am + ap * k),
                ap + am * k - k2,
            ),
            BiquadType::HighShelf => (
                a * (ap + am * k + k2),
                -2.0 * a * (am + ap * k),
                a * (ap + am * k - k2),
                2.0 * (am - ap * k),
                ap - am * k - k2,
            ),
        };

        let a0 = match ty {
            BiquadType::Peaking => 1.0 + alpha / a,
            BiquadType::LowShelf => ap + am * k + k2,
            BiquadType::HighShelf => ap - am * k + k2,
        };

        let a0i = 1.0 / a0;
        self.b0 = b0 * a0i;
        self.b1 = b1 * a0i;
        self.b2 = b2 * a0i;
        self.a1 = a1 * a0i;
        self.a2 = a2 * a0i;
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }

    #[inline]
    fn run(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

// ────────────────────────────────────────────────────────────────────────────
// DYNAMICS
// ────────────────────────────────────────────────────────────────────────────

// dB <-> linear gain via IEEE-754 bit tricks + a degree-5 polynomial fit,
// used in place of libm log10()/powf() on every sample: powf(10.0, x) in
// particular has no fast path for a constant base and re-derives ln(10) on
// every call. Error bounds (measured over the practically relevant range,
// mag 1e-6..=2.0 / dB -140..=20) are ~0.0002 dB for fast_log2 and ~2e-6 dB
// for fast_exp2 -- both far below anything audible; see the accuracy test
// in `tests` below.
const LOG2_TO_DB: f32 = 20.0 / std::f32::consts::LOG2_10;
const DB_TO_LOG2: f32 = std::f32::consts::LOG2_10 / 20.0;

/// log2(x) for x > 0: exponent via bit-cast, degree-5 polynomial fit of
/// log2(1+t) on t in [0,1) for the mantissa.
#[inline]
fn fast_log2(x: f32) -> f32 {
    let bits = x.to_bits();
    let exponent = ((bits >> 23) as i32 & 0xFF) - 127;
    let mantissa_bits = (bits & 0x007F_FFFF) | (127 << 23);
    let t = f32::from_bits(mantissa_bits) - 1.0; // in [0, 1)
    let m = 3.190_813_1e-5
        + t * (1.441_267_4
            + t * (-0.705_704_15 + t * (0.408_721_74 + t * (-0.187_722_64 + t * 0.043_428_91))));
    exponent as f32 + m
}

/// 2^x: integer/fraction split via `floor`, degree-5 polynomial fit of 2^t
/// on t in [0,1) for the fractional part, integer part folded straight into
/// the IEEE-754 exponent bits (no libm call at all).
#[inline]
fn fast_exp2(x: f32) -> f32 {
    let xf = x.floor();
    let t = x - xf; // in [0, 1)
    let poly = 0.999_999_77
        + t * (0.693_156_78
            + t * (0.240_131_69 + t * (0.055_876_56 + t * (0.008_940_58 + t * 0.001_894_38))));
    let exponent = (xf as i32 + 127).clamp(0, 255) as u32;
    poly * f32::from_bits(exponent << 23)
}

#[inline]
fn db(x: f32) -> f32 {
    LOG2_TO_DB * fast_log2(x.abs() + 1e-8)
}

/// dB -> linear gain, the inverse of `db` -- what every stage used to spell
/// as `10f32.powf(db / 20.0)`.
#[inline]
fn from_db(db: f32) -> f32 {
    fast_exp2(db * DB_TO_LOG2)
}

fn one_pole(ms: f32, rate: u32) -> f32 {
    let tau = ms.max(0.1) / 1000.0 * rate as f32;
    1.0 - (-1.0 / tau).exp()
}

#[derive(Clone, Copy)]
enum DynMode {
    Expander,
    Compressor,
}

/// Smooth-gain dynamics with a cosine soft knee (expander + compressor).
#[derive(Clone, Copy)]
struct Dynamics {
    mode: DynMode,
    enabled: bool,
    threshold_db: f32,
    ratio: f32,
    knee_db: f32,
    floor_db: f32,
    attack: f32,
    release: f32,
    makeup_gain: f32,
    cur_db: f32,
    /// Level-detector smoothing coefficient (see `StageConf::detector_ms`) --
    /// separate from `attack`/`release`, which smooth the resulting gain,
    /// not the level that drives the threshold comparison.
    detector: f32,
    detected_db: f32,
}

impl Dynamics {
    fn new(mode: DynMode) -> Self {
        Dynamics {
            mode,
            enabled: true,
            threshold_db: -60.0,
            ratio: 2.0,
            knee_db: 6.0,
            floor_db: -24.0,
            attack: 0.0,
            release: 0.0,
            makeup_gain: 1.0,
            cur_db: 0.0,
            detector: 1.0,
            detected_db: -120.0,
        }
    }

    #[inline]
    fn run(&mut self, x: f32, key_db: f32) -> f32 {
        if !self.enabled {
            return x * self.makeup_gain;
        }

        // Smooth the LEVEL before comparing it to the threshold -- a raw
        // instantaneous per-sample value jitters at the input's own
        // waveform rate, which a fast attack barely averages out (on a low
        // voice, not even one pitch period), audible as grit/buzz riding
        // the gain. This is a separate, short, fixed-ish time constant from
        // the attack/release smoothing applied to the gain below.
        self.detected_db += (key_db - self.detected_db) * self.detector;
        let key_db = self.detected_db;

        let g = match self.mode {
            // Expander: attenuate below threshold, floored (gentle noise reducer).
            DynMode::Expander => {
                let e = self.threshold_db - key_db; // > 0 below threshold
                let k = self.knee_db;
                let full = e * (1.0 - self.ratio); // <= 0
                let raw = if e <= -k / 2.0 {
                    0.0
                } else if e >= k / 2.0 {
                    full
                } else {
                    let w = 0.5 * (1.0 - (std::f32::consts::PI * (e + k / 2.0) / k).cos());
                    w * full
                };
                raw.max(self.floor_db)
            }
            // Compressor: attenuate above threshold. gain = L_out - L_in
            // where L_out = threshold + d/ratio, i.e. gain = d*(1/ratio - 1)
            // = -d*(1 - 1/ratio). The missing negation here previously made
            // this compute a BOOST (e.g. +15 dB for 20 dB over threshold at
            // a 4:1 ratio) instead of a cut -- confirmed unchanged since the
            // very first commit that added this file.
            DynMode::Compressor => {
                let d = key_db - self.threshold_db; // > 0 above threshold
                let k = self.knee_db;
                let full = -d * (1.0 - 1.0 / self.ratio); // <= 0
                if d <= -k / 2.0 {
                    0.0
                } else if d >= k / 2.0 {
                    full
                } else {
                    let w = 0.5 * (1.0 - (std::f32::consts::PI * (d + k / 2.0) / k).cos());
                    w * full
                }
            }
        };

        // Smooth toward `g`. The two modes have OPPOSITE polarity here:
        //   Expander: dropping gain = engaging (signal went quiet) -- the
        //     SLOW phase (release), so a word's tail isn't chopped; rising
        //     = opening (signal returned) -- the FAST phase (attack), so a
        //     word's onset isn't clipped. Gate-like semantics.
        //   Compressor: dropping gain = engaging (signal got LOUD) -- needs
        //     to be FAST (attack) to catch the transient; rising =
        //     recovering afterward -- the SLOW phase (release), to avoid
        //     pumping.
        // Previously both modes used the expander's mapping unconditionally,
        // which left the compressor's attack/release effectively swapped
        // (clamped down slowly, let go quickly -- backwards).
        let coeff = match self.mode {
            DynMode::Expander => {
                if g < self.cur_db {
                    self.release
                } else {
                    self.attack
                }
            }
            DynMode::Compressor => {
                if g < self.cur_db {
                    self.attack
                } else {
                    self.release
                }
            }
        };
        self.cur_db += (g - self.cur_db) * coeff;

        x * from_db(self.cur_db) * self.makeup_gain
    }
}

/// The smart soft gate: hysteresis + hold + floored steep expansion, keyed on
/// a sidechain so a later gain boost can't re-open it.
#[derive(Clone, Copy)]
struct Gate {
    enabled: bool,
    open_db: f32,
    close_db: f32,
    ratio: f32,
    knee_db: f32,
    floor_db: f32,
    hold_frames: u32,
    attack: f32,
    release: f32,
    was_open: bool,
    held: u32,
    cur_db: f32,
    /// Level-detector smoothing coefficient (see `StageConf::detector_ms`),
    /// separate from `attack`/`release` (which smooth the gain, not the
    /// level driving the open/close decision).
    detector: f32,
    detected_db: f32,
}

impl Gate {
    fn new() -> Self {
        Gate {
            enabled: true,
            open_db: -50.0,
            close_db: -56.0,
            ratio: 8.0,
            knee_db: 6.0,
            floor_db: -30.0,
            hold_frames: 0,
            attack: 0.0,
            release: 0.0,
            was_open: false,
            held: 0,
            cur_db: 0.0,
            detector: 1.0,
            detected_db: -120.0,
        }
    }

    #[inline]
    fn run(&mut self, x: f32, key_db: f32) -> f32 {
        if !self.enabled {
            return x;
        }

        // Smooth the level before the open/close decision -- a raw
        // instantaneous sample can spike across `open_db`/`close_db` for a
        // single sample, which hysteresis+hold already guard against
        // somewhat, but smoothing the level itself (same rationale as
        // `Dynamics::run`) avoids feeding that jitter in in the first place.
        self.detected_db += (key_db - self.detected_db) * self.detector;
        let key_db = self.detected_db;

        // Hysteresis: crossing OPEN opens; the level must fall below CLOSE to
        // start the close sequence.
        if key_db >= self.open_db {
            self.was_open = true;
            self.held = 0;
        } else if self.was_open {
            self.held += 1;
            if self.held >= self.hold_frames {
                self.was_open = false;
            }
        }

        let target = if self.was_open {
            0.0
        } else {
            // Soft downward expansion below close_db, floored — a gate that
            // attenuates smoothly instead of an on/off switch.
            let e = self.close_db - key_db;
            let k = self.knee_db;
            let full = e * (1.0 - self.ratio);
            let raw = if e <= -k / 2.0 {
                0.0
            } else if e >= k / 2.0 {
                full
            } else {
                let w = 0.5 * (1.0 - (std::f32::consts::PI * (e + k / 2.0) / k).cos());
                w * full
            };
            raw.max(self.floor_db)
        };

        let coeff = if target < self.cur_db { self.release } else { self.attack };
        self.cur_db += (target - self.cur_db) * coeff;

        x * from_db(self.cur_db)
    }
}

// ────────────────────────────────────────────────────────────────────────────
// DENOISER (RNNoise, quality lane only)
// ────────────────────────────────────────────────────────────────────────────

/// `nnnoiseless::DenoiseState::FRAME_SIZE` (480 samples = 10ms @ 48kHz) --
/// RNNoise's model operates on fixed-size frames, unlike every other stage
/// in this chain which is a pure per-sample recurrence. This is the one
/// place in the codebase that has to bridge that mismatch.
const RNN_FRAME: usize = nnnoiseless::DenoiseState::FRAME_SIZE;
/// RNNoise's model was trained on 16-bit PCM and expects/produces samples in
/// `[-32768.0, 32767.0]`, not the `[-1.0, 1.0]` range the rest of this chain
/// uses -- scale in going in, back out coming back.
const RNN_SCALE: f32 = 32768.0;

/// Bridges the per-sample RT callback to RNNoise's fixed-480-sample-frame
/// API with a fixed ~10ms FIFO delay, no reallocation on the RT thread after
/// startup (both buffers are fixed-size arrays reused every frame).
///
/// `push` is called once per sample: it always returns the OLDEST buffered
/// output sample first (if any), then feeds `x` into the next input frame,
/// running RNNoise exactly when a frame fills. After the first `RNN_FRAME`
/// warm-up samples (silence -- `None`, caller should emit 0.0) it returns
/// `Some` every call, forever, at a steady fixed ~10ms pipeline delay.
struct Denoiser {
    state: Box<DenoiseState<'static>>,
    in_buf: [f32; RNN_FRAME],
    in_len: usize,
    out_buf: [f32; RNN_FRAME],
    scratch: [f32; RNN_FRAME],
    out_pos: usize,
}

impl Denoiser {
    fn new() -> Self {
        Denoiser {
            state: DenoiseState::new(),
            in_buf: [0.0; RNN_FRAME],
            in_len: 0,
            out_buf: [0.0; RNN_FRAME],
            scratch: [0.0; RNN_FRAME],
            out_pos: RNN_FRAME, // "empty" -- forces None until the first frame completes
        }
    }

    #[inline]
    fn push(&mut self, x: f32) -> Option<f32> {
        let emit = if self.out_pos < RNN_FRAME {
            let v = self.out_buf[self.out_pos];
            self.out_pos += 1;
            Some(v)
        } else {
            None
        };

        self.in_buf[self.in_len] = x * RNN_SCALE;
        self.in_len += 1;
        if self.in_len == RNN_FRAME {
            self.state.process_frame(&mut self.scratch, &self.in_buf);
            for (o, s) in self.out_buf.iter_mut().zip(self.scratch.iter()) {
                *o = *s / RNN_SCALE;
            }
            self.in_len = 0;
            self.out_pos = 0;
        }
        emit
    }
}

// ────────────────────────────────────────────────────────────────────────────
// CHAIN
// ────────────────────────────────────────────────────────────────────────────

/// How stage 0 (stereo→mono) folds the two-channel input down to one mono
/// lane before the mono result is duplicated onto both outputs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FoldMode {
    /// Per-sample the louder of L/R — keeps a mono source riding one input
    /// at unit level even when the other input is empty.
    Peak,
    /// Standard `0.5 * (L + R)` downmix.
    Average,
    /// Left channel only.
    Left,
    /// Right channel only.
    Right,
}

impl FoldMode {
    fn parse(s: Option<&str>) -> FoldMode {
        match s {
            Some("average" | "mid") => FoldMode::Average,
            Some("left") => FoldMode::Left,
            Some("right") => FoldMode::Right,
            _ => FoldMode::Peak,
        }
    }
}

/// Stage 0 — the stereo→mono boundary conversion. Runs at the frame edge,
/// not inside the per-sample chain. Disabled = plain stereo passthrough.
#[derive(Debug, Clone, Copy)]
struct Stereo2Mono {
    enabled: bool,
    fold: FoldMode,
}

impl Default for Stereo2Mono {
    fn default() -> Self {
        Stereo2Mono { enabled: true, fold: FoldMode::Peak }
    }
}

/// One configured processing stage, in `order`.
#[derive(Clone)]
enum Stage {
    Expander(Dynamics),
    Compressor(Dynamics),
    Gate(Gate),
    Eq { bqs: Vec<Biquad>, preamp: f32 },
}

impl Stage {
    /// Kind name for logging (e.g. the per-lane stage list announced on
    /// reload) -- not used for any dispatch, `step`/`match` do that directly.
    fn name(&self) -> &'static str {
        match self {
            Stage::Expander(_) => "expander",
            Stage::Compressor(_) => "compressor",
            Stage::Gate(_) => "gate",
            Stage::Eq { .. } => "eq",
        }
    }

    /// `key` is the sidechain level detector input (only the gate uses it).
    #[inline]
    fn step(&mut self, x: f32, key_db: f32) -> f32 {
        match self {
            Stage::Expander(d) => d.run(x, key_db),
            Stage::Compressor(d) => d.run(x, key_db),
            Stage::Gate(g) => g.run(x, key_db),
            Stage::Eq { bqs, preamp } => {
                bqs.iter_mut().fold(x * *preamp, |y, bq| bq.run(y))
            }
        }
    }
}

/// A fully-built chain, produced OFF the JACK realtime thread by
/// `build_snapshot` (called from the background config reloader, and once
/// at startup before the client is activated). Published to the RT thread
/// via a lock-free `ArcSwap<DspSnapshot>`; `MicDsp::adopt` only clones the
/// (small) `stages` Vec out of it, so none of the parsing / string matching
/// / biquad trig / logging in `build_snapshot` ever runs on the audio
/// thread, even at the moment `micproc.ron` is hot-reloaded.
/// A fully-built per-lane chain: independent stage state and gate-detector
/// indexing, since a stage disabled on one lane (see `disable-output-fast`/
/// `disable-output-good`) means the two lanes' stage LISTS -- and therefore
/// their sidechain indices -- can genuinely differ, not just their signal.
#[derive(Clone)]
struct LaneChain {
    stages: Vec<Stage>,
    /// Detector stage index for gate sidechaining (index of the stage whose
    /// POST output the gate keys on). `None` = gate keys on its own input.
    gate_det_idx: Option<usize>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Lane {
    Fast,
    Good,
}

/// A fully-built chain, produced OFF the JACK realtime thread by
/// `build_snapshot` (called from the background config reloader, and once
/// at startup before the client is activated). Published to the RT thread
/// via a lock-free `ArcSwap<DspSnapshot>`; `MicDsp::adopt` only clones the
/// (small) `stages` Vecs out of it, so none of the parsing / string matching
/// / biquad trig / logging in `build_snapshot` ever runs on the audio
/// thread, even at the moment `micproc.ron` is hot-reloaded.
struct DspSnapshot {
    version: u64,
    preamp: f32,
    stereo2mono: Stereo2Mono,
    fast: LaneChain,
    good: LaneChain,
    rnnoise_fast: bool,
    rnnoise_good: bool,
}

/// Build ONE lane's stage list + resolved gate-detector index, skipping any
/// stage whose `disable-output-fast`/`disable-output-good` flag excludes it
/// from `lane`. `log` gates the "unknown stage type" diagnostic so it's only
/// printed once across both lane builds, not duplicated.
fn build_lane(stages_conf: &[StageConf], rate: u32, lane: Lane, log: bool) -> LaneChain {
    let mut stages: Vec<Stage> = Vec::new();
    let mut kinds: Vec<&str> = Vec::new();
    let mut gate_det: Vec<Option<String>> = Vec::new();

    for sc in stages_conf {
        if sc.ty.as_str() == "stereo2mono" || sc.ty.as_str() == "rnnoise" {
            continue; // handled separately -- not a per-sample Stage
        }
        if !sc.enabled {
            continue;
        }
        let skip = match lane {
            Lane::Fast => sc.disable_output_fast,
            Lane::Good => sc.disable_output_good,
        };
        if skip {
            continue;
        }
        let pushed = match sc.ty.as_str() {
            "expander" => {
                let mut s = Dynamics::new(DynMode::Expander);
                s.enabled = true;
                s.threshold_db = sc.threshold_db.unwrap_or(-60.0);
                s.ratio = sc.ratio.unwrap_or(2.0);
                s.knee_db = sc.knee_db.unwrap_or(6.0);
                s.floor_db = sc.range_db.unwrap_or(-24.0);
                s.attack = one_pole(sc.attack_ms.unwrap_or(1.0), rate);
                s.release = one_pole(sc.release_ms.unwrap_or(80.0), rate);
                s.detector = one_pole(sc.detector_ms.unwrap_or(3.0), rate);
                s.makeup_gain = 1.0;
                stages.push(Stage::Expander(s));
                true
            }
            "compressor" => {
                let mut s = Dynamics::new(DynMode::Compressor);
                s.enabled = true;
                s.threshold_db = sc.threshold_db.unwrap_or(-20.0);
                s.ratio = sc.ratio.unwrap_or(3.0);
                s.knee_db = sc.knee_db.unwrap_or(6.0);
                s.floor_db = 0.0; // compressors don't gate below
                s.attack = one_pole(sc.attack_ms.unwrap_or(2.0), rate);
                s.release = one_pole(sc.release_ms.unwrap_or(120.0), rate);
                s.detector = one_pole(sc.detector_ms.unwrap_or(3.0), rate);
                s.makeup_gain = 10f32.powf(sc.makeup_db.unwrap_or(0.0) / 20.0);
                stages.push(Stage::Compressor(s));
                true
            }
            "gate" => {
                let mut s = Gate::new();
                s.enabled = true;
                s.open_db = sc.threshold_db.unwrap_or(-50.0);
                s.close_db = s.open_db - sc.hysteresis_db.unwrap_or(6.0);
                s.ratio = sc.ratio.unwrap_or(8.0);
                s.knee_db = sc.knee_db.unwrap_or(6.0);
                s.floor_db = sc.range_db.unwrap_or(-30.0);
                s.hold_frames = (sc.hold_ms.unwrap_or(80.0) / 1000.0 * rate as f32) as u32;
                s.attack = one_pole(sc.attack_ms.unwrap_or(3.0), rate);
                s.release = one_pole(sc.release_ms.unwrap_or(220.0), rate);
                s.detector = one_pole(sc.detector_ms.unwrap_or(3.0), rate);
                stages.push(Stage::Gate(s));
                true
            }
            "eq" => {
                let bqs = sc
                    .band
                    .clone()
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|b| {
                        let ty = BiquadType::parse(&b.ty)?;
                        let mut bq = Biquad::identity();
                        bq.set(ty, b.freq, b.q.max(0.01), b.gain_db, rate);
                        Some(bq)
                    })
                    .collect::<Vec<_>>();
                let preamp = 10f32.powf(sc.preamp_db.unwrap_or(0.0) / 20.0);
                stages.push(Stage::Eq { bqs, preamp });
                true
            }
            other => {
                if log {
                    eprintln!("[micproc] unknown stage type in stages: {other:?}");
                }
                false
            }
        };
        if pushed {
            kinds.push(sc.ty.as_str());
            gate_det.push(sc.detector.clone());
        }
    }

    // Resolve the gate's sidechain detector: it must be a stage type that
    // runs BEFORE the gate, WITHIN THIS LANE's own (possibly-filtered)
    // stage list. Default "expander" keys on the (typically) pre-compressor
    // stage, keeping compressor makeup gain out of the key.
    let mut gate_det_idx = None;
    for (i, kind) in kinds.iter().enumerate() {
        if *kind != "gate" {
            continue;
        }
        let det = gate_det[i].clone().unwrap_or_else(|| "expander".into());
        match det.as_str() {
            "input" => gate_det_idx = None,
            det => match kinds[..i].iter().rposition(|k| k == &det) {
                Some(j) => gate_det_idx = Some(j),
                None => {
                    if log {
                        eprintln!(
                            "[micproc] gate detector \"{det}\" not found before the gate; keying on gate input"
                        );
                    }
                    gate_det_idx = None;
                }
            },
        }
        break;
    }

    LaneChain { stages, gate_det_idx }
}

/// Build a full DSP chain from config: parsing, string matching over stage
/// types, biquad coefficient trig (`sin`/`cos`/`powf`), and the announce
/// `eprintln!` all happen here. Called only off the realtime thread.
fn build_snapshot(conf: &MicProcConf, rate: u32, version: u64) -> DspSnapshot {
    let stages = active_stages(conf);
    let preamp = 10f32.powf(conf.preamp_db / 20.0);
    let mut stereo2mono = Stereo2Mono::default();
    for sc in stages {
        if sc.ty.as_str() == "stereo2mono" {
            // Stage 0 — the stereo→mono boundary conversion. Not a
            // per-sample stage: it's the input fold + output duplication
            // applied at the frame edge (see the process handler). Shared by
            // both lanes -- it runs before they fork.
            stereo2mono.enabled = sc.enabled;
            stereo2mono.fold = FoldMode::parse(sc.mode.as_deref());
            break;
        }
    }

    let fast = build_lane(stages, rate, Lane::Fast, true);
    let good = build_lane(stages, rate, Lane::Good, false);
    let (rnnoise_fast, rnnoise_good) = rnnoise_lanes(stages);

    eprintln!(
        "[micproc] chain v{version} @ {rate} Hz: mode \"{}\", preamp {:.1} dB, stereo->mono {} ({stereo2mono:?}), fast-stages {:?}, good-stages {:?}, rnnoise fast={} good={}",
        conf.active_mode,
        conf.preamp_db,
        if stages.iter().any(|s| s.ty == "stereo2mono") { "configured" } else { "default" },
        fast.stages.iter().map(Stage::name).collect::<Vec<_>>(),
        good.stages.iter().map(Stage::name).collect::<Vec<_>>(),
        rnnoise_fast,
        rnnoise_good,
    );

    DspSnapshot { version, preamp, stereo2mono, fast, good, rnnoise_fast, rnnoise_good }
}

/// RT-thread-owned per-lane state: the (cloned) stage list plus each
/// stage's previous-cycle output (sidechain taps), mirroring `LaneChain`.
struct LaneDsp {
    stages: Vec<Stage>,
    gate_det_idx: Option<usize>,
    stage_out: Vec<f32>,
}

impl LaneDsp {
    fn new() -> Self {
        LaneDsp { stages: Vec::new(), gate_det_idx: None, stage_out: Vec::new() }
    }

    fn adopt(&mut self, chain: &LaneChain) {
        self.stages = chain.stages.clone();
        self.gate_det_idx = chain.gate_det_idx;
        self.stage_out = vec![0.0; self.stages.len()];
    }

    /// Run one sample through this lane's own stage list. Only
    /// Expander/Compressor (keyed on their own input) and Gate (keyed on a
    /// sidechain tap) read `key`; Eq ignores it entirely, so skip the log2
    /// call for that stage rather than throwing the result away.
    #[inline]
    fn run(&mut self, mut x: f32) -> f32 {
        for (i, stage) in self.stages.iter_mut().enumerate() {
            let key = match stage {
                Stage::Gate(_) => {
                    // Soft-gate sidechain: key on a stage BEFORE the
                    // compressor (by default the expander's output), so
                    // makeup gain can't lift residual noise back over the
                    // threshold. Indexes into THIS lane's own stage_out --
                    // the two lanes' stage lists (and therefore indices)
                    // can differ when `disable-output-fast`/`-good` is used.
                    match self.gate_det_idx {
                        Some(d) => db(self.stage_out[d]),
                        None => db(x),
                    }
                }
                Stage::Eq { .. } => 0.0,
                _ => db(x),
            };
            x = stage.step(x, key);
            self.stage_out[i] = x;
        }
        x
    }
}

/// All per-block DSP state for the mono strip -- RT-thread-owned. The two
/// output lanes are fully independent chains from `preamp` onward (see
/// `LaneDsp`), each built from `micproc.ron`'s SAME mode's stage list, just
/// with any stage marked `disable-output-fast`/`disable-output-good`
/// dropped from that lane's own copy.
struct MicDsp {
    version: u64,
    preamp: f32,
    stereo2mono: Stereo2Mono,
    fast: LaneDsp,
    good: LaneDsp,
    denoiser_fast: Denoiser,
    denoiser_good: Denoiser,
    rnnoise_fast: bool,
    rnnoise_good: bool,
}

impl MicDsp {
    fn new() -> Self {
        MicDsp {
            version: u64::MAX,
            preamp: 1.0,
            stereo2mono: Stereo2Mono::default(),
            fast: LaneDsp::new(),
            good: LaneDsp::new(),
            denoiser_fast: Denoiser::new(),
            denoiser_good: Denoiser::new(),
            rnnoise_fast: false,
            rnnoise_good: false,
        }
    }

    /// Adopt a freshly-built snapshot into this RT-thread-owned state. Only
    /// clones the small prebuilt `Vec<Stage>`s and copies scalar fields --
    /// all the expensive work already happened in `build_snapshot`, off the
    /// realtime thread. Safe to call from `process()`.
    #[inline]
    fn adopt(&mut self, snap: &DspSnapshot) {
        self.preamp = snap.preamp;
        self.stereo2mono = snap.stereo2mono;
        self.fast.adopt(&snap.fast);
        self.good.adopt(&snap.good);
        self.rnnoise_fast = snap.rnnoise_fast;
        self.rnnoise_good = snap.rnnoise_good;
        self.version = snap.version;
    }

    #[inline]
    fn process(&mut self, x: f32) -> (f32, f32) {
        let x = x * self.preamp;
        let fast_pre = self.fast.run(x);
        let fast = if self.rnnoise_fast { self.denoiser_fast.push(fast_pre).unwrap_or(0.0) } else { fast_pre };
        let good_pre = self.good.run(x);
        let good = if self.rnnoise_good { self.denoiser_good.push(good_pre).unwrap_or(0.0) } else { good_pre };
        (fast, good)
    }
}

// ────────────────────────────────────────────────────────────────────────────
// CONFIG LOAD / RELOAD
// ────────────────────────────────────────────────────────────────────────────

fn config_path() -> PathBuf {
    let dir = env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(env::var("HOME").expect("HOME unset")).join(".config"))
        .join("pipewire");
    env::var("MICPROC_CONF").map(PathBuf::from).unwrap_or_else(|_| dir.join(DEFAULT_CONF))
}

/// Load + parse the config at a specific path (bumping `VERSION`). Split out
/// from `load_config` so the reloader can be driven by an explicit path --
/// no implicit dependency on `config_path()`/env vars, which makes it
/// trivially testable with a temp file instead of the real on-disk config.
fn load_config_at(path: &std::path::Path) -> MicProcConf {
    VERSION.fetch_add(1, Ordering::Relaxed);
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("[micproc] cannot read {}: {e}; running empty chain", path.display());
            return MicProcConf::default();
        }
    };
    match ron_options().from_str::<MicProcConf>(&text) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[micproc] bad config {}: {e}; running empty chain", path.display());
            MicProcConf::default()
        }
    }
}

/// Only used by the `real_config_parses_and_builds_the_chain` regression
/// test now (the running binary always goes through `load_config_at` with
/// an explicit path); kept for that test's "does the real on-disk config
/// parse" purpose.
#[cfg(test)]
fn load_config() -> MicProcConf {
    load_config_at(&config_path())
}

/// True if an inotify event is an actual content/existence change to
/// `micproc.ron` -- NOT merely an access (open/read/close). Watching the
/// containing DIRECTORY rather than the file (and filtering by name here)
/// survives editors that save via rename-over-original (vim, and most
/// "atomic save" tools): those invalidate a watch on the file's own inode,
/// but the directory watch keeps seeing every event under it regardless of
/// which inode currently backs the file name.
///
/// Excluding `EventKind::Access` is load-bearing, not cosmetic: the reload
/// this gates itself calls `fs::read_to_string` on the same path, which
/// generates Access events for that same file. Treating those as
/// "relevant" (as an earlier version of this function did, checking only
/// the file name) creates a self-sustaining loop -- reload, which reads
/// the file, which fires an Access event, which triggers another reload --
/// observed live as thousands of chain rebuilds per minute, each one
/// audibly resetting the dynamics/EQ envelope and filter state.
fn event_touches_config(event: &notify::Event, file_name: &OsStr) -> bool {
    use notify::EventKind;
    let is_mutation = matches!(event.kind, EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_));
    is_mutation && event.paths.iter().any(|p| p.file_name() == Some(file_name))
}

/// Hot-reloads `micproc.ron` purely on inotify events (via `notify`) --
/// no polling loop, no idle wakeups between edits, and typically low
/// single-digit-millisecond reaction to a save (bounded by the debounce
/// window below, not by a fixed poll interval). Does ALL of the expensive
/// work (parse, build the chain, log) off the realtime thread, publishing
/// the result via `snapshot` for `process()` to pick up lock-free.
///
/// If the watch can't be set up (e.g. inotify instance/watch limits), this
/// logs and gives up on hot-reload entirely rather than falling back to
/// polling -- the whole point is zero idle overhead when nothing changes.
/// Takes `path` explicitly (rather than resolving `config_path()` itself)
/// so it has no implicit env-var dependency, making it directly testable
/// against a temp file (see `tests::hot_reload_reacts_to_a_file_write`).
fn spawn_reloader(snapshot: Arc<ArcSwap<DspSnapshot>>, rate: u32, path: PathBuf) {
    thread::spawn(move || {
        let Some(dir) = path.parent().map(|p| p.to_path_buf()) else {
            eprintln!("[micproc] config path {} has no parent dir; hot-reload disabled", path.display());
            return;
        };
        let Some(file_name) = path.file_name().map(|n| n.to_os_string()) else {
            eprintln!("[micproc] config path {} has no file name; hot-reload disabled", path.display());
            return;
        };

        let (tx, rx) = mpsc::channel();
        let mut watcher = match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(event) = res {
                let _ = tx.send(event);
            }
        }) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("[micproc] failed to start config watcher: {e}; hot-reload disabled");
                return;
            }
        };
        if let Err(e) = watcher.watch(&dir, RecursiveMode::NonRecursive) {
            eprintln!("[micproc] failed to watch {}: {e}; hot-reload disabled", dir.display());
            return;
        }

        loop {
            let Ok(first) = rx.recv() else { break };
            let mut relevant = event_touches_config(&first, &file_name);
            // Editors commonly fire several fs events per logical save
            // (write + rename + chmod, ...); coalesce a short burst into one
            // reload instead of rebuilding the chain once per event.
            while let Ok(ev) = rx.recv_timeout(Duration::from_millis(50)) {
                relevant |= event_touches_config(&ev, &file_name);
            }
            if !relevant {
                continue;
            }
            let conf = load_config_at(&path);
            let version = VERSION.load(Ordering::Relaxed);
            snapshot.store(Arc::new(build_snapshot(&conf, rate, version)));
        }
    });
}

// ────────────────────────────────────────────────────────────────────────────
// JACK NODE
// ────────────────────────────────────────────────────────────────────────────

struct MicProc {
    in_l: Port<AudioIn>,
    in_r: Port<AudioIn>,
    /// Quality/"good" lane -- RNNoise applied (~10ms fixed delay when
    /// enabled). Feeds vmic_good (the mic-feed mix).
    out_good_l: Port<AudioOut>,
    out_good_r: Port<AudioOut>,
    /// Fast lane -- no RNNoise, the chain's normal sub-1ms latency. Feeds
    /// vmic_fast (self-monitoring only; never captured by other apps).
    out_fast_l: Port<AudioOut>,
    out_fast_r: Port<AudioOut>,
    dsp: MicDsp,
    snapshot: Arc<ArcSwap<DspSnapshot>>,
}

impl MicProc {
    fn new(client: &Client, snapshot: Arc<ArcSwap<DspSnapshot>>) -> Result<Self, jack::Error> {
        let in_l = client.register_port("in_L", AudioIn::default())?;
        let in_r = client.register_port("in_R", AudioIn::default())?;
        let out_good_l = client.register_port("out_good_L", AudioOut::default())?;
        let out_good_r = client.register_port("out_good_R", AudioOut::default())?;
        let out_fast_l = client.register_port("out_fast_L", AudioOut::default())?;
        let out_fast_r = client.register_port("out_fast_R", AudioOut::default())?;
        let rate = client.sample_rate() as u32;
        RATE.store(rate, Ordering::Relaxed);

        let mut dsp = MicDsp::new();
        dsp.adopt(&snapshot.load());

        Ok(MicProc { in_l, in_r, out_good_l, out_good_r, out_fast_l, out_fast_r, dsp, snapshot })
    }
}

impl ProcessHandler for MicProc {
    fn process(&mut self, _client: &Client, scope: &ProcessScope) -> jack::Control {
        // Lock-free load; `adopt` on a version change is just a small Vec
        // clone + scalar copies -- everything expensive already happened on
        // the background reloader thread that built this snapshot.
        let snap = self.snapshot.load();
        if snap.version != self.dsp.version {
            self.dsp.adopt(&snap);
        }

        let n = scope.n_frames() as usize;
        let in_l = self.in_l.as_slice(scope);
        let in_r = self.in_r.as_slice(scope);
        let out_fast_l = self.out_fast_l.as_mut_slice(scope);
        let out_fast_r = self.out_fast_r.as_mut_slice(scope);
        let out_good_l = self.out_good_l.as_mut_slice(scope);
        let out_good_r = self.out_good_r.as_mut_slice(scope);

        if self.dsp.stereo2mono.enabled {
            // Standard stereo → mono. Fold the two inputs to one mono lane
            // per `mode`, run the chain, put each lane's mono result on
            // BOTH of that lane's outputs.
            for f in 0..n {
                let l = in_l[f];
                let r = in_r[f];
                let mono = match self.dsp.stereo2mono.fold {
                    FoldMode::Peak => if r.abs() > l.abs() { r } else { l },
                    FoldMode::Average => 0.5 * (l + r),
                    FoldMode::Left => l,
                    FoldMode::Right => r,
                };
                let (fast, good) = self.dsp.process(mono);
                out_fast_l[f] = fast;
                out_fast_r[f] = fast;
                out_good_l[f] = good;
                out_good_r[f] = good;
            }
        } else {
            // Fold disabled: plain stereo passthrough — each channel runs
            // the shared strip independently (linked dynamics, and shares
            // one Denoiser -- interleaving L/R through the RNNoise model's
            // continuous-stream state, same pre-existing quirk as the
            // dynamics state below), no folding, no duplication.
            for f in 0..n {
                let (fast_l, good_l) = self.dsp.process(in_l[f]);
                let (fast_r, good_r) = self.dsp.process(in_r[f]);
                out_fast_l[f] = fast_l;
                out_fast_r[f] = fast_r;
                out_good_l[f] = good_l;
                out_good_r[f] = good_r;
            }
        }

        jack::Control::Continue
    }
}

// ────────────────────────────────────────────────────────────────────────────
// MAIN
// ────────────────────────────────────────────────────────────────────────────

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (client, _status) = Client::new("micproc", ClientOptions::empty())?;
    let rate = client.sample_rate() as u32;
    RATE.store(rate, Ordering::Relaxed);

    let path = config_path();
    let initial_conf = load_config_at(&path);
    let initial_version = VERSION.load(Ordering::Relaxed);
    let snapshot = Arc::new(ArcSwap::from_pointee(build_snapshot(&initial_conf, rate, initial_version)));
    spawn_reloader(Arc::clone(&snapshot), rate, path);

    let proc = MicProc::new(&client, snapshot)?;
    let _active = client.activate_async((), proc)?;

    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The compressor must CUT gain above threshold (not boost it), engage
    /// FAST (attack) when the signal gets loud, and recover SLOWLY
    /// (release) afterward. Catches both the sign bug (was computing a
    /// boost) and the attack/release swap (was using release to engage and
    /// attack to recover) in one end-to-end pass.
    #[test]
    fn compressor_cuts_fast_and_recovers_slow() {
        let mut c = Dynamics::new(DynMode::Compressor);
        c.threshold_db = -20.0;
        c.ratio = 4.0;
        c.knee_db = 0.0; // hard knee: isolates the "d >= k/2" branch cleanly
        c.makeup_gain = 1.0;
        c.detector = 1.0; // no detector lag, isolate attack/release timing
        c.attack = one_pole(1.0, 48000); // fast
        c.release = one_pole(200.0, 48000); // slow

        // 20 dB over threshold at a 4:1 ratio should settle at -15 dB
        // (L_out - L_in = threshold + d/ratio - (threshold+d) = d*(1/ratio-1)).
        for _ in 0..240 {
            // 5ms @ 48kHz
            c.run(1.0, 0.0);
        }
        assert!(c.cur_db < 0.0, "compressor boosted instead of cutting: cur_db={}", c.cur_db);
        assert!(
            c.cur_db < -14.0,
            "compressor should have nearly reached -15 dB within 5ms at a 1ms attack, got {}",
            c.cur_db
        );

        // Signal drops back to silence: recovery should be SLOW (200ms
        // release), so after another 5ms it should have barely moved.
        for _ in 0..240 {
            c.run(1.0, -100.0);
        }
        assert!(
            c.cur_db < -10.0,
            "compressor recovered too fast for a 200ms release after only 5ms, got {}",
            c.cur_db
        );
    }

    /// Regression check: the expander shares `Dynamics::run` with the
    /// compressor but has the OPPOSITE polarity (opening back up is the
    /// fast phase, engaging on a quiet signal is the slow phase) -- make
    /// sure fixing the compressor didn't flip this one by mistake.
    #[test]
    fn expander_still_engages_slow_and_opens_fast() {
        let mut e = Dynamics::new(DynMode::Expander);
        e.threshold_db = -40.0;
        e.ratio = 4.0;
        e.knee_db = 0.0;
        e.floor_db = -24.0;
        e.makeup_gain = 1.0;
        e.detector = 1.0;
        e.attack = one_pole(1.0, 48000); // fast (opening)
        e.release = one_pole(200.0, 48000); // slow (engaging)

        // Well below threshold: engages (floored) attenuation, should be SLOW.
        for _ in 0..240 {
            e.run(1.0, -80.0);
        }
        assert!(
            e.cur_db > -3.0,
            "expander should barely have engaged within 5ms at a 200ms release, got {}",
            e.cur_db
        );

        // Signal returns above threshold: should open back up FAST.
        for _ in 0..240 {
            e.run(1.0, 0.0);
        }
        assert!(
            e.cur_db > -0.5,
            "expander should have nearly fully opened within 5ms at a 1ms attack, got {}",
            e.cur_db
        );
    }

    /// The level detector must smooth away per-sample jitter instead of
    /// tracking the raw instantaneous key value -- otherwise a signal
    /// alternating between loud and silent every single sample (worst-case
    /// stand-in for a low-pitched voice's waveform swinging within one
    /// pitch period) keeps the threshold comparison bouncing between the
    /// two extremes, which is exactly the "twitchy"/gritty failure mode
    /// this is meant to fix.
    #[test]
    fn detector_smooths_alternating_per_sample_levels() {
        let mut d = Dynamics::new(DynMode::Expander);
        d.threshold_db = -1000.0; // never triggers gain changes; isolates the detector
        d.detector = one_pole(3.0, 48000);

        for i in 0..2000 {
            let key = if i % 2 == 0 { 0.0 } else { -120.0 };
            d.run(1.0, key);
        }

        assert!(
            d.detected_db > -90.0 && d.detected_db < -30.0,
            "detector should have settled well away from either raw extreme (0 / -120), got {}",
            d.detected_db
        );
    }

    /// End-to-end check that the inotify-based reloader actually reacts to a
    /// real file write -- not just that `notify` compiles, but that a save
    /// lands in the published snapshot well within the old 1000ms poll
    /// interval this replaced.
    #[test]
    fn hot_reload_reacts_to_a_file_write() {
        let dir = std::env::temp_dir().join(format!("micproc-jack-test-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("create temp dir");
        let path = dir.join("micproc.ron");
        let conf = |preamp: f32| {
            format!(
                r#"(preamp_db: {preamp}, active_mode: "m", modes: {{"m": (stages: [(type: "stereo2mono")])}})"#
            )
        };
        fs::write(&path, conf(1.0)).expect("write initial config");

        let initial = load_config_at(&path);
        let initial_version = VERSION.load(Ordering::Relaxed);
        let snapshot = Arc::new(ArcSwap::from_pointee(build_snapshot(&initial, 48000, initial_version)));
        spawn_reloader(Arc::clone(&snapshot), 48000, path.clone());

        // Give the watcher a moment to actually register before writing.
        thread::sleep(Duration::from_millis(100));

        let before_version = snapshot.load().version;
        fs::write(&path, conf(7.0)).expect("write updated config");

        let want_preamp = 10f32.powf(7.0 / 20.0);
        let mut reloaded = false;
        for _ in 0..40 {
            thread::sleep(Duration::from_millis(25));
            let snap = snapshot.load();
            if snap.version != before_version && (snap.preamp - want_preamp).abs() < 1e-4 {
                reloaded = true;
                break;
            }
        }

        let _ = fs::remove_dir_all(&dir);
        assert!(reloaded, "inotify-based hot-reload did not pick up the file write within 1s");
    }

    #[test]
    fn real_config_parses_and_builds_the_chain() {
        // NOTE: this reads the user's real, live, hand-tuned micproc.ron --
        // which stages are PRESENT in the active mode (expander/compressor/
        // gate/eq/rnnoise, in what order) is exactly what this checks
        // parses/builds without panicking; which of them
        // are currently `enabled = true` is live-tunable user preference,
        // not a code contract, so this must not hardcode a specific
        // enabled-set (it will legitimately drift as the user tunes).
        let conf = load_config();
        let stages = active_stages(&conf);
        let kinds: Vec<&str> = stages.iter().map(|s| s.ty.as_str()).collect();
        assert!(kinds.first() == Some(&"stereo2mono"), "stage 0 must be stereo2mono, got {kinds:?}");
        assert!(kinds.contains(&"eq"), "chain should still end in an eq stage, got {kinds:?}");

        let snap = build_snapshot(&conf, 48000, 1);
        let mut dsp = MicDsp::new();
        dsp.adopt(&snap);

        // stereo2mono and rnnoise are handled separately, not per-sample
        // stages; every OTHER present-and-enabled stage produces one Stage
        // entry on each lane that doesn't specifically disable it (the live
        // config has no per-lane disables, so fast/good should match
        // exactly).
        let enabled_non_stereo =
            stages.iter().filter(|s| s.enabled && s.ty != "stereo2mono" && s.ty != "rnnoise").count();
        assert_eq!(dsp.fast.stages.len(), enabled_non_stereo);
        assert_eq!(dsp.good.stages.len(), enabled_non_stereo);
        assert!(dsp.stereo2mono.enabled);
        assert_eq!(dsp.stereo2mono.fold, FoldMode::Peak);
        assert!(matches!(dsp.fast.stages.last(), Some(Stage::Eq { .. })), "chain should still end in Eq");

        let _ = (snap.rnnoise_fast, snap.rnnoise_good);

        // EQ holds the five ported bands.
        match dsp.fast.stages.last() {
            Some(Stage::Eq { bqs, .. }) => assert_eq!(bqs.len(), 5),
            _ => unreachable!(),
        }
    }

    /// `disable-output-fast`/`disable-output-good` must (a) drop the stage
    /// from ONLY that lane's own stage list, leaving the other lane's list
    /// (and its gate-detector indexing) untouched, and (b) actually produce
    /// different audio on the two lanes at runtime -- not just parse.
    #[test]
    fn per_lane_stage_disable_only_affects_its_own_lane() {
        // Hard mute below threshold (ratio huge, floor silence) on the gate
        // so the two lanes' outputs are trivially distinguishable at runtime.
        let ron = r#"(
            preamp_db: 0.0,
            active_mode: "m",
            modes: {
                "m": (stages: [
                    (type: "stereo2mono", enabled: true, mode: "peak"),
                    (
                        type: "gate",
                        threshold_db: -10.0,
                        ratio: 1000.0,
                        range_db: -120.0,
                        hysteresis_db: 0.0,
                        hold_ms: 0.0,
                        attack_ms: 0.001,
                        release_ms: 0.001,
                        detector_ms: 0.001,
                        disable_output_fast: true,
                    ),
                ]),
            },
        )"#;
        let conf: MicProcConf = ron_options().from_str(ron).expect("valid config");
        let stages = active_stages(&conf);
        assert!(stages[1].disable_output_fast);
        assert!(!stages[1].disable_output_good);

        let snap = build_snapshot(&conf, 48000, 1);
        // Dropped entirely from fast's own list, present on good's.
        assert_eq!(snap.fast.stages.len(), 0, "gate should be absent from the fast lane's stage list");
        assert_eq!(snap.good.stages.len(), 1, "gate should still be present on the good lane's stage list");
        assert!(matches!(snap.good.stages[0], Stage::Gate(_)));

        let mut dsp = MicDsp::new();
        dsp.adopt(&snap);
        // A quiet input (well below the gate's -10dB threshold): the fast
        // lane (no gate) passes it through unattenuated; the good lane (gate
        // active, huge ratio, deep floor) crushes it toward silence.
        let quiet = from_db(-40.0);
        let (fast, good) = dsp.process(quiet);
        assert!((fast - quiet).abs() < 1e-6, "fast lane should be an unmodified passthrough, got {fast}");
        assert!(good.abs() < quiet.abs() * 0.1, "good lane's gate should have crushed a -40dB input, got {good}");
    }

    /// The fast log2/exp2 approximations stand in for libm log10()/powf() on
    /// every sample; verify their error stays far below anything audible
    /// over the ranges this DSP actually produces (levels down to -140 dB,
    /// magnitudes from silence up to a couple dB of headroom).
    #[test]
    fn fast_math_matches_std_within_tolerance() {
        let mut max_log2_db_err = 0.0f32;
        let mut mag = 1e-6f32;
        let mut steps = 0u32;
        while mag <= 2.0 {
            let got = fast_log2(mag) * LOG2_TO_DB;
            let want = 20.0 * mag.log10();
            max_log2_db_err = max_log2_db_err.max((got - want).abs());
            mag *= 1.001;
            steps += 1;
        }
        assert!(steps > 1000, "sanity: sweep actually ran");
        assert!(max_log2_db_err < 0.01, "fast_log2-derived dB error too large: {max_log2_db_err}");

        let mut max_exp2_db_err = 0.0f32;
        let mut d = -140.0f32;
        while d <= 20.0 {
            let got = from_db(d);
            let want = 10f32.powf(d / 20.0);
            // Compare in dB, not linear, since these are gain multipliers.
            let err_db = 20.0 * (got / want).log10();
            max_exp2_db_err = max_exp2_db_err.max(err_db.abs());
            d += 0.01;
        }
        assert!(max_exp2_db_err < 0.001, "fast_exp2 dB error too large: {max_exp2_db_err}");
    }

    /// The RNNoise bridge must (a) stay silent for exactly one frame's worth
    /// of warm-up, (b) emit finite, non-NaN, non-exploding samples forever
    /// after, and (c) settle into a stable, unchanging pipeline delay
    /// (`RNN_FRAME` samples) rather than drifting -- if it ever drifted,
    /// input and output would slowly fall out of sync with each other.
    #[test]
    fn denoiser_pipeline_warms_up_then_emits_finite_samples_at_a_fixed_delay() {
        let mut d = Denoiser::new();

        let mut warmup_none_count = 0usize;
        for i in 0..RNN_FRAME {
            let x = (i as f32 * 0.05).sin() * 0.1;
            if d.push(x).is_none() {
                warmup_none_count += 1;
            }
        }
        assert_eq!(
            warmup_none_count, RNN_FRAME,
            "expected exactly one frame of silence during warm-up, got {warmup_none_count}"
        );

        // Every call from here on must emit Some(finite) -- the FIFO is full
        // and draining at exactly the rate it's filling.
        for i in 0..(RNN_FRAME * 4) {
            let x = (i as f32 * 0.05).sin() * 0.1;
            let v = d.push(x).expect("denoiser should emit every sample after warm-up");
            assert!(v.is_finite(), "denoiser output should be finite, got {v} at sample {i}");
            assert!(v.abs() < 10.0, "denoiser output should stay near input scale, got {v} at sample {i}");
        }
    }
}
