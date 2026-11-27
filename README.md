# trackpad-subwoofer

Turns the Mac's Force Touch trackpad into a **subwoofer**, driven by the **system's audio output**.

```
system output  →  low-pass  →  bass envelope + pitch  →  haptic motor  →  glass
```

Play music with a beat on, and the trackpad rumbles with the bass. Put it on a table, mute the
speakers, and feel the low end through the glass.

Built from the same idea as [nospeaker](https://github.com/os6/nospeaker) — that project makes the
trackpad *talk*; this one makes it *rumble*.

---

## Build

### Just download it

Grab the latest release and run it:

```sh
curl -fsLO https://github.com/Jimmytheprofessionaldumbass/trackpad-subwoofer/releases/latest/download/trackpad-subwoofer.zip
unzip trackpad-subwoofer.zip
./trackpad-subwoofer
```

Universal binary (Apple Silicon + Intel), macOS 14.2 or later. It is ad-hoc signed but **not
notarized**, so Gatekeeper may stop it the first time — right-click → Open, or build it yourself
below.

### Build from source

Needs Xcode or the Command Line Tools:

```sh
xcode-select --install      # if you don't have it
git clone https://github.com/Jimmytheprofessionaldumbass/trackpad-subwoofer
cd trackpad-subwoofer
./build.sh
```

## Run

```sh
./trackpad-subwoofer                 # rumble with whatever the Mac is playing
./trackpad-subwoofer --dry-run       # same analysis, but the trackpad stays still
./trackpad-subwoofer --selftest      # verify the filter, pitch tracking and tone shapes (no sound)
./trackpad-subwoofer --check         # what this Mac can do: haptics + capture path
./trackpad-subwoofer --help          # every option
```

`ctrl-c` stops it.

**Nothing is captured from the microphone by default.** The program taps what the system is playing
(a CoreAudio process tap), so it hears your music, not your room.

### Try it

1. Put the Mac on a table (or hold it — you'll feel it either way).
2. Play something with a beat. Music with a strong low end works best.
3. `./trackpad-subwoofer` and leave it running.

Start with `--dry-run` if you'd rather watch the meter first — it prints what the analyser sees
without moving anything. The meter shows the bass level in dB, the detected fundamental, and the
drive strength:

```
  bass -41.9 dB   f0  40.4 Hz   drive  40.4 Hz   level 0.21   conf 0.52
```

If it feels more like a buzzer than bass, lower `--cutoff` and `--max-hz`. If it's too subtle,
raise `--gain` (or `--max-level`, up to 1.0).

## Options

| Option | Default | What it does |
|---|---|---|
| `--source WHICH` | `output` | `output` = what the system is playing. `input` = the microphone. |
| `--exclude-app NAME` | — | Don't capture audio from apps whose bundle id contains `NAME`. |
| `--cutoff HZ` | 120 | Low-pass corner — the top of the sub band. Lower = more muffled, deeper. |
| `--highpass HZ` | 20 | DC blocker corner. Keeps infrasonic rumble out of the envelope. |
| `--min-hz HZ` | 60 | Lowest frequency the motor is asked to make. |
| `--max-hz HZ` | 150 | Highest frequency the motor is asked to make. |
| `--waveform WHICH` | `sine` | Tone shape: `sine`, `square` or `sawtooth`. Square and sawtooth carry harmonics, which is what makes a low fundamental audible. |
| `--floor-db DB` | -55 | Input level treated as silence. |
| `--ceiling-db DB` | -12 | Input level that means full drive. |
| `--gamma G` | 1.5 | Response curve. Higher = less eager, more "only the loud bass". |
| `--gain G` | 1.0 | Overall drive multiplier. |
| `--max-level L` | 0.8 | Hard ceiling on motor strength (0…1). |
| `--harmonic N` | 0 | Add a tone N× the fundamental, so it is audible as well as felt. |
| `--harmonic-amp A` | 0.35 | How loud that harmonic is, relative. |
| `--attack S` | 0.010 | Envelope attack time, seconds. |
| `--release S` | 0.120 | Envelope release time, seconds. |
| `--dry-run` | — | Capture and analyse, but don't drive the trackpad. |
| `--selftest` | — | Verify the filter, pitch tracking and tone-shape encoding. No device, no sound. |
| `--check` | — | Report the haptic and capture paths, then exit. Captures nothing. |
| `--list-devices` | — | List input devices, then exit. |
| `--device WHICH` | default input | Which device to listen to in `--source input` mode: a device id, or part of its name. |
| `--fixed-hz HZ` | follow pitch | Drive one fixed frequency instead of tracking the bass pitch. |
| `--no-feedback-guard` | on | Don't damp the motor when it starts hearing itself (mic mode only). |
| `--feedback-decay DB` | 1.0 | How far the level may drift over the lock window and still count as a held hum. |
| `--no-meter` | — | No level meter. |
| `--external` | — | Drive an external Magic Trackpad instead of the built-in one. |

### Recipes

```sh
# deeper, for techno
./trackpad-subwoofer --cutoff 90 --max-hz 110 --gamma 1.2

# wider, for funk and R&B
./trackpad-subwoofer --cutoff 180 --max-hz 220 --ceiling-db -16

# audible as well as felt
./trackpad-subwoofer --harmonic 3 --harmonic-amp 0.5

# louder: square wave carries harmonics the trackpad can actually make
./trackpad-subwoofer --waveform square

# don't wake the whole house
./trackpad-subwoofer --floor-db -45 --max-level 0.5

# one steady tone you can feel, no pitch tracking
./trackpad-subwoofer --fixed-hz 60

# rumble with the room instead of the computer (uses the microphone)
./trackpad-subwoofer --source input

# don't let the program hear itself if you play music from a browser tab
./trackpad-subwoofer --exclude-app com.google.Chrome
```

## How it works

1. **Capture the system output.** macOS 14.2 added *process taps*: `AudioHardwareCreateProcessTap`
   with a `CATapDescription` creates a tap on what apps are playing. The tap isn't a device, so it's
   wrapped in an **aggregate device** (`AudioHardwareCreateAggregateDevice`) with the tap in its
   `kAudioAggregateDeviceTapListKey`. That aggregate is what an `AudioQueue` reads from, in Float32.
2. **Mono mix** → **DC blocker** (one-pole high-pass at 20 Hz) → **8th-order Butterworth low-pass**
   (four biquads, Q = 0.510 / 0.601 / 0.900 / 1.962, at 120 Hz). High frequencies are gone; only the
   sub band is left.
3. **Envelope.** RMS of the filtered signal → dBFS → normalised between `--floor-db` and
   `--ceiling-db` → gamma curve → gain, with fast attack and slow release so a kick drum hits hard
   and the rumble fades out.
4. **Pitch.** Normalised autocorrelation on the decimated filtered signal finds the fundamental
   (25 Hz up to twice the low-pass corner). It's slewed, not jumped, so the motor glides instead of
   clicking. The fundamental becomes the motor's drive frequency, clamped to `--min-hz`…`--max-hz`.
5. **Haptic.** `MultitouchSupport` (private framework, resolved with `dlopen`/`dlsym`):
   `MTActuatorCreateFromDeviceID` → `MTActuatorOpen` → `MTActuationCreateFromDictionary` →
   `MTActuationActuate`. Each ~20 ms segment is a whole number of cycles of the current drive
   frequency, so the sine never starts mid-cycle. The tone shape (`Sine`, `Square`, `Sawtooth`)
   goes in the same dictionary.

### Notes on the range

The motor can't reproduce true sub-bass, so the program plays the trackpad's strong, felt range:
roughly **60–150 Hz**. Below that the Taptic engine just thuds; above it the glass gets buzzy
rather than deep. The default band is chosen so it *feels* like a subwoofer rather than sounding
like one.

**60 Hz is a hard floor, not a default.** Apple's own actuation tables bottom out at 0.06 kHz —
nothing in them goes lower — and the encoder quantises the frequency you request logarithmically
onto that table. Asking for 35 Hz does not give you 35 Hz; it gives you the lowest tone the
hardware has, or a mushy one. The drive is clamped to the hardware's range (60 Hz – 3.8 kHz) so
the meter never claims a frequency the trackpad cannot produce.

The trackpad has no speaker — it has a motor that taps the glass. Driving it at 60–150 Hz makes
the glass move in slow thumps you can feel through a desk. `--waveform square` adds harmonics that
land in the trackpad's loudest octave (around 1 kHz), which is what turns a faint thump into
something you can actually hear.

### Four things that bite when you build this

Worth recording, because each one cost a debugging round:

- **The aggregate device must be private AND have `kAudioAggregateDeviceTapAutoStartKey: 1`.**
  With a public aggregate the tap never activates and the aggregate reports zero input channels.
  With auto-start missing, the same. The combination that works is `IsPrivateKey: 1` plus
  `TapAutoStartKey: 1`.
- **A tap's UID comes from `kAudioTapPropertyUID` ('tuid'), not `kAudioDevicePropertyDeviceUID`.**
  Asking a tap for a device UID doesn't return an error — it **crashes** CoreAudio (SIGSEGV inside
  the property marshaller).
- **The tone-type string is case-sensitive.** `"Sine"` encodes as type 1, `"Square"` as 2,
  `"Sawtooth"` as 3 — but `"sine"` or `"square"` silently become 0 (Gaussian). No error, just the
  wrong waveform, so the program maps its option to the exact dictionary string.
- **The feedback guard only matters in microphone mode.** With the system-output tap there is no
  acoustic path from the motor back to the source, so no loop is possible. Switch to
  `--source input` and the built-in mic sits right next to the trackpad: the motor shakes the
  glass, the glass shakes the air, the mic hears the motor. The guard handles that (runaway → 150 ms
  mute; steady self-locked hum → halved drive), and `--device "BlackHole 2ch"` avoids the loop
  entirely.

## Safety

- The motor is never driven past `--max-level` (default 0.8, hard-capped at 1.0). nospeaker's
  finding: past full strength the driver starts to stall, so this stays below that.
- Nothing is written to disk and nothing leaves the machine. The captured audio is processed in
  memory and thrown away. The program makes no network connections.
- It never changes your default input or output device, and it never unmutes anything.

## Requirements

- Force Touch trackpad: a MacBook from 2015 on, or a Magic Trackpad 2 or newer.
- **macOS 14.2 or later** — capturing system output uses `AudioHardwareCreateProcessTap`.
- `MultitouchSupport` is private and undocumented — a macOS update could move the functions this
  needs.

## Credits

The haptic layer (`dlopen` of `MultitouchSupport`, `MTActuator*`, `MTActuation*`, the terminal
silencing trick) comes from **[nospeaker](https://github.com/os6/nospeaker)** by Cody Collier —
MIT licensed, Copyright (c) 2026 Cody Collier. The audio analysis, filtering, envelope, pitch
tracking, and the whole subwoofer concept are new work by Jimmy Zeng.

```
MIT License

Copyright (c) 2026 Cody Collier
```

See `LICENSE.nospeaker` for the full text of the upstream license, and `LICENSE` for this project.

---

## Why this exists

nospeaker proved the trackpad can be made to *speak*. That raises an obvious question: can it be
made to *rumble*? The answer is yes, and it turns out to be more useful than expected — it's a
way of feeling a track's low end without the speakers, which is handy on a desk, on a train, or at
2am.

This is also a decent demonstration of three fairly obscure macOS APIs in one small program:
process taps for system-audio capture, aggregate devices for turning a tap into something
readable, and the private `MultitouchSupport` framework for driving the haptic motor.
