//! PipeWire Links Manager
//!
//! Declarative audio/MIDI wiring for this machine, TWO output lanes since
//! micproc-jack forks its processed signal in two:
//!
//!   Komplete mic -> micproc -> forked into:
//!     - out_rnn_*  (RNNoise quality lane) -> the "vmic" app feed (what
//!       other apps/listeners capture as the microphone)
//!     - out_fast_* (no-RNNoise, chain's normal sub-1ms latency) -> the
//!       "vmonitor" app feed (self-monitoring ONLY)
//!   vmonitor monitor -> the default speaker device (so you hear your own
//!     fast-lane voice mixed with whatever apps play). "vmic"'s monitor is
//!     deliberately NEVER wired to your speakers -- doing so would mean
//!     hearing your own voice twice, at two different delays (RNNoise's
//!     ~10ms vs. the fast lane's), an audible echo/comb-filter artifact.
//!     If the default speaker IS vmic or vmonitor itself, left alone.
//!   apps -> the default speaker device (WirePlumber's normal routing; the
//!     mic arrives there through the vmonitor tap)
//!   Oxygen 49 MIDI -> fluidsynth (on-demand) -> BOTH the "vmic" and
//!     "vmonitor" app feeds (so the synth is audible to you AND listeners)
//!   ~/Soundboard/play.sh -> the default speaker device
//!
//! The routing is described by the `routes()` table, the vmonitor rule
//! and the synth rule.
//!
//! Purely event-driven: this is a persistent PipeWire client (via the
//! `pipewire` crate) subscribed to the registry (node/port/link add+remove)
//! and to the "default" metadata object (default sink changes) -- no
//! polling loop, no `pw-cli`/`pw-link`/`pactl` subprocess spawns for the
//! routine path. A burst of registry events (e.g. one app launching, or
//! startup enumeration) is coalesced by a short debounce timer into a
//! single route-application pass instead of one per event. Links are
//! created/destroyed natively (`Core::create_object`/`Registry::destroy_global`)
//! rather than by shelling out to `pw-link`.
//!
//! `--dry-run`: logs every connect/disconnect/vmic-provision/synth-start
//! decision instead of performing it -- fully read-only against the live
//! graph, safe to run alongside the real service for diagnosis.

use pipewire as pw;
use pw::loop_::Signal;
use pw::properties::properties;
use pw::registry::GlobalObject;
use pw::spa::utils::dict::DictRef;
use pw::types::ObjectType;

use std::cell::RefCell;
use std::collections::HashMap;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

// ────────────────────────────────────────────────────────────────────
// TIMING
// ────────────────────────────────────────────────────────────────────

/// How long to wait after the LAST registry/metadata event before actually
/// applying routes. Coalesces a burst (e.g. ~125 objects announced at
/// startup, or several events from one app launching) into one pass instead
/// of one per event.
const DEBOUNCE: Duration = Duration::from_millis(50);

/// A just-issued link creation is considered "in flight" (and won't be
/// re-attempted) for this long, covering the round-trip before the server's
/// own Link-added event confirms it in `Manager::links`. If creation
/// silently failed for some reason, the route becomes eligible for a fresh
/// attempt again after this window -- a small self-healing fallback, not a
/// real retry loop (the old poll-based version needed retries because it
/// could race a device's ports still coming up; this version only ever
/// attempts a route once the ports it needs already exist in the registry).
const PENDING_LINK_TTL: Duration = Duration::from_secs(2);

// ────────────────────────────────────────────────────────────────────
// NODE NAMES & THE SYNTH
// ────────────────────────────────────────────────────────────────────

const NAME_MIC: &str = "Komplete";
const NAME_MICPROC: &str = "micproc";
/// The quality/broadcast lane -- what apps capture as the mic. "vmic" is
/// NOT a substring of "vmonitor" (and vice versa), so `Device` matching by
/// substring cleanly tells the two nodes apart.
const NAME_VMIC: &str = "vmic";
/// The fast/self-monitor lane -- routed only to your own speakers.
const NAME_VMONITOR: &str = "vmonitor";
// Matches the synth's single JACK node ("fluidsynth-midi": MIDI-in port +
// audio-out ports on one node), as well as the old PulseAudio layout
// ("FluidSynth" audio + "FLUID Synth (pid)" MIDI).
const NAME_SYNTH: &str = "Synth";
const SYNTH_SOUNDFONT: &str = "/usr/share/soundfonts/FluidR3_GM.sf2";

