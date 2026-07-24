#!/bin/bash
# ============================================================================
# sync_archive.sh
#
# 用途：在 Synology DSM 上，把「透過 CIFS 掛載的 A PC 分享夾」中的 IPCAM 影片/PDF
#       安全搬移（copy → verify → delete source）到 NAS 本機封存目錄，並清除
#       NAS 上超過保留期限的舊檔。每次執行寫入每日封存 log（txt）並更新一份
#       易讀的 summary_time.html。
#
# 設計要點：
#   - 以 rsync --remove-source-files 達成「類似 mv」的安全語義：每個檔完整成功
#     傳輸後才刪來源，中途失敗只保留來源、不遺失資料。
#   - 只搬「基準日 00:00 之前」的檔（以檔案 mtime 判斷），今天產生中的檔不碰。
#   - 掛載/哨兵健康檢查失敗即中止，絕不因來源「看起來是空的」而誤動作。
#   - 保留刪除只作用於 $DST（本機），程式碼層級與來源分離，杜絕誤刪來源。
#   - flock 單一實例鎖，避免排程重疊。
#
# 執行：bash sync_archive.sh [設定檔路徑]
#       未指定設定檔時，預設讀取與本腳本同目錄的 sync_archive.conf
#       以 root 執行（掛載存取與刪除需要）。
# ============================================================================

set -u
set -o pipefail

# --- 定位並載入設定 -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$SCRIPT_DIR/sync_archive.conf}"

if [ ! -f "$CONF" ]; then
    echo "ERROR: 找不到設定檔: $CONF" >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$CONF"

# 去掉路徑尾端斜線：mountpoint 不在時的 fallback 是比對 `mount` 輸出的
# " on <路徑> "，帶尾斜線會比不到而誤判成「未掛載」。
while [ "$SRC" != "/" ] && [ "${SRC%/}" != "$SRC" ]; do SRC="${SRC%/}"; done
while [ "$DST" != "/" ] && [ "${DST%/}" != "$DST" ]; do DST="${DST%/}"; done

# 設定必要變數的預設值（設定檔未定義時的保險）
: "${ARCHIVE_BEFORE_DAYS_AGO:=0}"
: "${RETENTION_DAYS:=365}"
: "${LOG_RETENTION_DAYS:=90}"
: "${DRY_RUN:=0}"
: "${NOTIFY_ON_ERROR:=0}"

# --- 準備 log 與統計變數 ------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/sync_$(date +%F).log"
SUMMARY_TSV="$LOG_DIR/summary.tsv"
SUMMARY_HTML="$LOG_DIR/summary_time.html"
LOCKFILE="$LOG_DIR/.sync_archive.lock"
FILELIST="$(mktemp "${TMPDIR:-/tmp}/sync_archive.XXXXXX")"
SKIPLIST="$(mktemp "${TMPDIR:-/tmp}/sync_archive_skip.XXXXXX")"

# 供 summary 使用的全域統計（die 也會用到）
MOVE_COUNT=0; MOVE_BYTES=0; DEL_COUNT=0; DEL_BYTES=0; RC=0
SKIP_COUNT=0; SKIP_BYTES=0
START_TS=$(date +%s)

log()  { echo "$(date '+%F %T')  $*" >> "$LOG"; }

# 位元組轉人類可讀（awk，DSM 無 numfmt 也可用）
human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB",u," "); s=1;
        while (b>=1024 && s<6){ b/=1024; s++ }
        if (s==1) printf "%d %s", b, u[s]; else printf "%.1f %s", b, u[s];
    }'
}

# 追加一筆 summary 紀錄到 TSV 並重新產生 HTML（任何結束路徑都會呼叫）
append_summary() {
    local status="$1"
    local dur=$(( $(date +%s) - START_TS ))
    # 跳過數放在 status 之後（第 10 欄），舊格式的 9 欄紀錄仍可正常讀取
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%F %T')" "$MOVE_COUNT" "$MOVE_BYTES" \
        "$DEL_COUNT" "$DEL_BYTES" "$RC" "$dur" "$DRY_RUN" "$status" \
        "$SKIP_COUNT" \
        >> "$SUMMARY_TSV" 2>/dev/null
    render_summary_html
}

