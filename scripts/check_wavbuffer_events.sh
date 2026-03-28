#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

normal_stderr=$(mktemp)
starved_stderr=$(mktemp)
starved_fifo=$(mktemp -u)
trap 'rm -f "$normal_stderr" "$starved_stderr" "$starved_fifo"' EXIT HUP INT TERM

cd "$REPO_DIR"

swift "$SCRIPT_DIR/generate_test_wav_stream.swift" \
    | swift run wavbuffer --queue-depth 8 --preroll-buffers 3 2>"$normal_stderr"

grep -q 'event=engine_started' "$normal_stderr"
grep -q 'event=playback_started' "$normal_stderr"
grep -q 'event=completed' "$normal_stderr"

engine_line=$(grep -n 'event=engine_started' "$normal_stderr" | head -n 1 | cut -d: -f1)
play_line=$(grep -n 'event=playback_started' "$normal_stderr" | head -n 1 | cut -d: -f1)
complete_line=$(grep -n 'event=completed' "$normal_stderr" | head -n 1 | cut -d: -f1)

[ "$engine_line" -lt "$play_line" ]
[ "$play_line" -lt "$complete_line" ]

mkfifo "$starved_fifo"
(
    exec 3>"$starved_fifo"
    swift "$SCRIPT_DIR/generate_single_tone_wav.swift" 440 0.03 >&3
    sleep 1
    swift "$SCRIPT_DIR/generate_single_tone_wav.swift" 660 0.03 >&3
    exec 3>&-
) &
writer_pid=$!

if swift run wavbuffer <"$starved_fifo" 2>"$starved_stderr"
then
    :
fi

wait "$writer_pid" || true

grep -q 'event=engine_started' "$starved_stderr"
grep -q 'event=playback_started' "$starved_stderr"
grep -q 'event=underrun' "$starved_stderr"
grep -q 'event=waiting_for_audio' "$starved_stderr"
grep -q 'event=playback_resumed' "$starved_stderr"
grep -q 'event=completed' "$starved_stderr"