// ────────────────────────────────────────────────────────────────────
// DEVICES & LANES — the machine's wiring vocabulary.
// ────────────────────────────────────────────────────────────────────

/// A set of ports on a PipeWire node. `node` matches the node name by
/// substring; `port` additionally narrows to ports whose own name contains
/// that substring (`""` = every port).
#[derive(Debug, Clone, Copy)]
struct Device {
    node: &'static str,
    port: &'static str,
}

const fn dev(node: &'static str, port: &'static str) -> Device {
    Device { node, port }
}

const MIC_INPUT: Device = dev(NAME_MIC, "capture_");
const MICPROC_INPUT: Device = dev(NAME_MICPROC, "in_");
/// Quality/broadcast lane output (RNNoise applied) -- feeds `vmic`.
const MICPROC_OUT_RNN: Device = dev(NAME_MICPROC, "out_rnn_");
/// Fast/self-monitor lane output (no RNNoise) -- feeds `vmonitor`.
const MICPROC_OUT_FAST: Device = dev(NAME_MICPROC, "out_fast_");
const VMIC_SINK_IN: Device = dev(NAME_VMIC, "playback_");
const VMONITOR_SINK_IN: Device = dev(NAME_VMONITOR, "playback_");
const VMONITOR_MONITOR: Device = dev(NAME_VMONITOR, "monitor_");
const KEYBOARD_OUT: Device = dev("", "Oxygen");
const SYNTH_ANY: Device = dev(NAME_SYNTH, "");

// ────────────────────────────────────────────────────────────────────
// ROUTING TABLE — edit these lines to rewire the machine.
// ────────────────────────────────────────────────────────────────────

enum Route {
    Channels {
        src: Device,
        dst: Device,
        map: &'static [(&'static str, &'static str)],
        exclusive: bool,
    },
}

fn pairs(src: Device, dst: Device, map: &'static [(&'static str, &'static str)]) -> Route {
    Route::Channels { src, dst, map, exclusive: false }
}

fn pairs_exclusive(src: Device, dst: Device, map: &'static [(&'static str, &'static str)]) -> Route {
    Route::Channels { src, dst, map, exclusive: true }
}

fn routes() -> Vec<Route> {
    vec![
        pairs_exclusive(MIC_INPUT, MICPROC_INPUT, &[("FL", "in_L"), ("FR", "in_R")]),
        // Quality/broadcast lane -> vmic (what apps capture as the mic).
        pairs(MICPROC_OUT_RNN, VMIC_SINK_IN, &[("L", "playback_FL"), ("R", "playback_FR")]),
        // Fast/self-monitor lane -> vmonitor (your speakers only).
        pairs(MICPROC_OUT_FAST, VMONITOR_SINK_IN, &[("L", "playback_FL"), ("R", "playback_FR")]),
    ]
}

// ────────────────────────────────────────────────────────────────────
// PORT MODEL
// ────────────────────────────────────────────────────────────────────

/// Which stream kind a port carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PortKind {
    AudioOut,
    AudioIn,
    MidiOut,
    MidiIn,
}

fn port_kind(format: &str, direction: &str) -> PortKind {
    let is_midi = format.contains("midi");
    let out = direction == "out";
    match (is_midi, out) {
        (true, true) => PortKind::MidiOut,
        (true, false) => PortKind::MidiIn,
        (false, true) => PortKind::AudioOut,
        (false, false) => PortKind::AudioIn,
    }
}

/// What the registry told us about one Port global.
struct PortInfo {
    node_id: u32,
    name: String,
    format: String,
    direction: String,
}

/// A port resolved against the current node-name table, for matching
/// against `Device` patterns and for issuing link create/destroy calls.
#[derive(Debug, Clone)]
struct RPort {
    id: u32,
    node_id: u32,
    device: String,
    name: String,
}

