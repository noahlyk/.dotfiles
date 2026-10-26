# Sober + gamescope + MangoHud without losing FPS

Researched 2026-10-14. Setup: niri 26.04 + xwayland-satellite, RTX 5070, gamescope 3.16.31,
Sober 1.8.0 (flatpak, runtime org.gnome.Platform/51), MangoHud flatpak layer 25.08 + 26.08.
Claims are tagged with a source. Anything I could not confirm from a primary source is marked UNVERIFIED.
Local facts (from `flatpak info`, config files) are tagged [local].

## Summary (verdict)

1. The installed MangoHud pair is not a mismatch problem: GNOME 51 is built on freedesktop 26.08, so the
   **26.08** layer is the one Sober loads; 25.08 belongs to GNOME 50 and is just unused for Sober [local].
2. Nothing in Sober's docs, manifest or issue tracker endorses gamescope for Sober. The maintainer says
   MangoHud "is already supported, you just need to install the runtimes" (no gamescope needed). The only
   gamescope mention on Sober's tracker is a user listing it as a failed workaround, and one issue body
   describing it as a source of "performance issues or input lag".
3. gamescope upstream says plain MangoHud inside gamescope is unsupported and `--mangoapp` should be used. Stacking
   gamescope on top of a nested Sober (X11 inside gamescope's Xwayland, inside niri) adds a whole extra
   compositor + copy stage, and on NVIDIA nested mode cannot flip directly. That is the most likely cause of the FPS
   loss (inference, not documented).
4. Recommended: **drop gamescope for Sober**, run native Wayland (or X11 via xwayland-satellite as a fallback), and use only the MangoHud
   Vulkan layer (`MANGOHUD=1`) with a config in the sandbox config dir. Test order is at the bottom.

## 1. What Sober docs say about Wayland/X11, gamescope, MangoHud; why both sockets

- Flathub manifest finish-args: `--device=dri`, `--allow=devel`, `--share=ipc`, `--share=network`,
  `--socket=wayland`, `--socket=fallback-x11`, `--socket=pulseaudio`. The manifest's comments say ipc is shared "for X11
  performance" and that users "should try using Wayland where possible". Neither gamescope nor MangoHud
  appears in the manifest and it declares no extensions.
  Source: https://github.com/flathub/org.vinegarhq.Sober (org.vinegarhq.Sober.yml); installed metadata
  confirms the same sockets [local `flatpak info --show-permissions`].
- Why both: `wayland` is the preferred path, `fallback-x11` only gives X11 when there is no Wayland socket. That is the
  manifest design. Flatpak only binds the Wayland socket if WAYLAND_DISPLAY is set, which is why your
  `env -u WAYLAND_DISPLAY flatpak run` trick drops it to X11 (your own script comment, [local]
  /home/fib/.dotfiles/Scripts/gamelaunch). The claim that Sober shows "Permission Update Required" when a socket
  is removed is only recorded in your script comment: UNVERIFIED from any Sober doc.
- Troubleshooting page: "Use the Wayland session for your DE where possible"; HiDPI needs non-X11 ("X11 does not have
  support for HiDPI"); overriding the socket to X11 is "not recommended as it will mess up mouse positioning and speed".
  Source: https://raw.githubusercontent.com/vinegarhq/vinegarhq.github.io/main/src/Sober/Troubleshooting.md
  (rendered at https://vinegarhq.org/Sober/Troubleshooting.html).
- Docs on gamescope: nothing in Troubleshooting, FAQ, Configuration or Tips and Tricks. Docs on MangoHud: nothing either.
  Sources: same repo, src/Sober/FAQ/index.md, src/Sober/Configuration/{index,TipsAndTricks}.md.
- Sober homepage claims performance "the same or better than the Windows client" natively: https://sober.vinegarhq.org/

## 2. Known FPS / input / typing problems and fixes

- Typing in chat: no single documented root cause. #2207 "Game completely freezes when u type anything" was closed
  "Fixed in 1.7.1" by maintainer V3L0C1T13S (you are on 1.8.0, so that fix is included). https://github.com/vinegarhq/sober/issues/2207
  #1771 "Can't type, but can still use WASD" (Wayland, closed as stale, no fix; reporter notes forcing X11 crashed with a
  Chromebook-incompatible message). https://github.com/vinegarhq/sober/issues/1771
  Other threads: #973, #983, #960, #1683 (https://github.com/vinegarhq/sober/issues/973). No documented gamescope/niri-specific fix. UNVERIFIED whether your
  native-Wayland typing failure was the pre-1.7.1 bug or a niri text-input/IME interaction. Retest on 1.8.0 first.
- FPS throttled while focused (KDE Wayland): #2027, 16 FPS focused / 60 unfocused, open, reporter tried gamescope,
  X11 override, SDL_VIDEODRIVER=x11 and FFlag DFIntTaskSchedulerTargetFpsBackground=0 with no success.
  https://github.com/vinegarhq/sober/issues/2027 . Related: #1916 lower FPS unfocused, #2202 low FPS, #2156 low FPS, #2092 random drops,
  #2289 lag spikes (all open). Takeaway: Sober ties its frame pacing to window focus; any compositor/nesting arrangement
  that confuses focus (nested gamescope window, xwayland-satellite) can hit this. This is inference from #2027; not confirmed for niri.
- MangoHud on Sober: #2153 (closed) maintainer: "Mangohud and VkBasalt are already supported, you just need to install the
  runtimes for them." https://github.com/vinegarhq/sober/issues/2153 . #2018 (closed): a user got it working via Flatseal env
  `MANGOHUD=1` plus the Vulkan layer; another said it "never worked"; the reporter says gamescope as workaround can cause
  "performance issues or input lag". https://github.com/vinegarhq/sober/issues/2018
- No Sober issue I found documents a working gamescope setup with xwayland-satellite. UNVERIFIED either way.

## 3. MangoHud extension branch vs GNOME 51; enabling the layer

- GNOME 51 runtime metadata declares `[Extension org.freedesktop.Platform.VulkanLayer] version = 26.08`
  (GNOME 50 declares 25.08) [local `flatpak info --show-metadata org.gnome.Platform//51` and `//50`].
  The MangoHud 26.08 extension is `[ExtensionOf] runtime/org.freedesktop.Platform/x86_64/26.08` [local].
  Flatpak docs: the extension "version must match the base runtime version" (freedesktop base) and the extension is
  auto-mounted only if the matching branch is installed. https://docs.flatpak.org/en/latest/extension.html
  => 26.08 is the correct one for Sober; 25.08 is harmless/unused. Not a mismatch, no action needed.
  (Mounted extensions can be checked in a running sandbox: `app-extensions`/`runtime-extensions` in /.flatpak-info, per the same doc.)
- Enabling: `MANGOHUD=1` in the app's environment; MangoHud README says this works for Vulkan; Steam example
  `flatpak override --user --env=MANGOHUD=1 com.valvesoftware.Steam`. https://github.com/flightlessmango/MangoHud (README, Flatpak section)
  For Sober: `flatpak run --env=MANGOHUD=1 org.vinegarhq.Sober` (your gamelaunch already does this in non-scope mode).
- Config path inside the sandbox: README gives no flatpak-specific path (it only notes `MANGOHUD_PRESETSFILE` is useful in a
  sandbox, and `MANGOHUD_CONFIGFILE` selects a file). The Sober thread #2018 says to put the config in Sober's flatpak config
  dir under MangoHud. The standard XDG location is `~/.var/app/org.vinegarhq.Sober/config/MangoHud/MangoHud.conf`
  (XDG_CONFIG_HOME inside the sandbox); that mapping is standard flatpak behavior but I did not find a primary doc line: treat as UNVERIFIED until you
  check. [local] that dir does not exist today, and the host ~/.config/MangoHud is not visible in the sandbox, so Sober currently gets
  MangoHud default (large) HUD settings.
- HUD cost knob: MangoHud `fps_limit_method` is `late` (default, lowest latency) or `early`; Vulkan `vsync`/`vulkan_present_mode`
  override the present mode, so leave both unset to avoid changing Roblox's present behavior. README (link above).
  `throttling_status` is "disabled by default for Nvidia as it causes lag on 3000 series" so keep it off.

## 4. `gamescope -- flatpak run ...` vs gamescope inside the sandbox

- Wrapping from the host is the only practical way (gamescope is not in the Sober runtime; Flathub manifest has no gamescope).
  Upstream does not document flatpak. README only says gamescope can run nested on a desktop "in its own Xwayland sandbox".
  https://github.com/ValveSoftware/gamescope (README)
- Consequence (inference from the above, UNVERIFIED by a benchmark): `flatpak run` inherits DISPLAY=gamescope's Xwayland. Sober runs
  as an X11 client, its Vulkan swapchain is presented through X11 (DRI3/Present) to gamescope, gamescope composites it via its own Vulkan
  and then hands a frame to niri as a Wayland client. That is two compositors and an extra full-frame copy, and
  gamescope's WSI layer is not inside the flatpak sandbox (UNVERIFIED), so no direct swapchain path. Compare native Wayland: swapchain presents directly to niri.
- `--mangoapp` vs layer: gamescope's own help says of `--mangoapp`: "You should use this instead of using mangohud on the game or
  gamescope." MangoHud README: "Using normal mangohud with gamescope is not supported." So with gamescope use `--mangoapp` only (your script already
  avoids stacking). Note gamescope issue #1724 reports mangoapp affecting adaptive-sync refresh (AMD). https://github.com/ValveSoftware/gamescope/issues/1724
  Conversely, without gamescope the Vulkan layer is the supported route.
- Sober forced to X11 also loses HiDPI (docs above) and may break mouse positioning (docs above): relevant to your `enable_hidpi: true`.

## 5. NVIDIA specifics for gamescope

- README: NVIDIA proprietary driver >= 515.43.04 and `nvidia-drm.modeset=1`; nested vs DRM: nested runs on the desktop, DRM/KMS direct flipping is
  only for embedded sessions. Under niri you are always nested, so gamescope cannot direct-flip. https://github.com/ValveSoftware/gamescope
- `gamescope --help` on this machine [local, 3.16.31]: `--immediate-flips` "may result in tearing" (only meaningful with DRM backend: UNVERIFIED for nested);
  `--adaptive-sync` "Enable adaptive sync if available"; `--rt` "Use realtime scheduling"; `-r` = nested refresh (game refresh rate);
  `-o` = unfocused refresh; `--framerate-limit` divisor of refresh; `--force-grab-cursor`; `--expose-wayland`; `--backend`;
  `--prefer-vk-device`.
- `--rt` without CAP_SYS_NICE: `getcap $(which gamescope)` printed nothing [local], i.e. the capability is not set, so `--rt` cannot raise priority
  (gamescope would warn and carry on; exact failure behavior UNVERIFIED in primary docs). Skip `--rt`; niri/priority-run.sh already handles priority.
- Open NVIDIA issues: #1617 VRR jumping to max (Wayland, HDR), #760 immediate-flips tearing only in -b not -f, #995 immediate flips X11, #490 (closed) NVIDIA 30 FPS cap vs `-r`,
  #2455 RTX 5070 artifacts on 3.16.31 vs 3.16.25 (DRM). https://github.com/ValveSoftware/gamescope/issues/2455 ,
  https://github.com/ValveSoftware/gamescope/issues/760 , https://github.com/ValveSoftware/gamescope/issues/490
- `-r 319.998` oddity: the number is just niri's reported fractional refresh from `niri msg focused-output` parsed by your script [local]. No primary
  source on why it matters; UNVERIFIED. Use an integer (e.g. `-r 320` or lower than the display) and `--framerate-limit`/in-game cap rather than the odd fractional mode.
- Worth it for Sober? No evidence of benefit: Sober already has a native Wayland path, gamescope only adds scaling/FSR/NIS and a HUD. Use it only if you need
  FSR/NIS upscaling or forced cursor grab.

## 6. Sober config.json perf options

From https://vinegarhq.org/Sober/Configuration/index.html (defaults per docs) and your file [local]:
- `graphics_optimization_mode`: "quality" | "balanced" (default) | "performance" (max speed, lower LOD/texture quality). You: balanced.
- `use_opengl`: false = Vulkan (default). OpenGL is a workaround for e.g. OutOfMemory crashes; MangoHud Vulkan layer needs Vulkan (#2018 comment). Keep false.
- `enable_hidpi`: default false; scales Sober's window to pixel density; you have true; docs say X11 lacks HiDPI, so it only helps in native Wayland.
- `enable_gamemode`: default true; you have true. Note gamemoded must be reachable from the sandbox (UNVERIFIED).
- `fflags`: docs say "Experimental ... We don't recommend or support using this." and since September 2025 FFlags are allowlist-only: flags off the allowlist
  "will be ignored even if configured correctly". https://raw.githubusercontent.com/vinegarhq/vinegarhq.github.io/main/src/Sober/Configuration/TipsAndTricks.md
  Whether `FramerateCap` / `DFIntTaskSchedulerTargetFps` are on the allowlist: UNVERIFIED (not stated in the pages I could read; the tables there were large and I did not
  fully read them). Your config has only the placeholder `FFlagExample`. #1873 notes the in-game cap is 240 and the workaround is FFlags.
  For the rendering prefer-Vulkan/OpenGL flags the docs recommend `flatpak run org.vinegarhq.Sober config` -> "Force Legacy Rendering" instead.
- #2202 mentions FramerateCap 5000 in the XML; #2027 lists `GlobalBasicSettings_13.xml` FramerateCap -1 (unlimited). Check Roblox in-game graphics FPS cap if you see a cap.

## Recommended gamelaunch setup for Sober

Current gamelaunch `sober)` preset is commented out [local]. Suggested contents (do not apply blindly):

```
sober)
  FLATPAK_APP_ID="org.vinegarhq.Sober"
  USE_SCOPE=0          # no gamescope
  HUD_MODE="default"   # -> MANGOHUD=1 via existing FP_CMD block
  FLATPAK_X11=0        # native Wayland; use --x11 only as fallback
  ;;
```

Extra bits:
- Create `~/.var/app/org.vinegarhq.Sober/config/MangoHud/MangoHud.conf` with your small HUD (copy ~/.config/MangoHud/MangoHud.conf; avoid `vsync`, `fps_limit`,
  `vulkan_present_mode`, `throttling_status`). Optionally `flatpak run --env=MANGOHUD_CONFIGFILE=...` if the path assumption fails.
- Pin the layer branch if you want certainty: nothing to do, 26.08 auto-matches. You can remove 25.08 later if nothing else needs it.
- config.json: keep `use_opengl:false`, `graphics_optimization_mode` "balanced" or "performance" if GPU-bound, leave hidpi true on Wayland (set false on the X11 fallback).
- Do not pass `--rt` (no CAP_SYS_NICE), skip `--immediate-flips`; the `-r 319.998` should be an integer if gamescope is used at all.

Fallback order to test (measure with the MangoHud fps counter or Roblox's own, same server/place, 2 min each):
- **A. MangoHud layer only, native Wayland, no gamescope** (`MANGOHUD=1`, FLATPAK_X11=0). If typing in chat fails here, try A2: same but `--x11`
  (`env -u WAYLAND_DISPLAY`, goes via xwayland-satellite; expect HiDPI off and possible mouse quirks per the docs).
- **A0. Baseline: no HUD, no gamescope** to see whether the layer itself costs FPS. If A0 is much faster than A, MangoHud is the problem (try toggling off heavy options like gpu_stats/ram/frame_timing).
- **B. gamescope without HUD** (`--no-hud`, USE_SCOPE=1, no `--rt`, integer `-r`). If B is slow while A0 is fast, nested gamescope is the cause.
- **C. gamescope + `--mangoapp`** (never both mangoapp and the layer). Expected worst case.
Pick the fastest configuration that still lets you type in chat.
