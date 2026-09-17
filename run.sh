#!/bin/bash
set -e
cd "$(dirname "$0")"
./build.sh
pkill -9 -x ClipNote 2>/dev/null || true
pkill -9 -x ClipNoteStatus 2>/dev/null || true
sleep 0.3
open build/ClipNote.app