impl RPort {
    /// The part after the last `_` in the port name, e.g. `FL` from
    /// `capture_FL`, `1` from `monitor_1`. Used as a routing key.
    fn channel(&self) -> Option<&str> {
        self.name.rsplit_once('_').map(|(_, ch)| ch)
    }
}

impl std::fmt::Display for RPort {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.device, self.name)
    }
}

fn prop<'a>(props: Option<&'a DictRef>, key: &str) -> Option<&'a str> {
    props.and_then(|p| p.get(key))
}

// ────────────────────────────────────────────────────────────────────
// MANAGER — all live state, rebuilt incrementally from registry events.
// ────────────────────────────────────────────────────────────────────

struct Manager {
    core: pw::core::CoreRc,
    registry: pw::registry::RegistryRc,
    /// `--dry-run`: log every connect/disconnect/vmic-provision decision
    /// instead of actually issuing it. Read-only against the live graph --
    /// used to validate this against a real running system before it's ever
    /// allowed to mutate anything.
    dry_run: bool,

    nodes: HashMap<u32, String>,
    ports: HashMap<u32, PortInfo>,
    /// link global id -> (output port id, input port id).
    links: HashMap<u32, (u32, u32)>,
    /// A link create we just issued, not yet confirmed via a registry Link
    /// event -- see `PENDING_LINK_TTL`.
    pending_links: HashMap<(u32, u32), Instant>,

    default_sink: Option<String>,
    link_factory: Option<String>,

    // Kept alive only so the "default" metadata subscription keeps running;
    // never read directly.
    _default_metadata: Option<pw::metadata::Metadata>,
    _default_metadata_listener: Option<pw::metadata::MetadataListener>,

    synth: Option<Child>,
    synth_stdin: Option<ChildStdin>,
}

impl Manager {
    fn new(core: pw::core::CoreRc, registry: pw::registry::RegistryRc, dry_run: bool) -> Self {
        Manager {
            core,
            registry,
            dry_run,
            nodes: HashMap::new(),
            ports: HashMap::new(),
            links: HashMap::new(),
            pending_links: HashMap::new(),
            default_sink: None,
            link_factory: None,
            _default_metadata: None,
            _default_metadata_listener: None,
            synth: None,
            synth_stdin: None,
        }
    }

    // ── registry event handlers ───────────────────────────────────

    fn on_global(&mut self, obj: &GlobalObject<&DictRef>) {
        match obj.type_ {
            ObjectType::Node => {
                if let Some(name) = prop(obj.props, "node.name") {
                    self.nodes.insert(obj.id, name.to_string());
                }
            }
            ObjectType::Port => {
                if let (Some(format), Some(direction)) =
                    (prop(obj.props, "format.dsp"), prop(obj.props, "port.direction"))
                {
                    let node_id = prop(obj.props, "node.id").and_then(|s| s.parse().ok());
                    let name = prop(obj.props, "port.name").unwrap_or_default();
                    if let Some(node_id) = node_id {
                        self.ports.insert(
                            obj.id,
                            PortInfo {
                                node_id,
                                name: name.to_string(),
                                format: format.to_string(),
                                direction: direction.to_string(),
                            },
                        );
                    }
                }
            }
            ObjectType::Link => {
                let out_port = prop(obj.props, "link.output.port").and_then(|s| s.parse::<u32>().ok());
                let in_port = prop(obj.props, "link.input.port").and_then(|s| s.parse::<u32>().ok());
                if let (Some(o), Some(i)) = (out_port, in_port) {
                    self.pending_links.remove(&(o, i));
                    self.links.insert(obj.id, (o, i));
                }
            }
            ObjectType::Factory => {
                if prop(obj.props, "factory.type.name") == Some(ObjectType::Link.to_str()) {
                    if let Some(name) = prop(obj.props, "factory.name") {
                        self.link_factory = Some(name.to_string());
                    }
                }
            }
            _ => {}
        }
    }

