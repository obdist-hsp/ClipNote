# ClipNote

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-swiftc-F05138.svg)](https://www.swift.org/)

Clipboard history + region capture, shown as always-on sticky notes in the macOS menu bar.

macOS 14+ 向けのメニューバーアプリ。クリップボード履歴と範囲キャプチャを「付箋」として常時表示します。Xcode 不要、`swiftc` だけでビルドできます。**外部通信ゼロを OS レベルで担保**しています。

## 特徴

- コピーしたテキスト / 画像 / ファイルを 0.3 秒以内に履歴へ追加
- ⌘⇧2 で画面をドラッグして範囲キャプチャ
- App Sandbox 有効・ネットワーク権限なし。依存ライブラリはゼロ（Apple 標準フレームワーク + libsqlite3 のみ）
- 画像はオンデバイス Vision で OCR され、SQLite FTS5 で全文検索
- テキストは明示削除しない限り永続。画像は合計 100 GB 超で古いものから本体だけ削除（ブックマークは対象外）

## インストール

前提: macOS 14 以降、Xcode Command Line Tools（`xcode-select --install`）。Xcode 本体は不要。

```bash
git clone https://github.com/obdist-hsp/ClipNote.git
cd ClipNote
./install.sh      # ビルド → 署名 → 外部通信ゼロ検証 → /Applications に配置 → 起動（ログイン項目に登録）
```

初回の ⌘⇧2 で「画面収録」の許可を求められるので許可し、もう一度 ⌘⇧2 を押してください。
ad-hoc 署名のためビルドし直すと署名が変わり、許可をもう一度求められます（それ以外では聞かれません）。

開発中の試し起動は `./run.sh`（`build/` 側を起動。/Applications 版とは別署名なので普段は使いません）。

## 操作

| 操作 | 内容 |
|---|---|
| 何かをコピー | 0.3 秒以内にテキスト / 画像 / ファイルが先頭に追加される |
| ⌘⇧2 | 画面をドラッグして範囲キャプチャ（Esc でキャンセル）。初回は「画面収録」の許可が必要 |
| カードにホバー → コピーボタン | クリップボードへ再コピー |
| カードをダブルクリック | 拡大プレビュー（← → で前後、Esc で閉じる、⌘C でコピー、テキスト選択可） |
| カードをドラッグ | 他アプリへ直接ドロップ |
| 右クリック | コピー / 拡大表示 / ブックマーク / 削除 / OCR テキストをコピー / Finder で表示 |
| ブックマーク | 常に一覧の先頭に固定。左端のグリップ（≡）をドラッグで並び替え。容量上限の削除対象外 |
| 検索欄 | 3 文字以上で本文と OCR 結果を全件対象に全文検索（SQLite FTS5 trigram） |
| メニューバー | パネル表示切替、監視の一時停止、全消去、ログイン時起動 |

- 一覧は 100 件ずつの無限スクロール。件数が増えても重くならない。
- 画像は保存後にバックグラウンド（Vision、オンデバイス）で OCR され、結果が出た時点で自動的に検索対象になる。
- **テキストは明示的に削除しない限り永続**。件数上限はない。
- **画像ファイルの合計が 100 GB を超えると、ブックマーク以外の古い画像から削除**される。
  レコード自体と OCR テキストは残り、カードには「画像は容量上限で削除済み」と表示される。
  同じ画像を再度コピーすると復元される。上限は次で変更できる。
  ```bash
  defaults write obdist.hsp.clipnote imageCapacityBytes -int 10737418240   # 10 GB
  ```

## データの保存先

```
~/Library/Containers/obdist.hsp.clipnote/Data/Library/Application Support/ClipNote/
  clipnote.sqlite  # 履歴（SQLite + FTS5）。画像はファイル名参照
  images/*.png     # 画像本体（PNG 原寸）
```

旧版の `history.json` が残っていれば初回起動時に自動で取り込み、`history.json.migrated` にリネームする。

## 外部通信ゼロの検証手順

`./build.sh` の末尾に「証明レポート」が出力され、1 つでも FAIL ならビルドは失敗する。

1. **エンティトルメント**: `com.apple.security.app-sandbox` があり、`com.apple.security.network.*` が無い
   ```bash
   codesign -d --entitlements - build/ClipNote.app
   ```
   network エンティトルメントの無いサンドボックスアプリは、コードが通信を試みてもカーネルが
   `Operation not permitted` で socket 作成を拒否する。
2. **シンボル**: バイナリが `NSURLSession` / `NWConnection` / `socket` / `connect` などを参照していない
   ```bash
   nm -u build/ClipNote | grep -iE 'URLSession|NWConnection|socket|connect'
   ```
3. **リンク**: `CFNetwork` / `Network.framework` を直接リンクしていない
   ```bash
   otool -L build/ClipNote
   ```
4. **実行時**: 起動中にソケットが 1 つも無い
   ```bash
   lsof -i -a -p "$(pgrep -x ClipNote)"
   ```

依存ライブラリはゼロで、Apple 標準フレームワーク（AppKit / SwiftUI / ScreenCaptureKit / Vision / Carbon / ServiceManagement）と macOS 標準の libsqlite3 のみを使用。
ソースは `Sources/` 配下で全文監査できる。

## 構成

```
build.sh                  ビルド・署名・検証
ClipNote.entitlements     app-sandbox のみ（network 権限なし）
Info.plist                LSUIElement / 画面収録の用途説明
Sources/
  main.swift, AppDelegate.swift        起動、メニューバー、各サービスの配線
  Models/ClipItem.swift                1 件のモデル
  Models/SQLite.swift                  libsqlite3 の最小ラッパー
  Models/Database.swift                スキーマ、FTS5、ページング、容量クエリ
  Models/HistoryStore.swift            表示状態、ページ読み込み、ブックマーク、容量上限
  Services/PasteboardWatcher.swift     changeCount ポーリング
  Services/ScreenCapturer.swift        範囲選択オーバーレイ + ScreenCaptureKit
  Services/HotKey.swift                Carbon グローバルホットキー
  Services/OCRQueue.swift              後追い OCR
  UI/StickyPanel.swift                 非アクティブ化しない浮動パネル
  UI/HistoryListView.swift             検索、ブックマーク／履歴セクション、無限スクロール、並び替え
  UI/ClipCardView.swift                カード（コピーボタン、グリップ、右クリック）
  UI/PreviewWindow.swift               ダブルクリックの拡大プレビュー
```

## ライセンス

[MIT License](LICENSE) © 2026 obdist-hsp
