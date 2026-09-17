#!/bin/bash
# ビルド → /Applications に配置 → 起動（ログイン項目に登録）
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
# メインスレッドが固まっていると SIGTERM（通常の終了）は届かない
pkill -9 -x ClipNote 2>/dev/null || true
pkill -9 -x ClipNoteStatus 2>/dev/null || true
sleep 0.5
rm -rf /Applications/ClipNote.app
cp -R build/ClipNote.app /Applications/ClipNote.app
open -a /Applications/ClipNote.app --args --enable-login-item
echo "✅ installed: /Applications/ClipNote.app"
echo "   注意: 再インストールすると署名が変わり、画面収録の許可を再度求められます"