    fn on_global_remove(&mut self, id: u32) {
        self.nodes.remove(&id);
        self.ports.remove(&id);
        self.links.remove(&id);
    }

    // ── port queries ───────────────────────────────────────────────

    /// All ports matching a device pattern and stream kind. Matching is
    /// case-insensitive so node names like `fluidsynth`, `FluidSynth` and
    /// `FLUID Synth (pid)` all match the same device pattern.
    fn resolved_ports(&self, d: &Device, kind: PortKind) -> Vec<RPort> {
        let node_q = d.node.to_lowercase();
        let port_q = d.port.to_lowercase();
        self.ports
            .iter()
            .filter_map(|(&id, info)| {
                let device = self.nodes.get(&info.node_id)?;
                if !device.to_lowercase().contains(&node_q) || !info.name.to_lowercase().contains(&port_q) {
                    return None;
                }
                if port_kind(&info.format, &info.direction) != kind {
                    return None;
                }
                Some(RPort { id, node_id: info.node_id, device: device.clone(), name: info.name.clone() })
            })
            .collect()
    }

    fn sink_inputs(&self, sink_name: &str) -> Vec<RPort> {
        self.ports
            .iter()
            .filter_map(|(&id, info)| {
                let device = self.nodes.get(&info.node_id)?;
                if device != sink_name || !info.name.starts_with("playback_") {
                    return None;
                }
                if port_kind(&info.format, &info.direction) != PortKind::AudioIn {
                    return None;
                }
                Some(RPort { id, node_id: info.node_id, device: device.clone(), name: info.name.clone() })
            })
            .collect()
    }

    // ── link management (native create_object / destroy_global) ───

    fn link_exists(&mut self, out_id: u32, in_id: u32) -> bool {
        if self.links.values().any(|&(o, i)| o == out_id && i == in_id) {
            return true;
        }
        match self.pending_links.get(&(out_id, in_id)) {
            Some(t) if t.elapsed() < PENDING_LINK_TTL => true,
            _ => {
                self.pending_links.remove(&(out_id, in_id));
                false
            }
        }
    }

    fn connect(&mut self, source: &RPort, sink: &RPort) {
        if self.link_exists(source.id, sink.id) {
            return;
        }
        if self.dry_run {
            // Deliberately NOT marked pending: re-logs every debounce pass
            // this route is still wanted, which is exactly what makes a
            // flapping/incorrect decision visible during dry-run.
            println!("[dry-run] would create link: {source} -> {sink}");
            return;
        }
        let Some(factory) = self.link_factory.clone() else {
            eprintln!("No link factory discovered yet; can't link {source} -> {sink}");
            return;
        };
        let props = properties! {
            "link.output.port" => source.id.to_string(),
            "link.input.port" => sink.id.to_string(),
            "link.output.node" => source.node_id.to_string(),
            "link.input.node" => sink.node_id.to_string(),
            // Persist independently of our local proxy -- we track/destroy
            // links by id via the registry, not by holding proxies.
            "object.linger" => "1",
        };
        match self.core.create_object::<pw::link::Link>(&factory, &props) {
            Ok(_link) => {
                self.pending_links.insert((source.id, sink.id), Instant::now());
                println!("Created link: {source} -> {sink}");
            }
            Err(e) => eprintln!("Failed to create link: {source} -> {sink}: {e}"),
        }
    }

    fn disconnect(&mut self, source: &RPort, sink: &RPort) {
        let id = self.links.iter().find(|(_, &(o, i))| o == source.id && i == sink.id).map(|(&id, _)| id);
        if let Some(id) = id {
            if self.dry_run {
                println!("[dry-run] would remove link: {source} -> {sink}");
            } else {
                let _ = self.registry.destroy_global(id);
                println!("Removed link: {source} -> {sink}");
            }
        }
        self.pending_links.remove(&(source.id, sink.id));
    }

    // ── synth lifecycle (on-demand) ────────────────────────────────

    fn synth_running(&mut self) -> bool {
        self.synth_stdin.is_some() && self.synth.as_mut().is_some_and(|c| is_alive(c))
    }

