#!/bin/bash
# 別 Mac 向けの配布物を git bundle で作る。展開後は ./install.sh だけ。
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
STAGE=dist/ClipNote
BUNDLE_NAME=ClipNote.bundle
ZIP="dist/ClipNote-${VERSION}.bundle.zip"

rm -rf dist
mkdir -p "$STAGE"

# 全ブランチ・タグを含む clone 可能な bundle
git bundle create "$STAGE/$BUNDLE_NAME" --all
git bundle verify "$STAGE/$BUNDLE_NAME"

cat > "$STAGE/install.sh" << 'EOF'
#!/bin/bash
# git bundle からリポジトリを展開し、ビルド → /Applications へ入れる
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v git >/dev/null; then
  echo "エラー: git が必要です。次を実行してください: xcode-select --install" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null; then
  echo "エラー: swiftc が必要です。次を実行してください: xcode-select --install" >&2
  exit 1
fi

SRC="ClipNote"
if [[ ! -d "$SRC/.git" ]]; then
  git clone ClipNote.bundle "$SRC"
else
  echo "既存の $SRC を使います"
fi
exec "$SRC/install.sh"
EOF
chmod +x "$STAGE/install.sh"

cat > "$STAGE/README.txt" << EOF
ClipNote ${VERSION}（git bundle / Apple Silicon / macOS 14 以降）

インストール:
  1. このフォルダを展開する
  2. ターミナルでそのフォルダに入り、次を実行する

     ./install.sh

git の履歴ごと clone したあと、ビルドして /Applications に入れます。
Xcode Command Line Tools（git と swiftc）が必要です。未導入なら:

  xcode-select --install

範囲キャプチャを使う場合、初回は「画面収録」の許可が必要です。
ad-hoc 署名のため、入れ直すたびに許可を再度求められます。
EOF

rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"

echo "✅ package OK: $ZIP"
echo "   先方: zip を展開 → ./install.sh"
echo "   bundle: $STAGE/$BUNDLE_NAME"
