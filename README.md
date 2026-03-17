# swiftly-play

`swiftly-play` is a small macOS Swift command-line playground for streaming concatenated WAV buffers into `AVAudioEngine`.

This tool is intentionally basic right now and still under construction.

Current notes:
- The main executable is `wavbuffer`.
- Input is expected on `stdin` as concatenated RIFF/WAVE chunks.
- Playback lifecycle logging and preroll controls are implemented, but the project is still a rough utility rather than a polished package.