    fn ensure_synth_running(&mut self) {
        if self.synth_running() {
            return;
        }
        if self.dry_run {
            println!("[dry-run] keyboard plugged in; would start {}", NAME_SYNTH);
            return;
        }
        if let Some(mut child) = self.synth.take() {
            if child.try_wait().ok().flatten().is_none() {
                eprintln!("{} died unexpectedly; restarting", NAME_SYNTH);
            }
            self.synth_stdin.take();
            let _ = child.kill();
            let _ = child.wait();
        }

        // JACK driver (`-a jack -o midi.driver=jack`) so the synth appears
        // in qpwgraph as ONE node ("fluidsynth-midi") with a MIDI-in port
        // and two audio-out ports. `-r 48000` matches the PipeWire JACK
        // sample rate. Stdin is piped and held open (fluidsynth's
        // interactive shell panics on stdin EOF; no `-i` since it exits
        // when stdin isn't a live shell).
        let mut child = match Command::new("fluidsynth")
            .args(["-a", "jack", "-r", "48000", "-c", "2", "-g", "1.0"])
            .args(["-o", "midi.driver=jack", SYNTH_SOUNDFONT])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Failed to start {}: {}", NAME_SYNTH, e);
                return;
            }
        };

        self.synth_stdin = child.stdin.take();
        self.synth = Some(child);
        println!("Started {}", NAME_SYNTH);
    }

    fn stop_synth(&mut self) {
        self.synth_stdin.take();
        if let Some(mut child) = self.synth.take() {
            let _ = child.kill();
            let _ = child.wait();
            println!("Stopped {}", NAME_SYNTH);
        }
    }

    // ── route engine ───────────────────────────────────────────────

    fn apply_routes(&mut self) {
        self.ensure_virtual_sinks();
        for route in routes() {
            self.apply_route(route);
        }
        self.apply_vmonitor_route();
        self.apply_synth_route();
        self.unroute_stray_mix_links();
    }

    /// vmonitor's monitor tap -> the default speaker device. This is the
    /// ONLY self-listen path: vmic's monitor is left alone here entirely
    /// (apps capture from it; it must never also reach your own speakers,
    /// or you'd hear your own voice twice at two different delays).
    fn apply_vmonitor_route(&mut self) {
        let Some(default) = self.default_sink.clone() else { return };
        if default.contains(NAME_VMIC) || default.contains(NAME_VMONITOR) {
            return;
        }

        let sinks = self.sink_inputs(&default);
        if sinks.is_empty() {
            return;
        }

        for monitor in self.resolved_ports(&VMONITOR_MONITOR, PortKind::AudioOut) {
            let Some(ch) = monitor.channel() else { continue };
            let want = format!("playback_{ch}");
            if let Some(sink) = sinks.iter().find(|s| s.name == want) {
                self.connect(&monitor, sink);
            }
        }

        let stray: Vec<(RPort, RPort)> = {
            let mut out = Vec::new();
            for &(out_id, in_id) in self.links.values() {
                let Some(src) = self.rport(out_id) else { continue };
                let Some(dst) = self.rport(in_id) else { continue };
                if src.device.contains(NAME_VMONITOR)
                    && src.name.starts_with("monitor_")
                    && !(dst.device == default && dst.name.starts_with("playback_"))
                {
                    out.push((src, dst));
                }
            }
            out
        };
        for (src, dst) in stray {
            self.disconnect(&src, &dst);
        }
    }

    /// Resolve a live port id to an `RPort`, or `None` if it's no longer
    /// (or not yet) in `self.ports`/`self.nodes`.
    fn rport(&self, id: u32) -> Option<RPort> {
        let info = self.ports.get(&id)?;
        let device = self.nodes.get(&info.node_id)?;
        Some(RPort { id, node_id: info.node_id, device: device.clone(), name: info.name.clone() })
    }

    /// Make sure both virtual mic nodes (`vmic`, `vmonitor`) exist. The
    /// filter-chain (pipewire.conf.d/99-vmic.conf) provides both at PipeWire
    /// startup; as a fallback we can provision a Pulse null-sink each so
    /// there's always something to route to/pick. This is the one remaining
    /// subprocess spawn in the routine path, and only actually runs if one
    /// is somehow missing (in practice: never, once 99-vmic.conf is loaded).
    fn ensure_virtual_sinks(&mut self) {
        self.ensure_named_sink(NAME_VMIC);
        self.ensure_named_sink(NAME_VMONITOR);
    }

    fn ensure_named_sink(&mut self, name: &str) {
        if self.nodes.values().any(|n| n.contains(name)) {
            return;
        }
        if self.dry_run {
            println!("[dry-run] {name} missing; would provision a Pulse null-sink fallback");
            return;
        }
        let out = Command::new("pactl").args(["load-module", "module-null-sink", &format!("sink_name={name}")]).output();
        match out {
            Ok(o) => println!("Loaded {name} null-sink: {}", String::from_utf8_lossy(&o.stdout).trim()),
            Err(e) => eprintln!("Failed to provision {name} fallback sink: {e}"),
        }
    }

    fn apply_route(&mut self, route: Route) {
        match route {
            Route::Channels { src, dst, map, exclusive } => self.route_channels(src, dst, map, exclusive),
        }
    }

    fn route_channels(&mut self, src: Device, dst: Device, map: &[(&str, &str)], exclusive: bool) {
        let sources = self.resolved_ports(&src, PortKind::AudioOut);
        let sinks = self.resolved_ports(&dst, PortKind::AudioIn);

        for source in &sources {
            let Some(ch) = source.channel() else { continue };
            let intended: Vec<&str> = map.iter().filter(|(key, _)| key == &ch).map(|(_, name)| *name).collect();
            if intended.is_empty() {
                continue;
            }
            for sink_name in &intended {
                if let Some(sink) = sinks.iter().find(|s| &s.name == sink_name) {
                    self.connect(source, sink);
                }
            }
            if exclusive {
                let leaks: Vec<RPort> =
                    sinks.iter().filter(|s| !intended.contains(&s.name.as_str())).cloned().collect();
                for leak in leaks {
                    self.disconnect(source, &leak);
                }
            }
        }
    }

    /// Anything on the micproc or the vmic/vmonitor nodes that isn't the
    /// routing table above is stray, so links stay exact even when apps
    /// auto-connect. Each micproc output lane may ONLY reach its own node:
    /// out_rnn_* -> vmic, out_fast_* -> vmonitor -- never crossed, and
    /// never both (that would defeat the whole point of the split: the
    /// self-monitor lane leaking into what apps capture, or vice versa).
    fn unroute_stray_mix_links(&mut self) {
        let stray: Vec<(RPort, RPort)> = {
            let mut out = Vec::new();
            for &(out_id, in_id) in self.links.values() {
                let Some(src) = self.rport(out_id) else { continue };
                let Some(dst) = self.rport(in_id) else { continue };

                let micproc_out_rnn = src.device.contains(NAME_MICPROC) && src.name.starts_with("out_rnn_");
                let micproc_out_fast = src.device.contains(NAME_MICPROC) && src.name.starts_with("out_fast_");
                let to_vmic = dst.device.contains(NAME_VMIC) && dst.name.starts_with("playback_");
                let to_vmonitor = dst.device.contains(NAME_VMONITOR) && dst.name.starts_with("playback_");

                let mic_to_proc = src.device.contains(NAME_MIC)
                    && dst.device.contains(NAME_MICPROC)
                    && ((src.name == "capture_FL" && dst.name == "in_L")
                        || (src.name == "capture_FR" && dst.name == "in_R"));
                let bad_micproc_in = dst.device.contains(NAME_MICPROC) && dst.name.starts_with("in_") && !mic_to_proc;
                let bad_rnn_out = micproc_out_rnn && !to_vmic;
                let bad_fast_out = micproc_out_fast && !to_vmonitor;

                if bad_micproc_in || bad_rnn_out || bad_fast_out {
                    out.push((src, dst));
                }
            }
            out
        };
        for (src, dst) in stray {
            self.disconnect(&src, &dst);
        }
    }

    /// Oxygen 49 MIDI -> fluidsynth -> the vmic app feed. The synth runs
    /// only while the keyboard is plugged in.
    fn apply_synth_route(&mut self) {
        let keyboard_plugged = !self.resolved_ports(&KEYBOARD_OUT, PortKind::MidiOut).is_empty();

        if !keyboard_plugged {
            if self.synth.is_some() {
                self.stop_synth();
            }
            return;
        }

        self.ensure_synth_running();
        if !self.synth_running() {
            return;
        }

        let synth_midi_in = self.resolved_ports(&SYNTH_ANY, PortKind::MidiIn).into_iter().next();
        if let Some(synth_in) = synth_midi_in {
            for kb in self.resolved_ports(&KEYBOARD_OUT, PortKind::MidiOut) {
                self.connect(&kb, &synth_in);
            }
        }

        // "Anything connected" (lane 1): the synth feeds BOTH nodes, so it's
        // audible in your own monitor (via vmonitor) as well as to whoever
        // captures the mic (via vmic). PipeWire sums multiple sources
        // landing on the same playback_FL/FR ports natively -- no mixing
        // node needed on either side.
        let vmic_ins = self.resolved_ports(&VMIC_SINK_IN, PortKind::AudioIn);
        let vmonitor_ins = self.resolved_ports(&VMONITOR_SINK_IN, PortKind::AudioIn);
        for port in self.resolved_ports(&SYNTH_ANY, PortKind::AudioOut) {
            let dest = match port.name.as_str() {
                "left" | "output_FL" | "FL" => "playback_FL",
                "right" | "output_FR" | "FR" => "playback_FR",
                _ => continue,
            };
            if let Some(sink) = vmic_ins.iter().find(|s| s.name == dest) {
                self.connect(&port, sink);
            }
            if let Some(sink) = vmonitor_ins.iter().find(|s| s.name == dest) {
                self.connect(&port, sink);
            }
        }

        self.unroute_stray_synth_links();
    }

    fn unroute_stray_synth_links(&mut self) {
        let stray: Vec<(RPort, RPort)> = {
            let mut out = Vec::new();
            for &(out_id, in_id) in self.links.values() {
                let Some(src) = self.rport(out_id) else { continue };
                let Some(dst) = self.rport(in_id) else { continue };
                let from_synth = src.device.to_lowercase().contains(&NAME_SYNTH.to_lowercase());
                let to_feed = (dst.device.to_lowercase().contains(&NAME_VMIC.to_lowercase())
                    || dst.device.to_lowercase().contains(&NAME_VMONITOR.to_lowercase()))
                    && dst.name.starts_with("playback_");
                if from_synth && !to_feed {
                    out.push((src, dst));
                }
            }
            out
        };
        for (src, dst) in stray {
            self.disconnect(&src, &dst);
        }
    }
}

