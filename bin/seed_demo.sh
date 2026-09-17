#!/usr/bin/env bash
# ClipNote 開発者向け: 大量データ投入スクリプト（1000 件・10000 件での安定性検証用）
#
# 使い方:
#   bin/seed_demo.sh <count> [--images N] [--files N] [--bookmarks N] [--huge N] [--pending-ocr N]
#   bin/seed_demo.sh --reset          投入したデータだけを削除（content_hash が 'seed:' で始まる行と images/seed-*.png）
#
# 例:
#   bin/seed_demo.sh 1000  --images 200  --bookmarks 30  --huge 10 --pending-ocr 100
#   bin/seed_demo.sh 10000 --images 1500 --bookmarks 300 --huge 30 --pending-ocr 500
#
# 前提: ClipNote を一度起動して DB（スキーマ）ができていること。実行中は ClipNote を終了しておくこと。
# 画像は Resources/AppIcon-1024.png を sips で数サイズに縮小し、ハードリンクで images/ に並べる（ディスクを食わない）。
# --huge は 1 件あたり数十万文字のテキストで、FTS(trigram) の索引付けに時間がかかる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$HOME/Library/Containers/obdist.hsp.clipnote/Data/Library/Application Support/ClipNote"
DB="$DATA_DIR/clipnote.sqlite"
IMAGES="$DATA_DIR/images"
SRC_PNG="$ROOT/Resources/AppIcon-1024.png"

COUNT=0; N_IMAGES=0; N_FILES=0; N_BOOKMARKS=0; N_HUGE=0; N_PENDING=0; RESET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --images)      N_IMAGES="$2"; shift 2 ;;
    --files)       N_FILES="$2"; shift 2 ;;
    --bookmarks)   N_BOOKMARKS="$2"; shift 2 ;;
    --huge)        N_HUGE="$2"; shift 2 ;;
    --pending-ocr) N_PENDING="$2"; shift 2 ;;
    --reset)       RESET=1; shift ;;
    -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
    *)             COUNT="$1"; shift ;;
  esac
done

if pgrep -x ClipNote >/dev/null 2>&1; then
  echo "✗ ClipNote が起動中です。先に終了してください（bin/clipnote stop）" >&2; exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "✗ DB がありません: $DB" >&2
  echo "  ClipNote を一度起動してスキーマを作ってから実行してください" >&2; exit 1
fi
if ! sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')" >/dev/null 2>&1; then
  echo "✗ sqlite3 に FTS5(trigram) がありません" >&2; exit 1
fi
mkdir -p "$IMAGES"

if [[ $RESET -eq 1 ]]; then
  before=$(sqlite3 "$DB" "SELECT count(*) FROM items WHERE content_hash LIKE 'seed:%'")
  sqlite3 "$DB" "DELETE FROM items WHERE content_hash LIKE 'seed:%'; PRAGMA wal_checkpoint(TRUNCATE);"
  find "$IMAGES" -name 'seed-*.png' -delete
  echo "✓ seed データ ${before} 件を削除しました"
  [[ $COUNT -eq 0 ]] && exit 0
fi
if [[ $COUNT -le 0 ]]; then sed -n '2,15p' "$0"; exit 1; fi

# ---- 画像バリアント（幅×高さ）。sips が使えなければ原寸を使う ----
VARIANTS=("1200 800" "800 600" "640 360" "400 900" "320 200")
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
V_FILES=(); V_W=(); V_H=(); V_BYTES=()
for i in "${!VARIANTS[@]}"; do
  read -r w h <<<"${VARIANTS[$i]}"
  out="$TMP/v$i.png"
  if ! sips -z "$h" "$w" "$SRC_PNG" --out "$out" >/dev/null 2>&1; then
    cp "$SRC_PNG" "$out"; w=1024; h=1024
  fi
  V_FILES+=("$out"); V_W+=("$w"); V_H+=("$h"); V_BYTES+=("$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")")