# 由 SUMMARY_TSV 產生自足（inline CSS、支援深/淺色）的 summary_time.html
render_summary_html() {
    [ -f "$SUMMARY_TSV" ] || return 0
    local rows; rows="$(tail -n 200 "$SUMMARY_TSV" | tac)"
    {
        cat <<'HTML_HEAD'
<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Synology Sync — 執行摘要</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--fg:#1f2328;--mut:#57606a;--bd:#d0d7de;--ok:#1a7f37;--err:#cf222e;--dry:#9a6700;--hd:#eaeef2}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--mut:#9198a1;--bd:#30363d;--ok:#3fb950;--err:#f85149;--dry:#d29922;--hd:#21262d}}
*{box-sizing:border-box}body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,"Segoe UI",Roboto,"Noto Sans TC",sans-serif}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--mut);font-size:13px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;overflow:hidden;max-width:1000px;margin:0 auto}
.wrap{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px}
th,td{padding:10px 14px;text-align:left;white-space:nowrap;border-bottom:1px solid var(--bd)}
th{background:var(--hd);color:var(--mut);font-weight:600;position:sticky;top:0}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:600}
.b-ok{color:var(--ok);background:color-mix(in srgb,var(--ok) 15%,transparent)}
.b-err{color:var(--err);background:color-mix(in srgb,var(--err) 15%,transparent)}
.b-dry{color:var(--dry);background:color-mix(in srgb,var(--dry) 15%,transparent)}
.foot{color:var(--mut);font-size:12px;text-align:center;margin:16px auto 0;max-width:1000px}
</style></head><body>
<h1>Synology Sync — 執行摘要</h1>
HTML_HEAD
        echo "<div class=\"sub\">最後更新：$(date '+%F %T')　·　來源 <code>${SRC}</code> → 封存 <code>${DST}</code>　·　顯示最近 200 筆</div>"
        echo '<div class="card"><div class="wrap"><table>'
        echo '<thead><tr><th>執行時間</th><th>狀態</th><th class="num">搬移檔數</th><th class="num">搬移量</th><th class="num">刪除檔數</th><th class="num">釋放量</th><th class="num">跳過(過舊)</th><th class="num">rsync</th><th class="num">耗時</th></tr></thead><tbody>'
        while IFS=$'\t' read -r dt mc mb dc db rc dur dry status skipped; do
            [ -z "$dt" ] && continue
            local cls="b-ok" label="$status"
            # 失敗優先判定：演練模式若 rsync 出錯，仍必須顯示成錯誤而非 DRYRUN
            case "$status" in
                ERROR*|*rc=*) cls="b-err";;
                DRYRUN*)      cls="b-dry";;
                OK*)
                    if [ "$dry" = 1 ]; then cls="b-dry"; label="DRYRUN"; else cls="b-ok"; fi
                    ;;
            esac
            printf '<tr><td>%s</td><td><span class="badge %s">%s</span></td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%ss</td></tr>\n' \
                "$dt" "$cls" "$label" "$mc" "$(human "$mb")" "$dc" "$(human "$db")" \
                "${skipped:-0}" "$rc" "$dur"
        done <<< "$rows"
        echo '</tbody></table></div></div>'
        echo '<div class="foot">由 sync_archive.sh 自動產生　·　詳細逐檔紀錄請見同目錄 sync_YYYY-MM-DD.log</div>'
        echo '</body></html>'
    } > "$SUMMARY_HTML" 2>/dev/null
}

die()  {
    log "ERROR  $*"
    append_summary "ERROR: $*"
    if [ "$NOTIFY_ON_ERROR" = 1 ] && [ -x /usr/syno/bin/synonotify ]; then
        /usr/syno/bin/synonotify "SYNOScheduledTaskComplete" \
            "{\"%TASKNAME%\":\"sync_archive\",\"%STATUS%\":\"$*\"}" 2>/dev/null || true
    fi
    exit 1
}
cleanup() { rm -f "$FILELIST" "$SKIPLIST" 2>/dev/null; }
trap cleanup EXIT

