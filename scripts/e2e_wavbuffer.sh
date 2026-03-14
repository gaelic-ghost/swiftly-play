#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$REPO_DIR"
swift "$SCRIPT_DIR/generate_test_wav_stream.swift" | swift run wavbuffer "$@"