fn is_alive(child: &mut Child) -> bool {
    child.try_wait().ok().flatten().is_none()
}

/// Pull `"name"` out of a PipeWire metadata JSON value, e.g.
/// `{"name":"alsa_output...."}` -> `alsa_output....`. Metadata values for
/// `default.audio.sink` are always this shape in practice; a tiny ad-hoc
/// extractor keeps this crate free of a JSON dependency for one field.
fn extract_json_name(value: &str) -> Option<String> {
    let after_key = &value[value.find("\"name\"")? + 6..];
    let after_colon = after_key[after_key.find(':')? + 1..].trim_start();
    let after_quote = after_colon.strip_prefix('"')?;
    let end = after_quote.find('"')?;
    Some(after_quote[..end].to_string())
}

// ────────────────────────────────────────────────────────────────────
// MAIN — persistent PipeWire client, event-driven.
// ────────────────────────────────────────────────────────────────────

fn main() {
    let dry_run = std::env::args().any(|a| a == "--dry-run");

    pw::init();

    // Intentionally leaked: this is the one main loop for the process's
    // entire lifetime, so a genuine `'static` reference to it (rather than
    // fighting the borrow checker over a local variable's lexical scope) is
    // the natural fit -- the OS reclaims it at process exit regardless.
    let main_loop: &'static pw::main_loop::MainLoopRc =
        Box::leak(Box::new(pw::main_loop::MainLoopRc::new(None).expect("failed to create PipeWire main loop")));

    let ml = main_loop.clone();
    let _sig_int = main_loop.loop_().add_signal_local(Signal::INT, move || ml.quit());
    let ml = main_loop.clone();
    let _sig_term = main_loop.loop_().add_signal_local(Signal::TERM, move || ml.quit());

    let context = pw::context::ContextRc::new(main_loop, None).expect("failed to create PipeWire context");
    let core = context.connect_rc(None).expect("failed to connect to PipeWire");
    let registry = core.get_registry_rc().expect("failed to get PipeWire registry");

    let manager = Rc::new(RefCell::new(Manager::new(core.clone(), registry.clone(), dry_run)));

    // The debounce timer: (re)armed on every registry/metadata event, fires
    // `apply_routes()` once no further event has arrived for `DEBOUNCE`.
    let timer_manager = Rc::clone(&manager);
    let timer: Rc<pw::loop_::TimerSource<'static>> =
        Rc::new(main_loop.loop_().add_timer(move |_expirations| {
            timer_manager.borrow_mut().apply_routes();
        }));

    let registry_weak = registry.downgrade();
    let manager_for_global = Rc::clone(&manager);
    let timer_for_global = Rc::clone(&timer);
    let _registry_listener = registry
        .add_listener_local()
        .global(move |obj| {
            manager_for_global.borrow_mut().on_global(obj);

            // The "default" metadata object needs its own bound listener to
            // receive property (default sink) changes -- registry `global`
            // events alone don't carry metadata's internal key/value store.
            if obj.type_ == ObjectType::Metadata && prop(obj.props, "metadata.name") == Some("default") {
                if let Some(registry) = registry_weak.upgrade() {
                    if let Ok(metadata) = registry.bind::<pw::metadata::Metadata, _>(obj) {
                        let manager_for_prop = Rc::clone(&manager_for_global);
                        let timer_for_prop = Rc::clone(&timer_for_global);
                        let listener = metadata
                            .add_listener_local()
                            .property(move |_subject, key, _type, value| {
                                if key == Some("default.audio.sink") {
                                    let sink = value.and_then(extract_json_name);
                                    manager_for_prop.borrow_mut().default_sink = sink;
                                    let _ = timer_for_prop.update_timer(Some(DEBOUNCE), None);
                                }
                                0
                            })
                            .register();
                        let mut m = manager_for_global.borrow_mut();
                        m._default_metadata = Some(metadata);
                        m._default_metadata_listener = Some(listener);
                    }
                }
            }

            let _ = timer_for_global.update_timer(Some(DEBOUNCE), None);
        })
        .global_remove({
            let manager = Rc::clone(&manager);
            let timer = Rc::clone(&timer);
            move |id| {
                manager.borrow_mut().on_global_remove(id);
                let _ = timer.update_timer(Some(DEBOUNCE), None);
            }
        })
        .register();

    println!(
        "PipeWire Links Manager starting (event-driven, no polling){}...",
        if dry_run { " [DRY RUN -- no links will be created/destroyed]" } else { "" }
    );
    main_loop.run();

    // Deliberately no `pw::deinit()` here: this only returns after
    // `main_loop.quit()` (SIGINT/SIGTERM), and several live objects above
    // (`_sig_int`/`_sig_term`, `context`, `registry`, `manager`'s metadata
    // proxy+listener, `timer`, `_registry_listener`) still need to run their
    // Drop impls -- which make FFI calls back into PipeWire -- AFTER this
    // point, as `main` returns. Calling `deinit()` before that (as the
    // `pipewire` crate's own `pw-mon` example does, safely, only because
    // ITS pipewire objects are scoped to a function that returns before its
    // `main` calls `deinit()`) segfaults here on exactly that: a `SignalSource`
    // dropped after the library it calls back into was torn down. Simplest
    // correct fix for a long-running daemon that only ever exits via
    // process termination: let the OS reclaim everything instead.
}