# 清理來源目錄：只針對「本輪搬移檔案的上層目錄（含其祖先）」嘗試 rmdir。
# rmdir 只在目錄確實空了才會成功，所以不會誤刪 IPCAM 仍在使用、或跨日剛建立
# 但尚未寫入的資料夾 —— 舊版的 find -type d -empty -delete 會無差別刪光。
# 反向排序讓子目錄先於父目錄處理，巢狀空目錄一次清乾淨。
#
# 兩層保護，缺一不可：
#   1. 來源根目錄 $SRC 永不觸及。
#   2. $SRC 底下第一層目錄（Enter_Leave / Enter_Leave_Records / ... 這類由
#      IPCAM 軟體建立的固定分類資料夾）一律保留。整個分類被搬空時，若放任
#      往上 rmdir 會把這些固定資料夾一起刪掉，攝影機下次要寫入就沒地方放。
#      只清第二層以下的日期資料夾這種本來就會輪替的目錄。
# 註：若來源結構是 $SRC/<日期>/檔案（日期就在第一層），日期資料夾會被保留、
#     不會清除，寧可留下空目錄也不動可能是固定結構的東西。
prune_moved_src_dirs() {
    local f d rel
    while IFS= read -r -d '' f; do
        d="${f%/*}"
        while [ -n "$d" ] && [ "$d" != "." ] && [ "$d" != "$f" ]; do
            rel="${d#./}"
            case "$rel" in
                */*) printf '%s\0' "$d" ;;   # 第二層以下，可清
                *)   break ;;                # 第一層固定分類資料夾，保留
            esac
            d="${d%/*}"
        done
    done < "$FILELIST" | sort -z -u -r | while IFS= read -r -d '' d; do
        rmdir "$SRC/$d" 2>/dev/null || true
    done
}

# --- 單一實例鎖（flock，退化為 mkdir） ---------------------------------------
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        log "SKIP   已有另一個實例在執行（flock），本次結束"
        exit 0
    fi
else
    if ! mkdir "$LOCKFILE.d" 2>/dev/null; then
        log "SKIP   已有另一個實例在執行（mkdir lock），本次結束"
        exit 0
    fi
    trap 'rmdir "$LOCKFILE.d" 2>/dev/null; cleanup' EXIT
fi

# --- 計算封存基準日（只搬此時刻之前的檔） ------------------------------------
CUTOFF="$(date -d "00:00:00 today - ${ARCHIVE_BEFORE_DAYS_AGO} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
[ -n "$CUTOFF" ] || die "無法計算基準日（date -d 不支援？）"

log "START  src=$SRC dst=$DST dry_run=$DRY_RUN 封存基準=<$CUTOFF 之前> retention=${RETENTION_DAYS}d"

# --- 前置健康檢查 -------------------------------------------------------------
if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$SRC" || die "來源不是掛載點或未掛載: $SRC"
else
    mount | grep -q " on $SRC " || die "來源未在 mount 清單中: $SRC"
fi
mkdir -p "$DST" 2>/dev/null
_probe="$DST/.write_test_$$"
if ! ( : > "$_probe" ) 2>/dev/null; then
    die "目的地不可寫: $DST"
fi
rm -f "$_probe"

# --- 搬移階段（安全 mv） ------------------------------------------------------
cd "$SRC" || die "無法進入來源目錄: $SRC"

# 待搬清單：mtime 早於基準日（! -newermt = 不比基準新 = 基準日之前），
# 但還沒老到「一搬過去就會被保留期刪掉」；排除暫存檔。
# 這裡的 -mtime +RETENTION_DAYS 與下方 $DST 保留刪除用的是同一個判斷式，
# 確保兩者邊界一致 —— 否則超過保留期的檔會被搬到 $DST 後於同一輪立刻刪除，
# 來源與封存同時消失，造成靜默的資料遺失。
find . -type f ! -newermt "$CUTOFF" ! -mtime +"$RETENTION_DAYS" \
    ! -name '*.tmp' -print0 > "$FILELIST"

# 過舊清單：只記錄與統計，不搬移也不刪除，原地留在來源等人工判斷。
# （保留期刪除永遠只作用於 $DST，絕不對來源動刀）
find . -type f ! -newermt "$CUTOFF" -mtime +"$RETENTION_DAYS" \
    ! -name '*.tmp' -print0 > "$SKIPLIST"

MOVE_COUNT=$(tr -cd '\0' < "$FILELIST" | wc -c)

# 先加總待搬位元組（此時來源檔仍在）
while IFS= read -r -d '' f; do
    sz=$(stat -c %s "$SRC/$f" 2>/dev/null || echo 0)
    MOVE_BYTES=$(( MOVE_BYTES + sz ))
done < "$FILELIST"

while IFS= read -r -d '' f; do
    sz=$(stat -c %s "$SRC/$f" 2>/dev/null || echo 0)
    SKIP_COUNT=$(( SKIP_COUNT + 1 )); SKIP_BYTES=$(( SKIP_BYTES + sz ))
    log "SKIPOLD $sz $f"
done < "$SKIPLIST"

log "SCAN   找到 $MOVE_COUNT 個符合基準的檔，共 $(human "$MOVE_BYTES")"
if [ "$SKIP_COUNT" -gt 0 ]; then
    log "WARN   另有 $SKIP_COUNT 個檔（$(human "$SKIP_BYTES")）mtime 已超過保留期 ${RETENTION_DAYS} 天，"
    log "WARN   未搬移亦未刪除，原地保留於來源（搬過去也會立刻被保留期刪掉），請人工處理"
fi

if [ "$MOVE_COUNT" -gt 0 ]; then
    RSYNC_OPTS=(-a --from0 --files-from="$FILELIST" --out-format='MOVE %l %n')
    if [ "$DRY_RUN" = 1 ]; then
        RSYNC_OPTS+=(--dry-run)
        log "DRYRUN 以下為將搬移清單（未實際搬移/刪除）"
    else
        RSYNC_OPTS+=(--remove-source-files)
    fi

    rsync "${RSYNC_OPTS[@]}" "$SRC/" "$DST/" >> "$LOG" 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
        log "WARN   rsync 退出碼=$RC（已成功傳輸的檔仍安全落地；未完成者保留於來源）"
    fi

    if [ "$DRY_RUN" != 1 ]; then
        prune_moved_src_dirs
    fi
fi

# --- 保留階段（只對 $DST，依原始 mtime） -------------------------------------
if [ "$DRY_RUN" = 1 ]; then
    log "DRYRUN 以下為將刪除（>${RETENTION_DAYS}天）清單（未實際刪除）"
    while IFS=' ' read -r sz path; do
        log "DELETE $sz $path"
        DEL_COUNT=$(( DEL_COUNT + 1 )); DEL_BYTES=$(( DEL_BYTES + sz ))
    done < <(find "$DST" -type f -mtime +"$RETENTION_DAYS" -printf '%s %p\n' 2>/dev/null)
else
    while IFS=' ' read -r sz path; do
        log "DELETE $sz $path"
        DEL_COUNT=$(( DEL_COUNT + 1 )); DEL_BYTES=$(( DEL_BYTES + sz ))
    done < <(find "$DST" -type f -mtime +"$RETENTION_DAYS" -printf '%s %p\n' -delete 2>/dev/null)
    find "$DST" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# --- log 自我歸檔清理 ---------------------------------------------------------
find "$LOG_DIR" -maxdepth 1 -name 'sync_*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

# --- 收尾 summary（txt log + summary_time.html） -----------------------------
DUR=$(( $(date +%s) - START_TS ))
log "SUMMARY moved=$MOVE_COUNT movedBytes=$MOVE_BYTES deleted=$DEL_COUNT deletedBytes=$DEL_BYTES skippedOld=$SKIP_COUNT skippedBytes=$SKIP_BYTES rsync_rc=$RC dur=${DUR}s dry_run=$DRY_RUN"

# rsync 失敗優先於 DRY_RUN 判定：演練的目的就是在上線前抓出環境問題
# （例如缺 rsync 會得到 rc=127），若一律記成 DRYRUN 並 exit 0 就驗不出來。
if [ "$RC" -ne 0 ]; then
    append_summary "ERROR: rsync rc=$RC"
elif [ "$DRY_RUN" = 1 ]; then
    append_summary "DRYRUN"
else
    append_summary "OK"
fi

if [ "$RC" -ne 0 ]; then
    if [ "$NOTIFY_ON_ERROR" = 1 ] && [ "$DRY_RUN" != 1 ] && [ -x /usr/syno/bin/synonotify ]; then
        /usr/syno/bin/synonotify "SYNOScheduledTaskComplete" \
            "{\"%TASKNAME%\":\"sync_archive\",\"%STATUS%\":\"rsync rc=$RC\"}" 2>/dev/null || true
    fi
    exit "$RC"
fi

exit 0
