# nam-zig: Neural Amp Modeler in Zig

A CPU-first port of the [Neural Amp Modeler](https://github.com/sdatkinson/neural-amp-modeler)
ecosystem, written in Zig on the [Fucina](https://github.com/matteo-grella/fucina) tensor
library: load and play `.nam` amp profiles live (optionally with cabinet IRs and
multi-stage signal chains), create your own profiles from captured audio, and exchange
profiles with the original NAM tooling in both directions. No plugin host or DAW is
required: it runs against your normal audio devices, from a window or from the terminal.

## Install

Download the build for your platform from the
[releases page](https://github.com/matteo-grella/nam-zig/releases) and unzip it.

| Platform | What you get | How to start |
| --- | --- | --- |
| macOS (Apple Silicon or Intel) | `nam-zig.app` plus the command-line binary in `bin/` | Double-click `nam-zig.app`. The first time, macOS may say the app is from an unidentified developer: open System Settings, Privacy & Security, scroll down and choose Open Anyway. |
| Linux (x86_64, aarch64) | the `nam-zig` binary | Run `./nam-zig`. The window needs GTK 3 and WebKitGTK (present on most desktops); without them the page opens in your browser. |
| Windows (x86_64) | `nam-zig.exe` | Run `nam-zig.exe`; the page opens in your browser. |

The app needs permission to use the microphone (that is how it hears your guitar
interface): allow it when asked. Nothing else is installed; everything lives in the
folder described below.

## First run

1. **Open the app.** A window appears and a folder named `nam-zig` is created inside
   your `Music` folder, with a `profiles` subfolder. Press **Open folder** to see it.
2. **Get a profile.** Download any `.nam` file: [Tone3000](https://www.tone3000.com)
   hosts thousands of free ones (they are almost all "standard WaveNet", which this player
   runs at full fidelity). A profile made with the official NAM trainer works too.
   Tone3000 also hosts cabinet IRs (`.wav`).
3. **Drop the files in `profiles`** and press **Rescan**. Every `.nam` in the folder
   becomes an entry in the list; `.wav` cabinet IRs and `.chain` manifests (see
   [Cabinet IRs and signal chains](#cabinet-irs-and-signal-chains)) are picked up too.
4. **Pick your input and output** in the Devices section (the audio interface your guitar
   is plugged into; see [Hardware](#hardware-what-plugs-into-what) for how to connect it),
   or press **Auto-detect input** and keep playing: it listens to every input for a
   moment and picks the one carrying your guitar.
5. **Play.** Click a profile to switch amps. The knobs: input drive (how hard you hit the
   amp, which changes the tone), output gain, a noise gate with its threshold, loudness
   normalization across profiles, bypass, mute, and a chromatic tuner.

Your device choice, profile, and knob positions are saved in `nam-zig/config.txt` and
restored next time. `nam-zig doctor` (from a terminal) checks the folder, the microphone
permission, the devices, and plays a test tone; `nam-zig open` opens the folder.

If you hear nothing: on macOS a denied microphone permission yields silence with no error;
allow nam-zig (or, for the terminal commands, your terminal app) in System Settings,
Privacy & Security, Microphone. Monitor through headphones or speakers on the same
interface you capture with: one device means one sample clock.

## Capture your own amp

`nam-zig profile` plays the standardized capture signal through your rig, records what
comes back, trains a profile, and saves it into your `profiles` folder. The capture signal
(`v3_0_0.wav`) is downloaded once into the `nam-zig` folder, checksum verified. See
[Profiling an amp or pedal](#profiling-an-amp-or-pedal-profile--train) for the wiring and
the command.

## Built on Fucina

The engines are [Fucina](https://github.com/matteo-grella/fucina) tensor programs: the
WaveNet streams through Fucina's streaming causal convolutions, the LSTM through its LSTM
sequence op, and training runs on its autograd engine and optimizers, so one model
definition both trains and plays. `build.zig.zon` pins the Fucina release; `zig build`
fetches it.

## Build from source

**Prerequisites:** [Zig 0.16.0](https://ziglang.org/download/) and git. Developed and
tested on macOS / Apple Silicon; Linux and Windows build and pass the test suite in CI
(live audio there is exercised by users, not by CI). The Fucina dependency is fetched by
the Zig package manager at build time (pinned by tag and content hash in `build.zig.zon`);
there are no other dependencies.

```sh
git clone https://github.com/matteo-grella/nam-zig && cd nam-zig
zig build -Doptimize=ReleaseFast        # builds zig-out/bin/nam-zig
zig build app -Doptimize=ReleaseFast    # macOS: also assembles zig-out/nam-zig.app
```

`-Doptimize=ReleaseFast` matters: debug builds are ~20× slower and will not keep up in
realtime. You can run every command either through the build runner
(`zig build run -Doptimize=ReleaseFast -- <command>`) or by calling the built binary
directly (`zig-out/bin/nam-zig <command>`); the examples below use the short form.
`zig build test` runs the unit tests, and `-Dblas=none` builds without any system BLAS
library (Fucina links Accelerate on macOS by default).

## The terminal player

`nam-zig gui` opens the window from a terminal (`--no-window` serves the page to your
browser instead, `--port N` picks the port). With no command, `nam-zig` in a terminal
shows a numbered amp menu over the profiles in your folder (and in a `nam-profiles` or
`models` folder next to the binary); pick one, keep playing while it auto-detects the
input, and you're live. Everything below is the manual/expert path through `live`.

1. **Get a profile** as above; add a cabinet IR with `--ir` (see
   [Cabinet IRs and signal chains](#cabinet-irs-and-signal-chains)).
2. **Find your audio interface:**
   ```sh
   nam-zig devices
   ```
   Note the index of your interface in *both* the capture and playback lists.
3. **Plug in and play** (see [Hardware](#hardware-what-plugs-into-what) below for how to
   connect the guitar):
   ```sh
   nam-zig live my-amp.nam --capture 2 --playback 2
   ```
   You should hear the processed guitar immediately. Keys: `space` bypass · `[` `]` or
   `1`–`9` switch profile/chain (pass several `.nam` files to A/B them, or build chains;
   see [Cabinet IRs and signal chains](#cabinet-irs-and-signal-chains)) · `a` auto-detect the
   input · `i` / `o` cycle the input / output device live (the status line names the
   active pair) · `,`/`.` input gain (how hard you drive the model, which changes the
   *tone*, not just volume) · `+`/`-` output gain · `t` tuner · `m` mute the output
   (processing keeps streaming, so unmute is click-free) · `n` toggle loudness
   normalization · `c` clear the clip indicator · `q` quit. A MIDI controller drives the
   same knobs; see [MIDI control](#midi-control).

   **Built-in tuner** (`t`, or start with `--tuner`): a strobe-class chromatic tuner runs
   on its own analysis thread off the raw input; the realtime model chain is never
   touched. Pluck one string for the needle (note, cents to one decimal, Hz; McLeod
   pitch detection + per-partial spectral refinement with inharmonicity fitting,
   measured well under 0.1 cent on stable tones); strum all strings and the row switches
   to a per-string readout (`E A D G B e`, standard tuning, cents each, ±120-cent
   capture range). `--a4 432` moves the reference (400–480 Hz). The tuner reads the raw
   input (pre-trim, pre-model), so it works identically live, bypassed, or with the
   output muted; `t` + `m` is the classic silent-tuning pedal move.

   **Not sure which input?** Start with `--auto-input` (or press `a` anytime) and keep
   playing: it records ~1.5 s from every capture device, measures signal vs noise floor,
   and picks the cleanest source: a direct interface/DI input wins over a microphone
   hearing the same guitar acoustically (its floor between notes is near-silent).
   Virtual devices (Teams, Zoom, VB-Cable, BlackHole, Camo, aggregates, loopbacks) are
   never candidates; devices that exist in both the capture *and* playback lists are
   tagged `[interface]` and an interface carrying any meaningful signal beats every
   microphone outright (even a weak under-gained one; you'll get a note to raise the
   interface's gain). USB interfaces often enumerate under generic names like "Audio
   Out" or "USB Audio CODEC"; the `[interface]` tag is how you spot yours. If nothing
   carries signal it keeps the current input. When the winner is a full interface, its playback side is
   adopted as the output automatically (one clock, no drift), or, if you had explicitly
   chosen an output, offered as a one-key suggestion (`y` to accept). Otherwise: if the
   `in` meter stays at −140 dB while you play, press `i` to cycle inputs; if `in` moves
   but you hear nothing, cycle the output with `o`.

## Hardware: what plugs into what

The two flows have different wiring needs. The golden rule: a guitar pickup is a weak,
high-impedance *instrument-level* signal; interface line outputs are strong, low-impedance
*line-level* signals. Mismatching them won't break anything (with one exception below), but
it will skew the sound, and for profiling a skewed capture becomes a permanently skewed
profile.

### Playing live (guitar → interface → nam-zig → speakers)

| Your setup | What to do |
| --- | --- |
| Interface has a **Hi-Z / "Inst" input** (most do: Scarlett, Volt, UR, MOTU...) | Plug the guitar straight in and engage the Inst/Hi-Z switch. **No extra gear needed.** |
| Only mic/line inputs, passive pickups | Put a **DI box** (or any buffered pedal; a tuner pedal works) between guitar and interface. Plugging a passive guitar into a low-impedance line input loses treble and level. |
| Active pickups, or a buffered pedalboard in front | Direct into a line input is fine: the buffer already did the impedance work. |

Set the interface's input gain so your hardest playing peaks around −12…−6 dBFS on the
`live` input meter (never hitting `CLIP!`); fine-tune the drive into the model with the
`,`/`.` input-trim keys (or `--input-gain dB`): NAM models are nonlinear, so input level
controls breakup, not just loudness.

**If everything sounds too quiet:** profiles have wildly different built-in output levels.
`live` normalizes them to −18 dBFS by default using each profile's loudness metadata
(status shows `NORM`; toggle with `n` or start with `--no-normalize` for the raw upstream-core
behavior), and `+`/`-` adds up to 24 dB of clean output gain on top. If the *input* meter is
the quiet one, raise the interface gain / input trim instead; boosting output can't recover
a starved model. Monitor through headphones/speakers on the **same interface**
you capture with: one device means one sample clock, and a different output device will
click every couple of minutes (the two clocks drift apart).

### Profiling an amp or pedal (`profile` / `train`)

Two cable runs at once: the capture signal goes **out** of the interface into your gear, and
the gear's output comes **back in**:

```
interface line OUT ──(reamp box)──> amp/pedal input
amp/pedal output  ──(see table)──> interface IN
```

**The send side: do you need a reamp box?**

| Target | Recommendation |
| --- | --- |
| Tube/solid-state **amp input** or **pedal** | Use a **reamp box** (e.g. Radial ProRMP). It converts line level → instrument level and impedance, and its ground lift kills hum loops. The amp's input stage reacts to level and impedance, and the profile bakes in whatever it sees; going direct with the interface output turned down can work, but the capture may not match how the amp feels with a guitar, and ground hum contaminates the training data. |
| **Digital gear** (another modeler, a plugin chain, a rack unit with line input) | Direct line-to-line is fine. No reamp box needed. |

**The return side: how to get the amp's output back.**

| Source | Connection |
| --- | --- |
| Amp's **line out / DI out / emulated out** | Straight into a line input. Captures preamp (+ power amp on some outs) without the cab; pick `--gear-type amp` and add a cab IR at playback with `--ir` (see [Cabinet IRs and signal chains](#cabinet-irs-and-signal-chains)). |
| **Mic on the cab** | Mic input with preamp gain. The profile then includes cab + mic (`--gear-type amp_cab`) and needs no IR afterwards (`live` warns if you add a redundant one). |
| **Speaker output** of an amp | **Never into a line input directly**: speaker-level signals are tens of volts and will damage the interface. Use a **load box / reactive attenuator with a DI out** (Captor, Suhr RL, ...). And remember: a tube amp must always see a speaker or load. |

Levels: aim for healthy peaks around −6 dBFS on the return; the trainer refuses clipped
captures (`|y| ≥ 1.0`, same as upstream). Keep all knobs untouched between the latency blips
at the start of the capture file and the end; drift fails the data checks.

### The capture run itself

Use the standardized **v3 capture file** (`v3_0_0.wav`, the same "input file" download the
official NAM trainer uses). It is recognized by checksum and enables automatic latency
calibration (from its blips) and the quality pre-checks. Then:

```sh
nam-zig profile --capture 2 --playback 2 --name "My Amp" --gear-type amp --tone-type crunch
```

downloads the capture signal on first use (into the `nam-zig` folder), plays it through
your rig, records the return under `captures/`, and trains; the profile lands in
`profiles/` as `My-Amp.nam`, where the window lists it. `--signal`, `--reamp-out`, and
`--out` override those paths. Alternatively
record the reamp in your DAW and run the two-step version:
`nam-zig train --input v3_0_0.wav --output reamp.wav --out my-amp.nam`. Any other
48 kHz input/output pair also works (pass `--latency` if your interface loopback delay is
known; the last 9 s become the validation split).

Training defaults to the classic "standard" WaveNet (13,802 weights), matching the upstream
Python full config. `--spec a2`/`--spec a2-standard` selects the C++ reference A2-standard
shape (8 channels); `--spec a2-nano` selects the 3-channel A2-nano shape. `--spec lstm`
trains the upstream LSTM (hidden 24, one layer, learned initial state, 4096-sample
burn-in without gradient, 512-step truncated backpropagation) and exports
`"architecture": "LSTM"`. `--spec packed`
selects the current upstream PackedWaveNet easy-mode recipe: channels-3 and channels-8 A2
submodels, summed submodel losses, MRSTFT weight 0.0005, Adam weight decay 3.17e-7,
gamma=0.994, 100 default epochs, and `SlimmableContainer` export. `--init model.nam`
fine-tunes a supported WaveNet profile through the same loop, including recursive WaveNet
`condition_dsp` weights. The classic/A2 optimizer recipe is MSE, Adam lr 0.004, gamma=0.993,
batch 16, 100 epochs (`--epochs 20` is useful for quick CPU smoke runs).
Each epoch prints the validation ESR with the upstream quality bands: **< 0.01 "Great!"**,
< 0.035 "Not bad!". The best epoch is exported with the full upstream metadata schema (date,
measured loudness/gain, your `--name`/`--gear-*`/`--tone-type` fields, latency calibration
record, final ESR). Check the result by ear with:

```sh
nam-zig validate my-amp.nam --input v3_0_0.wav --output reamp.wav --write-wavs ab/
```

(writes `validation_target.wav` = the real amp and `validation_model.wav` = the profile,
time-aligned for A/B listening), then play it: `nam-zig live my-amp.nam ...`.

## MIDI control

Every live control is also a MIDI control. `live` listens to **all** connected MIDI
sources by default, and hot-plug works: source *identity* is rescanned every ~2 s, so you
can turn the pedalboard on after the player is already running (or swap one controller for
another). A footswitch, expression pedal, or
controller knob works out of the box with these defaults (GM conventions where one exists):

| MIDI message | Control | Mapping |
| --- | --- | --- |
| CC 7 (volume) | output gain | 0–127 → −40…+24 dB |
| CC 11 (expression) | input trim (drive) | 0–127 → −20…+40 dB |
| CC 1 (mod wheel) | gate threshold | 0–127 → −90…−30 dB |
| CC 64 (sustain) | bypass | ≥ 64 = bypassed |
| CC 80 | noise gate on/off | ≥ 64 = on |
| CC 81 | loudness normalization | ≥ 64 = on |
| CC 85 | output mute | ≥ 64 = muted |
| Program change | profile/chain slot | PC 0 = slot 1 |

The status line echoes each applied event for ~1.5 s (`[MIDI CC7=93]`), so you can see a
controller reach the right knob. Continuous CCs sweep the same dB ranges the keyboard keys
step through, linear in dB.

Options: `--midi N` listens to one source only (`devices` lists them with indices),
`--no-midi` disables MIDI, `--midi-channel 1-16` reacts to one channel (default: omni),
and `--midi-map` reassigns CC numbers, e.g. `--midi-map out-gain=20,bypass=82`
(names: `out-gain`, `in-gain`, `gate-threshold`, `bypass`, `gate`, `normalize`;
unmentioned controls keep their defaults, and two controls landing on one CC (including
against an unmentioned control's default) are rejected at startup). MIDI is macOS-only
(CoreMIDI); other platforms have keyboard control.

## Cabinet IRs and signal chains

A `.nam` capture of an amp head or preamp has no speaker: pair it with a **cabinet
impulse response** (a mono `.wav`). And you can run several stages in series, e.g. a
drive pedal into an amp into a cab, as a **chain**.

### Add a cab IR

```sh
nam-zig live amp.nam --ir cab.wav --capture 2 --playback 2
```

`--ir` appends the cab after the model (`amp → cab → output`), as in the NAM plugin. The
stage behaves like the upstream `ImpulseResponse`: direct time-domain convolution, mono,
up to 8192 taps, a fixed −18 dB headroom gain (use `+` output gain if the cab makes
things quiet). The IR is **resampled** to the session rate at load when it differs
(cubic, as upstream), so a 44.1 kHz cab works
in a 48 kHz session, unlike `.nam` models, which are nonlinear and must match the stream
rate. `--ir` also works for offline `render`.

### Build a chain

A `.chain` file is a text manifest, one stage per line, top → bottom = signal flow:

```
# pedal -> amp -> cab
name: My Rig                       # optional; shown in the status line
boost.nam :: trim=+3               # a drive capture, hit +3 dB harder
amp.nam                            # no trim = unity
cab.wav :: trim=-2                 # cabinet IR, pulled back 2 dB
```

```sh
nam-zig live --chain rig.chain --capture 2 --playback 2
```

- A stage is a `.nam`/`.gguf` model or a `.wav` cab IR (chosen by file extension).
- `:: trim=<dB>` is an optional per-stage input trim (the level *into* a stage shapes its
  breakup, not just its volume). The ` :: ` is a literal
  space-colon-colon-space, so paths with spaces work; trims aren't live-adjustable.
- `name:` is optional (first one wins); without it the chain is named after the file. `#`
  starts a comment only as the first non-space character (so `Marshall #2.nam` is a path).
  Paths are relative to where you run the command.

Pass several `--chain rig1.chain --chain rig2.chain` and/or bare `.nam` profiles together
and switch between them live with `[` `]`, `1`–`9`, or MIDI Program Change; the status
line shows the active chain plus an `x3` tag for its stage count. A bare profile is just a
one-stage chain, so plain `live a.nam b.nam` A/B works as before; `--ir` then appends a cab
to **each** bare profile (with manifests only it has nothing to attach to and is ignored;
put the cab in the manifest instead).

### Cab advice from `gear_type`

If a capture carries a `gear_type` (the trainer writes it; see `--gear-type` above), `live`
checks each chain at load and prints a non-fatal note, both ways:

- **redundant cab**: a cab IR following a capture that already includes a speaker
  (`amp_cab`, `amp_pedal_cab`, `studio`, or a Tone3000 "full rig"): the doubled cab sounds
  dull/boxy.
- **cab likely needed**: a chain ending in an `amp`/`preamp`/`pedal_amp` capture with no
  cab after it.

Captures with no `gear_type`, and pedal-only chains, are left alone.

## All commands

| Command | What it does |
| --- | --- |
| `gui [--port N] [--no-window] [--no-open] [--period N]` | The window over the profiles in your `nam-zig` folder (the default when launched from the desktop). |
| `doctor [--no-tone] [--download]` | Check the folder, the capture signal (`--download` fetches it), the microphone permission, devices, and play a test tone. |
| `open` | Open the `nam-zig` folder in the file manager. |
| `devices` | List capture/playback devices and MIDI sources with indices. |
| `live [<profile>...] [--ir cab.wav] [--chain rig.chain] [--capture N] [--playback N] [--rate 48000] [--period 128] [--tuner] [--a4 440] [--midi N \| --no-midi] [--midi-channel C] [--midi-map ...]` | Play through profiles and/or chains (see [Cabinet IRs and signal chains](#cabinet-irs-and-signal-chains)). |
| `profile [--signal s.wav] [--reamp-out r.wav] [--out m.nam] [...]` | One-step capture + train + export; the defaults download the capture signal and save into the `nam-zig` folder. |
| `train --input in.wav --output reamp.wav --out m.nam [...]` | Train from an existing pair. |
| `validate <model> --input in.wav --output reamp.wav [--write-wavs dir]` | ESR + A/B WAVs. |
| `inspect <model.nam\|.gguf>` | Print structure + metadata. |
| `render <model> <in.wav> <out.wav> [--blocksize N] [--ir cab.wav]` | Offline file processing (matches upstream `tools/render`; `--ir` appends a cab). |
| `bench <model> [--blocksize N]` | Per-block cost vs the realtime budget. |
| `bench --train-step <spec> [--ny N]` | One training step (segment loss + backward) at the trainer's window shape. |
| `list [--profiles-dir d]` | The profiles in your `nam-zig` folder (or another directory). |
| `export-gguf` / `import-gguf` | Lossless GGUF interchange (byte-identical `.nam` recovery). |

## Compatibility guarantees

- **Import:** any upstream-tooling `.nam` of architecture WaveNet (incl. gated/blended,
  grouped convs, active FiLMs, WaveNet `condition_dsp`, and every legacy config spelling),
  LSTM, ConvNet, Linear, and `SlimmableContainer` (the current upstream trainer's export,
  loaded at its highest-quality submodel, the one players use by default). Slimmable WaveNet
  submodels and non-WaveNet `condition_dsp` engines fail with a named error in the trainable
  WaveNet path.
- **Export:** `.nam` v0.7.0 in the modern upstream exporter shape; WaveNet exports and packed
  `SlimmableContainer` exports both load in upstream `NeuralAmpModelerCore` (`loadmodel`).
  Rendering through the upstream core matches nam-zig (6.7e-8 max on a trained classic profile;
  2.7e-8 max on a packed-container smoke). Profiles made here work in any NAM player that
  supports the exported architecture.
- **Numeric parity:** vs upstream `tools/render` on the upstream example models: standard
  WaveNet max |diff| 2.3e-6 / RMS 6.5e-8 (about 20× inside upstream's own 5e-5
  cross-implementation tolerance). Tanh matches the scalar libm contract of the upstream
  C++ runtime to ≤ 1.9 ulp (9.5e-8 abs). Output is deterministic across machines and
  byte-identical across block sizes.
- **Performance:** standard WaveNet (13,802 weights) 72 µs per 64-frame block at
  48 kHz on one core, 18× the 1333 µs realtime budget; 480 µs per 512-frame block
  (22×). A 23-layer, 8-channel Tone3000 profile (12,146 weights) runs at 57 µs per
  64-frame block. ReleaseFast, Apple M1 Max, 2026-09-09 snapshot;
  `bench <model> --blocksize N` prints the same report for any profile.
- **GGUF:** an optional, lossless container: the original `.nam` JSON rides byte-verbatim in
  the `nam.file_json` KV next to a flat `nam.weights` f32 tensor, so `import-gguf` recovers a
  byte-identical `.nam`. The runtime loads `.nam` directly. The GGUF form is f32 only;
  there is no quantized form.

## Latency, buffers, sample rate

- `live` prints an end-to-end latency estimate at startup, read from CoreAudio:
  `input device + duplex+period + output device`. The duplex+period term is ≈ 3·period
  (miniaudio's duplex ring keeps ~2 capture periods of slack); the device terms are
  per-stream latency + device latency + safety offset + negotiated buffer. Default
  `--period 64` ⇒ 4 ms for the middle term; `--period 32` halves it if your interface is
  stable there.
- **The devices dominate.** A proper USB interface contributes ~1–3 ms per side (total
  ≈ 7–10 ms). Good interfaces (MOTU M2 class) accept
  `--period 16` for ~8 ms total at 48 kHz; if you hear crackles under load, step back to
  32. Built-in mic/speakers ≈ 11 ms total.
  **Avoid for monitoring:** HDMI/DisplayPort monitor speakers (the display adds internal
  buffering CoreAudio cannot even report, often tens of ms on top of the ~10 ms it does
  report), Bluetooth anything (100+ ms), webcam microphones. Guitar feel reference: ≤10 ms
  reads as immediate (standing 3 m from your amp is ~9 ms of air), ~15–20 ms feels laggy,
  30+ is unplayable.
- Devices not natively at 48 kHz are **retuned to 48 kHz at the OS level for the session**.
  If retuning fails, `live` prints a resample warning; set the device rate in Audio MIDI
  Setup. The device's own blocks reach the engine directly, with no intermediate
  re-buffering.
- The latency estimate uses the device's **negotiated** buffer size, not the requested one;
  a driver that refuses small buffers triggers a warning with the real cost (lower its
  buffer in the vendor's control panel if it has one).
- `loopback-test --capture N --playback N` measures the true software round-trip by sending
  impulses and timing their return. Run it on your interface with a physical patch cable
  (line out → line in) for ground truth on your exact rig.
- The audio callback is allocation-free and lock-free; all chains (and their stages) are
  preloaded and prewarmed, so switching mid-playing doesn't glitch.

## Test plan (beyond `zig build test`)

1. **Golden parity:** build upstream `render` (`cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
   -DNAM_ENABLE_A2_FAST=OFF` in `refs/NeuralAmpModelerCore` after `git submodule update --init`),
   render the example models over a test WAV with both renderers, compare (gate: 1e-5 RMS).
2. **Trained-profile interop:** `train` on any pair → upstream `loadmodel` accepts the export →
   upstream `render` matches ours. Python re-import oracle (needs torch):
   `pip install -e refs/neural-amp-modeler` then
   `python -c "import json,nam.models; nam.models.init_from_nam(json.load(open('model.nam')))"`.
3. **GGUF round-trip:** `export-gguf` → `import-gguf` → `cmp` byte-identical; render both.
4. **Realtime:** `bench` per block size; `live` loopback (e.g. a virtual cable) for the
   stream/HUD; a real-interface session for latency/dropout listening.
5. **Capture flow:** `profile` against a loopback (signal ≈ reamp ⇒ near-zero ESR) before
   using a real amp.
6. **Cab IR + chains:** `render amp.nam in.wav out.wav --ir cab.wav` (A/B with and without
   the cab); `live --chain rig.chain` to hear a multi-stage rig and see the per-chain gear
   advisories printed at load.

Module layout is described in the module doc comments of `src/*.zig`.

## The nam-zig folder

Everything the app keeps is in one folder: `Music/nam-zig` in your home directory
(`NAM_ZIG_HOME` overrides the location).

| Path | Content |
| --- | --- |
| `profiles/` | your `.nam` profiles, cabinet IR `.wav` files, and `.chain` manifests (subfolders are scanned too) |
| `captures/` | the reamp recordings made by `profile` |
| `config.txt` | the saved settings: devices, profile, gains, gate, normalization, period; plain `key=value` lines |
| `v3_0_0.wav` | the standardized capture signal, downloaded once by `profile` or `doctor --download` |

## Command help and format range

`nam-zig --help` lists the full command set (profile capture, chains, MIDI
mapping, loopback latency test). Accepted profiles cover the upstream `.nam` format
range 0.5.0–0.7.x.

## Getting the capture signal (`v3_0_0.wav`)

The v3 capture file is the official NAM trainer's "input file" download; the
upstream trainer GUI's *Download input file* button fetches it from
<https://drive.google.com/file/d/1Pgf8PdE0rKB1TD4TRPKbpNo1ByR3IOm9/view?usp=drive_link>.
Verify the bytes before a capture session:

```sh
md5 v3_0_0.wav        # macOS; Linux: md5sum
# expect 36cd1af62985c2fac3e654333e36431e
```

Recognition is an MD5 of the exact file bytes: a re-encoded or resampled copy still plays through your
rig, but the trainer falls back to the generic-pair path (no automatic latency
calibration, no v3 quality checks) with only an `unrecognized capture signal;
assuming --latency 0` note. v1/v2/v4 capture files (deprecated upstream) are refused.

## Quick training smoke: no interface, no amp

The whole train → export → validate loop runs offline: synthesize a noiseless,
sample-aligned "reamp" by rendering a vendored test profile over the v3 capture
file, then train against it.

```sh
nam-zig render src/testdata/wavenet.nam v3_0_0.wav synth-reamp.wav
nam-zig train --input v3_0_0.wav --output synth-reamp.wav \
    --out smoke.nam --spec tiny --epochs 20
nam-zig validate smoke.nam --input v3_0_0.wav --output synth-reamp.wav
```

`--spec tiny` is a small single-array spec for smoke tests and quick runs (it is
not a production profile shape; real profiles use the default `standard`).
Expect: a `v3 capture detected; latency -1 samples; replicate self-ESR 0.000000
(ok)` line (−1 is the 1-sample calibration safety factor on a zero-delay
pair), a `training tiny spec: ...` header with the resolved recipe,
one `epoch k/20: train loss ...  val ESR ...` line per epoch (improvements
starred; wall time printed per line), and a final `validation ESR ...` line
with its quality band before the export; the 20-epoch smoke lands in the "Not bad!"
band in a couple of minutes on a laptop. Reruns with the same `--seed`
(default 0) reproduce the loss trace exactly.

## Training reference: input requirements and options

**WAV requirements.** `train`, `validate`, `render`, and `profile` inputs must be
**mono** (stereo files are refused with `NotMono`; export a mono track from the
DAW rather than relying on a channel being picked). Accepted encodings: 16/24/32-bit
integer PCM and 32-bit float. Training requires both files at exactly 48 kHz and
at the same rate as each other; `profile` writes its reamp as 32-bit-float mono.

**All `train` options** (`profile` forwards every flag it doesn't recognize,
including `--out`, to `train`, so these work in both):

| Flag | Default | Meaning |
| --- | --- | --- |
| `--spec standard\|tiny\|a2\|a2-nano\|packed` | `standard` | model shape + recipe (`tiny` = smoke runs) |
| `--init model.nam` | none | fine-tune a supported WaveNet instead of `--spec` |
| `--epochs N` | 100 | training epochs (best epoch is exported) |
| `--batch N` | 16 | batch size (gradient accumulation) |
| `--ny N` | 8192 | target-window samples per example |
| `--lr X` | 0.004 | initial Adam learning rate |
| `--gamma X` | 0.993 (packed 0.994) | per-epoch exponential LR decay |
| `--weight-decay X` | 0 (packed 3.17e-7) | Adam weight decay |
| `--mrstft-weight X` | 0 (packed 0.0005) | MRSTFT loss weight |
| `--seed N` | 0 | deterministic init + shuffle |
| `--latency N` | v3: auto-calibrated; else 0 | manual x→y delay, in samples |
| `--ignore-checks` | off | proceed past a failed v3 replicate check (recorded in the export metadata) |
| `--name` `--modeled-by` `--gear-type` `--gear-make` `--gear-model` `--tone-type` | none | export metadata (`--gear-type` also drives the cab advisories) |

**Test-plan prerequisites.** The upstream checkouts the [Test plan](#test-plan-beyond-zig-build-test)
builds against are fetched pinned with:

```sh
tools/fetch_refs.sh
```

## Acknowledgments

nam-zig exists because others built the road first.

- **Steven Atkinson** ([NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore)
  and [neural-amp-modeler](https://github.com/sdatkinson/neural-amp-modeler)): the `.nam`
  format, the architectures, the trainer recipe, and the export schema this project ports.
  His `render` and `benchmodel` tools are the parity and performance oracles, and the
  vendored test fixtures and loudness signal come from his repositories.
- **[Tone3000](https://www.tone3000.com)**: the public library of `.nam` profiles and
  cabinet IRs that gives a fresh install something to play through.
- **David Reid** ([miniaudio](https://github.com/mackron/miniaudio)): the vendored
  single-header audio device layer behind `live`, `devices`, and `profile`.
- **[Fucina](https://github.com/matteo-grella/fucina)**: the tensor library the engines and
  the trainer are written on.

The complete inventory of what is vendored, what is ported, what is a parity reference
only, and under which license is in `THIRD-PARTY-NOTICES.md`.
