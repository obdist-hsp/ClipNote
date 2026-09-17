# ClipNote

[![Beta](https://img.shields.io/badge/status-beta-orange.svg)](https://github.com/obdist-hsp/ClipNote/releases)
[![Version 0.2.0](https://img.shields.io/badge/version-0.2.0-blue.svg)](https://github.com/obdist-hsp/ClipNote/releases/tag/v0.2.0-beta)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-swiftc-F05138.svg)](https://www.swift.org/)

Clipboard history + region capture, shown as always-on sticky notes in the macOS menu bar.  
デフォルト環境macOS向けのメニューバーアプリ。スタンドアロンのクリップボード管理とOCR検索による超簡易個人ナレッジベース。
**いまはベータ版（v0.2.0）です。** Xcode 不要、`swiftc` だけでビルドでき、**外部通信ゼロを OS レベルで担保**しています。

## TARGET
- 貸与されているPCで自由な環境が使えない
- 外部通信のあるアプリの利用許可が厳しい
- スタンドアロン環境で使いたい

## 特徴
- クリップボード監視によりtext, image, file(path)　を瞬時にボードに変換
- クリップボード監視を停止し、メニューまたはパネルのハサミボタンで範囲キャプチャすることが可能。　⌘⇧2 は初期 OFF
- 最前面表示機能（切り替え可）
- ブックマーク機能でTOPに好きなボードを固定可（TODO, memo用途を想定）
- App Sandbox 有効・ネットワーク権限なし。依存ライブラリはゼロ（Apple 標準フレームワーク + libsqlite3 のみ）
- 画像はオンデバイス Vision で OCR され、SQLite FTS5 で全文検索
- テキストは明示削除しない限り永続。画像は合計 100 GB 超で古いものから本体だけ削除（ブックマークは対象外）

## SAMPLE
<img width="352" height="530" alt="image" src="https://github.com/user-attachments/assets/c471eb6d-70dd-4017-9a5b-8a7b1c95a690" />

<img width="1068" height="531" alt="image" src="https://github.com/user-attachments/assets/9ce9fe7f-9194-403e-ae6e-2010cb204032" />

## インストール

前提: macOS 14 以降、Xcode Command Line Tools（`xcode-select --install`）。Xcode 本体は不要。

```bash
git clone https://github.com/obdist-hsp/ClipNote.git
cd ClipNote
./install.sh      # ビルド → 署名 → 外部通信ゼロ検証 → /Applications に配置 → 起動（ログイン項目に登録）
```

## 使い方
インストール後、クリップボード監視は有効状態です。  
text      : cmd + c  
image     : ctrl + shift + cmd + 4　※MacOS標準のショートカット  
file(path): cmd + c  

## 画面収録許可について
ad-hoc 署名のためビルドし直すと署名が変わり、許可をもう一度求められます。
※クリップボード監視のみ利用の場合は許可は不要です。

## 操作

| 操作 | 内容 |
|---|---|
| 何かをコピー | 0.3 秒以内にテキスト / 画像 / ファイルが先頭に追加される |
| 範囲キャプチャ | メニューまたはパネルのハサミボタン。画面をドラッグして切り抜き（Esc でキャンセル）。初回は「画面収録」の許可が必要 |
| ⌘⇧2 ショートカット | メニューで ON/OFF。初期値は OFF |
| 画面先頭に固定 | メニューで ON/OFF。初期値は ON。OFF だと他ウィンドウの後ろに回る |
| カードにホバー → コピーボタン | クリップボードへ再コピー |
| カードをダブルクリック | 拡大プレビュー（← → で前後、Esc で閉じる、⌘C でコピー、テキスト選択可） |
| カードをドラッグ | 他アプリへ直接ドロップ |
| 右クリック | コピー / 拡大表示 / ブックマーク / 削除 / OCR テキストをコピー / Finder で表示 |
| ブックマーク | 常に一覧の先頭に固定。左端のグリップ（≡）をドラッグで並び替え。容量上限の削除対象外 |
| 検索欄 | 3 文字以上で本文と OCR 結果を全件対象に全文検索（SQLite FTS5 trigram） |
| メニューバー | 本体と別プロセス。パネル表示切替、画面先頭に固定、⌘⇧2、監視の一時停止、全消去、ログイン時起動、強制再起動。本体が固まってもメニューから強制再起動できる |

- 一覧は 100 件ずつの無限スクロール
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
  UI/HistoryListView.swift             検索欄、フッター、ブックマーク並び替えのドロップ処理
  UI/HistoryTableView.swift            NSTableView による仮想化一覧（差分更新、100 件ずつの追加読み込み）
  UI/ClipCardView.swift                カード（コピーボタン、グリップ、右クリック）
  UI/PreviewWindow.swift               ダブルクリックの拡大プレビュー
```

### 開発者向け: 大量データでの検証

1000 件・10000 件規模での安定性（メモリ・スクロール・OCR 連続完了・リサイズ）を確認するための投入スクリプトを同梱している。
ClipNote を一度起動してから終了し、次を実行する（実行中の ClipNote は終了しておくこと）。

```bash
bin/seed_demo.sh 1000  --images 200  --bookmarks 30  --huge 10 --pending-ocr 100   # 1000 件
bin/seed_demo.sh 10000 --images 1500 --bookmarks 300 --huge 30 --pending-ocr 500   # 10000 件
bin/seed_demo.sh --reset                                                            # 投入分だけ削除
```

`--huge` は 1 件あたり数十万文字のテキスト、`--pending-ocr` は起動直後に OCR が連続実行される未処理画像の数。
画像は `Resources/AppIcon-1024.png` を縮小したものをハードリンクで並べるのでディスクは消費しない。

## ライセンス

[MIT License](LICENSE) © 2026 obdist-hsp
