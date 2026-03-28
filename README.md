# swiftly-play

`swiftly-play` is a small macOS Swift command-line playground for streaming concatenated WAV buffers into `AVAudioEngine`.

This tool is intentionally basic right now and still under construction.

Current notes:
- The main executable is `wavbuffer`.
- Input is expected on `stdin` as concatenated RIFF/WAVE chunks.
- Playback lifecycle logging and preroll controls are implemented, but the project is still a rough utility rather than a polished package.

## Usage

Build and run the executable with a concatenated WAV stream on `stdin`:

```sh
swift run wavbuffer < stream.wavs
```

Use preroll if you want the player to queue more than the first chunk before starting:

```sh
swift run wavbuffer --queue-depth 8 --preroll-buffers 3 < stream.wavs
swift run wavbuffer --preroll-seconds 0.5 < stream.wavs
```

The two preroll flags are mutually exclusive.
For the current `speak-to-user` service on Gale's M4 Pro, the recommended `wavbuffer` path is `--queue-depth 8 --preroll-buffers 3` so playback waits for a few full buffers instead of starting after a single long chunk.

For a local demo stream:

```sh
sh scripts/e2e_wavbuffer.sh --queue-depth 8 --preroll-buffers 3
```

## Stderr Vocabulary

`wavbuffer` writes structured lifecycle lines to `stderr`:

- `event=engine_started`: the `AVAudioEngine` graph was connected and started successfully.
- `event=playback_started`: the player actually began playback after preroll was satisfied, or after input finished with a short stream.
- `event=underrun`: the scheduled queue drained before more WAV data arrived on `stdin`.
- `event=completed`: playback finished normally.
- `event=error`: the command exited with an error; playback errors include additional reason and platform error details when available.
