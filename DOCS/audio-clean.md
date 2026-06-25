# audio-clean.sh

Deterministic "broadcast-ish" voice cleanup for the FIFINE USB mic (or any mic).
Record raw, run this, and you always get the same consistent, platform-ready
voice file. Pushes a budget USB mic from "room with furniture" into
"surprisingly competent narrator" territory.

## The chain (what each stage does)

| Stage | Filter | Why |
|-------|--------|-----|
| Low-cut | `highpass=f=80` | kills rumble, desk thumps, AC hum |
| High-cut | `lowpass=f=16000` | shaves the harsh hiss ceiling |
| Denoise | `arnndn=m=sh.rnnn` | RNNoise neural noise suppression (natural, not "underwater") |
| De-box | `equalizer=f=250:g=-2` | tames small-room "boxy" mids |
| Presence | `equalizer=f=3500:g=+2` | lifts speech clarity / intelligibility |
| Compress | `acompressor=threshold=-18dB:ratio=3` | evens out loud/quiet words |
| Loudness | `loudnorm=I=-16:TP=-1.5:LRA=11` | normalizes to podcast/YouTube loudness |
| Output | `-ar 48000` | pin sample rate (see note below) |

## Commands

```bash
./audio-clean.sh raw.wav final.wav
RNNOISE_MODEL=/path/to/other.rnnn ./audio-clean.sh raw.wav final.wav   # different model
```

### Recording raw from the FIFINE (no arecord on this box — use PipeWire)

```bash
wpctl status                                   # find the fifine source id (e.g. 73)
wpctl set-default 73                            # make the FIFINE the default mic
pw-record raw.wav                               # Ctrl-C to stop
# ...or target it explicitly without changing the default:
pw-record --target alsa_input.usb-MV-SILICON_fifine_Microphone_20190808-00.mono-fallback raw.wav
```

Then: `./audio-clean.sh raw.wav final.wav`.

## Two bugs fixed vs. the original recipe

1. **`arnndn` needs a model.** `arnndn` with no `m=` errors out immediately.
   We bundle `models/sh.rnnn` and pass `arnndn=m='…/models/sh.rnnn'`.
2. **`loudnorm` outputs 192 kHz.** It upsamples internally for its true-peak
   limiter and never comes back down. Without `-ar` every file lands at a bloated
   192 kHz. We pin `-ar 48000`.

## NixOS / ffmpeg

The stock system `ffmpeg` on this machine is built **without** the `arnndn`
filter. `audio-clean.sh` detects that and re-execs itself inside
`nix shell nixpkgs#ffmpeg` (which has it). Nothing is installed system-wide.
First run pays a few seconds of nix eval; after that it's cached.

There is **no** `rnnoise-models` package in nixpkgs (the original flake snippet
referenced one that doesn't exist), so the model is vendored in `models/`. The
files are public domain per the upstream README ("none of this work is creative
and thus none of it is subject to copyright").

## Knobs you can edit (in `audio-clean.sh`)

- **Less/more denoise** — swap the model via `RNNOISE_MODEL=`. Options (from
  `GregorR/rnnoise-models`, by signal×noise):

  | File | Trained for |
  |------|-------------|
  | `sh.rnnn` *(bundled)* | recorded **speech** — the default for narration |
  | `bd.rnnn` (beguiling-drafter) | recorded **voice** (incl. laughter etc.) |
  | `cb.rnnn` (conjoined-burgers) | recorded **general** audio |
  | `mp.rnnn` (marathon-prescription) | general signal, general noise |

  Get another: `curl -fsSL -o models/bd.rnnn https://raw.githubusercontent.com/GregorR/rnnoise-models/master/beguiling-drafter-2018-08-30/bd.rnnn`
- **Brightness** — `lowpass=f=16000` (lower = darker/less hiss).
- **EQ** — the two `equalizer=` lines (boxy-mid cut at 250 Hz, presence lift at
  3500 Hz). Adjust `g=` in dB.
- **Compression** — `acompressor=threshold=-18dB:ratio=3:...`. Softer ratio =
  more natural dynamics.
- **Target loudness** — `loudnorm=I=-16`. `-16` is podcast-ish; YouTube refs
  `-14`.

## Using it with `make_videos.sh`

`make_videos.sh` already runs its **own** two-pass `loudnorm` (target `-14`) +
compression on whatever audio you feed it. So if you clean a file here and then
build a video from it, the **noise removal + EQ** is the real value-add; the
loudness/compression gets partly redone (harmless — the final video ends at
`-14` for YouTube). For the navylily pipeline:

```
record raw → audio-clean.sh → put result in videos/audio/ → make_videos.sh → upload
```

## Reality check (measured on this machine)

- **No echo-cancel / auto-gain modules are loaded** — PipeWire is already *not*
  "helping," so the spec's "disable AGC/echo-cancel" steps are a no-op here.
- **PipeWire + pulse + alsa are already enabled** (it's running), so the
  `services.pipewire` block is effectively already in place. No `/etc/nixos`
  edit was made.
- The optional WirePlumber drop-in lives at
  [`wireplumber/51-mic-clean.conf`](../wireplumber/51-mic-clean.conf) — see its
  header to install. It's only worth it if you hit idle-suspend start-clipping;
  it is **not** installed by default (a malformed user WP config can break login
  audio, and there's nothing here it needs to fix).
- Biggest real-world gain is still **room noise** — RNNoise + the mic can't beat
  treating the space.
