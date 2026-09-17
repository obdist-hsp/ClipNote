#!/bin/bash
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x ClipNote 2>/dev/null || true
sleep 0.3
open build/ClipNote.app
