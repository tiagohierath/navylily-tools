# audio-clean.sh

Cleans a raw mic recording into a consistent, podcast-ready voice file. It removes rumble and hiss (RNNoise), fixes the boxy room sound, lifts speech clarity, evens out the volume, and normalizes loudness.

```bash
./audio-clean.sh raw.wav final.wav
```

## When to use it

Usually you don't. `make_videos.sh` runs the same cleanup itself, so for videos just drop the raw recording in `videos/audio/` and render. Use this script only when you want a cleaned audio file on its own (a podcast cut, or to listen and tune the sound before rendering). Never run both on the same file, that would compress twice.

## Recording raw audio on this box

No `arecord` here, use PipeWire:

```bash
wpctl status          # find the FIFINE source id
wpctl set-default 73  # make it the default mic
pw-record raw.wav     # Ctrl-C to stop
```

## Tuning

The filter chain lives in `lib/voice-chain.sh` and is shared with `make_videos.sh`, so editing it changes both. The useful knobs:

- Less/more denoise: swap the RNNoise model with `RNNOISE_MODEL=/path/to/model.rnnn`. The bundled `models/sh.rnnn` is trained for speech and is right for narration.
- Darker/brighter: the `lowpass=f=16000` value (lower = darker, less hiss).
- Room sound and clarity: the two `equalizer=` lines (cut at 250 Hz, lift at 3500 Hz), adjust `g=` in dB.
- Dynamics: the `acompressor` ratio (lower = more natural).
- Loudness target: `loudnorm=I=-16` (podcast level; YouTube uses -14).

## NixOS note

The system ffmpeg lacks the RNNoise filter, so the script re-runs itself inside `nix shell nixpkgs#ffmpeg` automatically. Nothing gets installed. The first run takes a few extra seconds, then it's cached.