done
NV=${#VARIANTS[@]}

# n を種別に割り当てる間隔（0 = その種別なし）
step() { local want=$1; if [[ $want -le 0 ]]; then echo 0; else echo $(( COUNT / want > 0 ? COUNT / want : 1 )); fi; }
STEP_IMG=$(step "$N_IMAGES"); STEP_FILE=$(step "$N_FILES"); STEP_HUGE=$(step "$N_HUGE")

case_wh() { # 引数 = バリアントごとの値 → CASE 式（macOS 標準 bash 3.2 でも動くよう nameref は使わない）
  local s="CASE (n / $STEP_IMG) % $NV" i=0
  for v in "$@"; do s="$s WHEN $i THEN $v"; i=$((i + 1)); done
  echo "$s END"
}
if [[ $STEP_IMG -gt 0 ]]; then
  IS_IMG="n % $STEP_IMG = 0"
  IMG_DELETED="($IS_IMG AND (n / $STEP_IMG) % 10 = 9)"          # 画像 10 枚に 1 枚は「容量上限で削除済み」
  IMG_PENDING="($IS_IMG AND (n / $STEP_IMG) <= $N_PENDING)"       # 新しい方から N 枚は OCR 未処理
  W_EXPR=$(case_wh "${V_W[@]}"); H_EXPR=$(case_wh "${V_H[@]}"); B_EXPR=$(case_wh "${V_BYTES[@]}")
else
  IS_IMG="0"; IMG_DELETED="0"; IMG_PENDING="0"; W_EXPR="NULL"; H_EXPR="NULL"; B_EXPR="0"
fi
IS_FILE=$([[ $STEP_FILE -gt 0 ]] && echo "n % $STEP_FILE = 1" || echo "0")
IS_HUGE=$([[ $STEP_HUGE -gt 0 ]] && echo "n % $STEP_HUGE = 2" || echo "0")

echo "▶ ${COUNT} 件を投入（画像≈${N_IMAGES} / ファイル≈${N_FILES} / 巨大テキスト≈${N_HUGE} / ブックマーク ${N_BOOKMARKS} / OCR 未処理≈${N_PENDING}）"
start=$(date +%s)
sqlite3 "$DB" <<SQL
PRAGMA journal_mode=WAL;
BEGIN;
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $COUNT),
rows AS (
  SELECT n,
    lower(hex(randomblob(16))) AS h,
    CASE WHEN $IS_IMG THEN 'image' WHEN $IS_FILE THEN 'file' ELSE 'text' END AS kind
  FROM seq
)
INSERT OR IGNORE INTO items
  (id, kind, text, image_file, image_w, image_h, image_bytes, image_deleted, ocr_text, content_hash, created_at, bookmark_order)
SELECT
  substr(h,1,8)||'-'||substr(h,9,4)||'-'||substr(h,13,4)||'-'||substr(h,17,4)||'-'||substr(h,21,12),
  kind,
  CASE kind
    WHEN 'text' THEN
      CASE WHEN $IS_HUGE
        THEN 'seed #' || n || ' 巨大テキスト ' || replace(hex(zeroblob(100000)), '0', 'あ') || ' ' || hex(randomblob(50000))
        ELSE 'seed #' || n || ' 決済画面の確認メモ。' || hex(randomblob(abs(random()) % 120 + 10)) || ' 管理システム側の対応要否を確認する。'
      END
    WHEN 'file' THEN '/Users/demo/Documents/seed-' || n || '.pdf' || char(10) || '/Users/demo/Downloads/請求書_' || n || '.xlsx'
      || CASE WHEN n % 2 = 0 THEN char(10) || '/Users/demo/Desktop/画面キャプチャ ' || n || '.png' ELSE '' END
    ELSE NULL
  END,
  CASE WHEN kind = 'image' AND NOT $IMG_DELETED THEN 'seed-' || n || '.png' END,
  CASE WHEN kind = 'image' THEN $W_EXPR END,
  CASE WHEN kind = 'image' THEN $H_EXPR END,
  CASE WHEN kind = 'image' AND NOT $IMG_DELETED THEN $B_EXPR ELSE 0 END,
  CASE WHEN kind = 'image' AND $IMG_DELETED THEN 1 ELSE 0 END,
  CASE WHEN kind = 'image' AND NOT $IMG_PENDING THEN
    CASE WHEN n % 4 = 0 THEN '' ELSE 'seed #' || n || ' OCR 結果サンプル 合計金額 ' || (n * 110) || ' 円 お支払い方法: クレジットカード' END
  END,
  'seed:' || n,
  CAST(strftime('%s', 'now') AS REAL) - n * 60.0,
  CASE WHEN n <= $N_BOOKMARKS THEN n * 1.0 END
FROM rows;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

# ---- 画像ファイル（ハードリンク。失敗したらコピー） ----
linked=0
while IFS='|' read -r file w; do
  [[ -z "$file" ]] && continue
  src=""
  for i in "${!V_W[@]}"; do [[ "${V_W[$i]}" == "$w" ]] && src="${V_FILES[$i]}" && break; done
  [[ -z "$src" ]] && src="${V_FILES[0]}"
  dst="$IMAGES/$file"
  [[ -e "$dst" ]] && continue
  ln "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
  linked=$((linked + 1))
done < <(sqlite3 "$DB" "SELECT image_file, image_w FROM items WHERE content_hash LIKE 'seed:%' AND image_file IS NOT NULL")

elapsed=$(( $(date +%s) - start ))
echo "✓ 完了 (${elapsed}s)  画像ファイル ${linked} 個"
sqlite3 -column -header "$DB" "
SELECT kind,
       count(*)                                         AS rows,
       sum(image_deleted)                               AS img_deleted,
       sum(kind='image' AND ocr_text IS NULL)           AS ocr_pending,
       sum(bookmark_order IS NOT NULL)                  AS bookmarks,
       sum(length(text) > 100000)                       AS huge_text
FROM items WHERE content_hash LIKE 'seed:%' GROUP BY kind;
SELECT count(*) AS total_items FROM items;"
