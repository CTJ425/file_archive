#!/bin/bash
# ============================================================================
# sync_archive.sh
#
# 用途：在 Synology DSM 上，把來源（透過 CIFS 掛載的 A PC 分享夾，或本機資料夾）
#       中的 IPCAM 影片/PDF 安全搬移（copy → verify → delete source）到 NAS 本機
#       封存目錄，並清除 NAS 上超過保留期限的舊檔。每次執行寫入每日封存 log（txt）
#       並更新一份易讀的 summary_time.html。
#
# 兩階段職責分開：
#   1. 封存階段（SRC → DST）：只負責搬移，完全不做保留期判斷。目標單純是
#      釋放來源空間、NAS 上有一份。
#   2. 保留階段（只對 DST）：檔案該不該留，一律在 NAS 上決定。
#   因此來源上已超過保留期的舊檔會照樣搬過去、再由保留階段刪除（log 兩筆都留）。
#
# 設計要點：
#   - 以 rsync --remove-source-files 達成「類似 mv」的安全語義：每個檔完整成功
#     傳輸後才刪來源，中途失敗只保留來源、不遺失資料。
#   - 只搬「基準日 00:00 之前」的檔（以檔案 mtime 判斷），今天產生中的檔不碰。
#   - 來源健康檢查失敗只跳過封存階段並記 ERROR，$DST 的保留期清理照常執行
#     （否則來源離線多久，NAS 就有多久不清理），最後仍以非零結束並發通知。
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

# 必要變數檢查：漏定義時給明確錯誤，而不是讓 set -u 丟出難懂的 unbound variable
for _v in SRC DST LOG_DIR; do
    if [ -z "${!_v:-}" ]; then
        echo "ERROR: 設定檔缺少必要變數 $_v: $CONF" >&2
        exit 2
    fi
done

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
: "${REQUIRE_MOUNTPOINT:=0}"

# --- 準備 log 與統計變數 ------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/sync_$(date +%F).log"
SUMMARY_TSV="$LOG_DIR/summary.tsv"
SUMMARY_HTML="$LOG_DIR/summary_time.html"
LOCKFILE="$LOG_DIR/.sync_archive.lock"
FILELIST="$(mktemp "${TMPDIR:-/tmp}/sync_archive.XXXXXX")"

# 執行中標記：開跑時寫入、收尾時刪除，summary_time.html 看到它就在最上面多畫一列
# 「PROG（執行中）」。內容一行 TSV：RUN_ID<TAB>開始epoch<TAB>PID<TAB>DRY_RUN。
# MARKED_RUNNING 保證「只刪自己寫的那份」—— cleanup 的 EXIT trap 在搶鎖之前就掛上了，
# 沒有這個旗標，搶不到鎖而提早結束的實例會把「正在跑的另一個實例」的標記刪掉。
RUNNING_MARKER="$LOG_DIR/.running"
MARKED_RUNNING=0

# 逐檔明細：每次執行累積到暫存檔，成功收尾時才落地成 details/<執行時間>.tsv，
# 供 summary_time.html 產生可展開的細項。格式：動作<TAB>位元組<TAB>路徑
DETAIL_DIR="$LOG_DIR/details"
DETAIL_TMP="$(mktemp "${TMPDIR:-/tmp}/sync_detail.XXXXXX")"
RSYNC_OUT="$(mktemp "${TMPDIR:-/tmp}/sync_rsyncout.XXXXXX")"
DETAIL_RUNS=30        # HTML 中 embed 明細的執行筆數（同時也是 details/ 保留的檔數）
DETAIL_MAX_LINES=2000 # 單次執行最多保留幾筆明細，避免大量搬移時檔案爆掉
# 每次執行的唯一識別（時間＋PID）。不能只用時間 —— 同一秒內結束的兩次執行會撞名，
# 導致後者覆蓋前者、或兩列摘要指向同一份明細。
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"

detail() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$DETAIL_TMP" 2>/dev/null; }

# 供 summary 使用的全域統計（die 也會用到）
MOVE_COUNT=0; MOVE_BYTES=0; DEL_COUNT=0; DEL_BYTES=0; RC=0
# 來源不健康（未掛載／目錄不存在）時設為 1：跳過封存階段，但保留階段照跑
SRC_UNAVAILABLE=0; SRC_ERR=""
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
    local ts; ts="$(date '+%F %T')"
    # 第 10 欄放 RUN_ID 供 HTML 找到對應明細檔。舊紀錄的第 10 欄是已停用的
    # skipped 計數，會被當成找不到的 RUN_ID → 該列單純不可展開，不會錯亂。
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$MOVE_COUNT" "$MOVE_BYTES" \
        "$DEL_COUNT" "$DEL_BYTES" "$RC" "$dur" "$DRY_RUN" "$status" "$RUN_ID" \
        >> "$SUMMARY_TSV" 2>/dev/null

    if [ -s "$DETAIL_TMP" ]; then
        mkdir -p "$DETAIL_DIR" 2>/dev/null
        local dfile total
        dfile="$DETAIL_DIR/$RUN_ID.tsv"
        total=$(wc -l < "$DETAIL_TMP")
        if [ "$total" -gt "$DETAIL_MAX_LINES" ]; then
            head -n "$DETAIL_MAX_LINES" "$DETAIL_TMP" > "$dfile" 2>/dev/null
            printf 'TRUNCATED\t0\t（僅顯示前 %s 筆，本次共 %s 筆，完整紀錄見 %s）\n' \
                "$DETAIL_MAX_LINES" "$total" "${LOG##*/}" >> "$dfile" 2>/dev/null
        else
            cp "$DETAIL_TMP" "$dfile" 2>/dev/null
        fi
        # 只留最近 DETAIL_RUNS 份，與 HTML 實際會展開的筆數一致
        ls -1t "$DETAIL_DIR"/*.tsv 2>/dev/null | tail -n +$(( DETAIL_RUNS + 1 )) \
            | while IFS= read -r _old; do rm -f "$_old" 2>/dev/null; done
    fi

    # 先清掉執行中標記再重繪：否則同一頁會同時出現 PROG 列與這次的正式列
    finish_running_marker
    render_summary_html
}

# HTML 逸出：路徑可能含 & < > 等字元，直接塞進 HTML 會破壞版面甚至截斷內容。
# 引號也要逸出 —— 狀態訊息（含來源路徑）會放進 title="..." 屬性，路徑裡一個雙引號
# 就能提前結束屬性。文字節點裡的 &quot; / &#39; 瀏覽器一樣顯示成原字元，不影響閱讀。
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# 由 SUMMARY_TSV 產生自足（inline CSS、支援深/淺色）的 summary_time.html
#
# 只在每次執行「收尾」時呼叫（append_summary），且先寫暫存檔再 mv 過去 ——
# mv 是同檔案系統上的原子操作，使用者永遠不會看到寫到一半的頁面，也不會在
# 搬移還在跑的時候看到半套數字而誤判。
render_summary_html() {
    # 首次執行時還沒有 TSV，但只要有執行中標記就該先把頁面（含 PROG 列）畫出來；
    # 頁面已存在時也一律重畫，否則首次執行被中斷後，頁面會停在撤不掉的 PROG 列。
    [ -f "$SUMMARY_TSV" ] || [ -f "$RUNNING_MARKER" ] || [ -f "$SUMMARY_HTML" ] || return 0
    local rows=""
    [ -f "$SUMMARY_TSV" ] && rows="$(tail -n 200 "$SUMMARY_TSV" | tac)"
    local out_tmp="$SUMMARY_HTML.tmp.$$"
    local row_idx=0
    {
        cat <<'HTML_HEAD'
<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Synology Sync — 執行摘要</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--fg:#1f2328;--mut:#57606a;--bd:#d0d7de;--ok:#1a7f37;--err:#cf222e;--dry:#9a6700;--run:#0969da;--hd:#eaeef2}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--mut:#9198a1;--bd:#30363d;--ok:#3fb950;--err:#f85149;--dry:#d29922;--run:#4493f8;--hd:#21262d}}
*{box-sizing:border-box}body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,"Segoe UI",Roboto,"Noto Sans TC",sans-serif}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--mut);font-size:13px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;overflow:hidden;max-width:1040px;margin:0 auto}
.wrap{overflow-x:auto}
.grid{min-width:900px}
/* 每欄都給「最小寬度 + fr 比例」：最小寬度保證內容放得下（例如第一欄要容得下
   「▸ 2026-07-24 22:14:39」約 185px），剩餘空間再按比例分給各欄，卡片內不會留下
   沒人吃的空白，也不會像全塞給單一欄那樣把時間欄拉得過寬。狀態欄比例給大一點，
   因為 ERROR 的訊息最長。 */
.row{display:grid;font-size:14px;align-items:center;gap:0;
     grid-template-columns:minmax(185px,1.5fr) minmax(120px,1.4fr) minmax(88px,1fr)
                           minmax(96px,1fr) minmax(88px,1fr) minmax(96px,1fr)
                           minmax(66px,.8fr) minmax(72px,.8fr)}
.row>span{padding:10px 12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row>span.num{text-align:right;font-variant-numeric:tabular-nums}
.hdr{background:var(--hd);color:var(--mut);font-weight:600;border-bottom:1px solid var(--bd);
     position:sticky;top:0;z-index:1}
details.run{border-bottom:1px solid var(--bd)}
details.run:last-of-type{border-bottom:none}
details.run>summary{list-style:none;cursor:pointer}
details.run>summary::-webkit-details-marker{display:none}
details.run>summary:hover{background:color-mix(in srgb,var(--fg) 4%,transparent)}
details.run[open]>summary{background:color-mix(in srgb,var(--fg) 6%,transparent)}
/* 沒有明細可看的列：外觀一致但不可展開，也不給游標暗示 */
.norow{border-bottom:1px solid var(--bd)}.norow:last-child{border-bottom:none}
.caret{display:inline-block;width:12px;color:var(--mut);transition:transform .15s}
details.run[open] .caret{transform:rotate(90deg)}
.det{padding:4px 14px 14px;background:color-mix(in srgb,var(--fg) 3%,transparent)}
.det table{border-collapse:collapse;width:100%;font-size:12.5px;
           font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
.det th,.det td{padding:4px 8px;text-align:left;border-bottom:1px solid var(--bd);white-space:nowrap}
.det td.p{white-space:normal;word-break:break-all;font-family:inherit}
.det td.n{text-align:right;font-variant-numeric:tabular-nums;color:var(--mut)}
.det tr:last-child td{border-bottom:none}
.det .scroll{max-height:420px;overflow:auto}
.act{display:inline-block;padding:1px 7px;border-radius:4px;font-size:11px;font-weight:600}
.a-mv{color:var(--ok);background:color-mix(in srgb,var(--ok) 14%,transparent)}
.a-dl{color:var(--err);background:color-mix(in srgb,var(--err) 14%,transparent)}
.a-tr{color:var(--dry);background:color-mix(in srgb,var(--dry) 14%,transparent)}
.nodet{color:var(--mut);font-size:12.5px;padding:10px 2px}
/* ERROR 的訊息可能很長（含路徑）。max-width+ellipsis 讓它在欄內收成「…」，
   而不是被外層 overflow:hidden 硬切成半個字；完整內容放在 title，滑過去看得到 */
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:600;
       max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:middle}
.b-ok{color:var(--ok);background:color-mix(in srgb,var(--ok) 15%,transparent)}
.b-err{color:var(--err);background:color-mix(in srgb,var(--err) 15%,transparent)}
.b-dry{color:var(--dry);background:color-mix(in srgb,var(--dry) 15%,transparent)}
/* 執行中：呼吸動畫表示這一列還活著（尊重使用者的減少動態偏好） */
.b-run{color:var(--run);background:color-mix(in srgb,var(--run) 15%,transparent);
       animation:pulse 1.8s ease-in-out infinite}
@keyframes pulse{50%{opacity:.55}}
@media (prefers-reduced-motion:reduce){.b-run{animation:none}}
.dash{color:var(--mut)}
.foot{color:var(--mut);font-size:12px;text-align:center;margin:16px auto 0;max-width:1040px}
</style></head><body>
<h1>Synology Sync — 執行摘要</h1>
HTML_HEAD
        echo "<div class=\"sub\">最後更新：$(date '+%F %T')　·　來源 <code>$(printf '%s' "$SRC" | html_escape)</code> → 封存 <code>$(printf '%s' "$DST" | html_escape)</code>　·　顯示最近 200 筆，點列可展開逐檔明細</div>"
        echo '<div class="card"><div class="wrap"><div class="grid">'
        echo '<div class="row hdr"><span>執行時間</span><span>狀態</span><span class="num">搬移檔數</span><span class="num">搬移量</span><span class="num">刪除檔數</span><span class="num">釋放量</span><span class="num">rsync</span><span class="num">耗時</span></div>'

        # 執行中列：數字一律留白（—），避免看到跑到一半的半套數字；只有耗時由頁面上的
        # JS 依開始時間即時遞增。用 norow 讓它外觀一致但不可展開，row_idx 不遞增
        # （row_idx 是明細檔的名額計數，這一列本來就沒有明細）。
        if [ -f "$RUNNING_MARKER" ]; then
            local r_id r_start r_pid r_dry r_when
            # r_id/r_pid/r_dry 只是把欄位讀完，這裡用不到（少讀會讓後面的欄位被併進來）
            # shellcheck disable=SC2034
            IFS=$'\t' read -r r_id r_start r_pid r_dry < "$RUNNING_MARKER"
            if [ -n "${r_start:-}" ]; then
                r_when="$(date -d "@$r_start" '+%F %T' 2>/dev/null)"
                printf '<div class="row norow"><span><span class="caret"></span> %s</span><span><span class="badge b-run">PROG</span></span><span class="num dash">—</span><span class="num dash">—</span><span class="num dash">—</span><span class="num dash">—</span><span class="num dash">—</span><span class="num"><span class="ela" data-start="%s">—</span></span></div>\n' \
                    "${r_when:-執行中}" "$r_start"
            fi
        fi
        # 第 10 欄＝RUN_ID（舊紀錄是已停用的 skipped 計數，找不到明細檔而已）。
        # legacy 這個變數是為了吃掉舊紀錄的第 11 欄，少讀會讓它被併進 status 造成錯亂。
        # shellcheck disable=SC2034
        while IFS=$'\t' read -r dt mc mb dc db rc dur dry status runid legacy; do
            [ -z "$dt" ] && continue
            row_idx=$(( row_idx + 1 ))
            local cls="b-ok" label="$status"
            # 失敗優先判定：演練模式若 rsync 出錯，仍必須顯示成錯誤而非 DRYRUN
            case "$status" in
                ERROR*|*rc=*) cls="b-err";;
                DRYRUN*)      cls="b-dry";;
                OK*)
                    if [ "$dry" = 1 ]; then cls="b-dry"; label="DRYRUN"; else cls="b-ok"; fi
                    ;;
            esac

            # 只有最近 DETAIL_RUNS 筆會留有明細檔；找不到就渲染成不可展開的一般列
            local dfile has_det=0
            dfile="$DETAIL_DIR/$runid.tsv"
            [ -n "$runid" ] && [ "$row_idx" -le "$DETAIL_RUNS" ] && [ -s "$dfile" ] && has_det=1

            # 逸出一次就好：同時當徽章文字與 title（長訊息在欄內收成「…」時靠 title 看全文）
            local cells esc_label
            esc_label="$(printf '%s' "$label" | html_escape)"
            cells="$(printf '<span>%s%s</span><span><span class="badge %s" title="%s">%s</span></span><span class="num">%s</span><span class="num">%s</span><span class="num">%s</span><span class="num">%s</span><span class="num">%s</span><span class="num">%ss</span>' \
                "$([ "$has_det" = 1 ] && printf '<span class="caret">&#9656;</span> ' || printf '<span class="caret"></span> ')" \
                "$dt" "$cls" "$esc_label" "$esc_label" \
                "$mc" "$(human "$mb")" "$dc" "$(human "$db")" "$rc" "$dur")"

            if [ "$has_det" = 0 ]; then
                printf '<div class="row norow">%s</div>\n' "$cells"
                continue
            fi

            printf '<details class="run"><summary><div class="row">%s</div></summary>\n' "$cells"
            echo '<div class="det"><div class="scroll"><table>'
            echo '<tr><th>動作</th><th>大小</th><th>路徑</th></tr>'
            while IFS=$'\t' read -r act sz path; do
                [ -z "$act" ] && continue
                local acls="a-mv"
                case "$act" in
                    DELETE)    acls="a-dl";;
                    TRUNCATED) acls="a-tr";;
                esac
                printf '<tr><td><span class="act %s">%s</span></td><td class="n">%s</td><td class="p">%s</td></tr>\n' \
                    "$acls" "$act" \
                    "$([ "$act" = TRUNCATED ] && printf '—' || human "$sz")" \
                    "$(printf '%s' "$path" | html_escape)"
            done < "$dfile"
            echo '</table></div></div></details>'
        done <<< "$rows"
        # 一筆完整紀錄都還沒有，又不在執行中：給一句話，不要只留一個空表頭
        if [ "$row_idx" = 0 ] && [ ! -f "$RUNNING_MARKER" ]; then
            echo '<div class="nodet" style="padding:14px">尚無完整執行紀錄。</div>'
        fi
        echo '</div></div></div>'
        echo '<div class="foot">由 sync_archive.sh 自動產生　·　執行一開跑就會多出一列 <strong>PROG</strong>（執行中，數字留白只跑耗時），<strong>正式數字要等該次完整收尾才寫入</strong>，不會看到半套數字<br>逐檔明細保留最近 '"$DETAIL_RUNS"' 次執行；更早的紀錄請見同目錄 sync_YYYY-MM-DD.log</div>'
        # 只有執行中才輸出這段；平常的頁面維持零 JS
        if [ -f "$RUNNING_MARKER" ]; then
            cat <<'HTML_JS'
<script>
(function(){
  var e=document.querySelector('.ela'); if(!e) return;
  var s=parseInt(e.dataset.start,10); if(!s) return;
  function tick(){
    // clamp：瀏覽器時鐘比 NAS 慢時不要出現負數
    var d=Math.max(0,Math.floor(Date.now()/1000-s)),h=Math.floor(d/3600),
        m=Math.floor(d%3600/60),x=d%60;
    e.textContent=h?h+'h'+m+'m'+x+'s':(m?m+'m'+x+'s':x+'s');
  }
  tick(); setInterval(tick,1000);
})();
</script>
HTML_JS
        fi
        echo '</body></html>'
    } > "$out_tmp" 2>/dev/null
    # 原子替換：讀取者只會看到舊版或新版，不會看到寫到一半的檔案
    mv -f "$out_tmp" "$SUMMARY_HTML" 2>/dev/null || rm -f "$out_tmp" 2>/dev/null
}

# 標記本次執行「進行中」並立刻重繪一次 —— 頁面因此在開跑當下就出現 PROG 列，
# 看的人才分得出「腳本還在跑」與「排程根本沒觸發」。
mark_running() {
    printf '%s\t%s\t%s\t%s\n' "$RUN_ID" "$START_TS" "$$" "$DRY_RUN" \
        > "$RUNNING_MARKER" 2>/dev/null && MARKED_RUNNING=1
    render_summary_html
}

# 清掉執行中標記；有清到才回傳 0，讓呼叫端決定要不要重繪。
# 只清自己寫的那份（見 MARKED_RUNNING 的說明）。
finish_running_marker() {
    [ "$MARKED_RUNNING" = 1 ] || return 1
    MARKED_RUNNING=0
    rm -f "$RUNNING_MARKER" 2>/dev/null
    return 0
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
cleanup() {
    rm -f "$FILELIST" "$DETAIL_TMP" "$RSYNC_OUT" "$SUMMARY_HTML.tmp.$$" 2>/dev/null
    # 沒經過 append_summary 就結束（被中斷等）：撤掉 PROG 列，頁面退回上一次完整執行的結果
    if finish_running_marker; then render_summary_html; fi
}
trap cleanup EXIT
# 被中斷時只記一行 log 後 exit，清理與重繪交給上面的 EXIT trap；
# 刻意不寫任何 summary.tsv 列 —— 沒跑完的執行不該留下一筆看似正式的紀錄。
trap 'log "ABORT  收到中斷訊號，未完成本次執行"; exit 130' INT TERM HUP

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

# 保留期基準在開跑時「定格」成一個固定時間點，讓長時間執行（大批首搬 rsync 可能
# 跑數小時）過程中的判定基準不會隨「當下」漂移，log 也才對得起來。
# 換算：-mtime +N 命中「年齡 ≥ (N+1)*24h」的檔，故定格點 = 開跑時刻 - (N+1) 天，
# 語義與 -mtime +RETENTION_DAYS 完全相同，只是凍結在 START_TS。
RET_CUTOFF="$(date -d "@$(( START_TS - (RETENTION_DAYS + 1) * 86400 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
[ -n "$RET_CUTOFF" ] || die "無法計算保留基準（date -d 不支援？）"

log "START  src=$SRC dst=$DST dry_run=$DRY_RUN 封存基準=<$CUTOFF 之前> retention=${RETENTION_DAYS}d 保留基準=<$RET_CUTOFF 之前刪>"

# 鎖已取得、基準日已算好，這裡就把頁面標成執行中（含來源掛掉那種慢路徑也涵蓋得到）
mark_running

# --- 前置健康檢查 -------------------------------------------------------------
# 來源的問題「只」讓封存階段停擺，不影響 NAS 端的保留期清理 ——
# A PC 關機或 CIFS 掉線期間，$DST 的清理仍須照常運作，否則來源離線多久，
# NAS 就有多久不清理。因此這裡不呼叫 die，改成記錄後設旗標往下走。
#
# REQUIRE_MOUNTPOINT=1：要求 $SRC 必須是掛載點。CIFS 部署建議開啟——分享夾沒掛上時
#   掛載點只是個空目錄，不擋下來會誤以為「沒東西可搬」而靜默空轉。
# REQUIRE_MOUNTPOINT=0（預設）：來源是本機資料夾的情境，只要求目錄存在即可。
if [ "$REQUIRE_MOUNTPOINT" = 1 ]; then
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$SRC" 2>/dev/null || \
            { SRC_UNAVAILABLE=1; SRC_ERR="來源不是掛載點或未掛載: $SRC"; }
    else
        mount | grep -qF " on $SRC " || \
            { SRC_UNAVAILABLE=1; SRC_ERR="來源未在 mount 清單中: $SRC"; }
    fi
fi
if [ "$SRC_UNAVAILABLE" = 0 ] && [ ! -d "$SRC" ]; then
    SRC_UNAVAILABLE=1; SRC_ERR="來源目錄不存在: $SRC"
fi
if [ "$SRC_UNAVAILABLE" = 1 ]; then
    log "ERROR  $SRC_ERR"
    log "INFO   跳過封存階段；$DST 的保留期清理仍照常執行"
fi

# 目的地問題則兩個階段都做不了，維持中止
mkdir -p "$DST" 2>/dev/null
_probe="$DST/.write_test_$$"
if ! ( : > "$_probe" ) 2>/dev/null; then
    die "目的地不可寫: $DST"
fi
rm -f "$_probe"

# --- 封存階段（安全 mv）：只負責把來源搬到 $DST，不做任何保留期判斷 -----------
# 職責分工：這一階段的目標單純是「釋放來源空間、NAS 上有一份」。
# 檔案該不該留，一律由下面的保留階段在 $DST 上決定。
if [ "$SRC_UNAVAILABLE" = 0 ]; then
    cd "$SRC" || die "無法進入來源目錄: $SRC"

    # 待搬清單：mtime 早於基準日（! -newermt = 不比基準新 = 基準日之前），排除暫存檔
    find . -type f ! -newermt "$CUTOFF" ! -name '*.tmp' -print0 > "$FILELIST"

    # 統計待搬位元組（此時來源檔仍在）
    while IFS= read -r -d '' f; do
        sz=$(stat -c %s "$SRC/$f" 2>/dev/null || echo 0)
        MOVE_BYTES=$(( MOVE_BYTES + sz ))
    done < "$FILELIST"
    MOVE_COUNT=$(tr -cd '\0' < "$FILELIST" | wc -c)

    log "SCAN   找到 $MOVE_COUNT 個符合基準的檔，共 $(human "$MOVE_BYTES")"

    if [ "$MOVE_COUNT" -gt 0 ]; then
        RSYNC_OPTS=(-a --from0 --files-from="$FILELIST" --out-format='MOVE %l %n')
        if [ "$DRY_RUN" = 1 ]; then
            RSYNC_OPTS+=(--dry-run)
            log "DRYRUN 以下為將搬移清單（未實際搬移/刪除）"
        else
            RSYNC_OPTS+=(--remove-source-files)
        fi

        # 先接到暫存檔：log 要完整原樣保留，明細則另外抽出 MOVE 行轉成 TSV
        rsync "${RSYNC_OPTS[@]}" "$SRC/" "$DST/" > "$RSYNC_OUT" 2>&1
        RC=$?
        cat "$RSYNC_OUT" >> "$LOG" 2>/dev/null
        # 只取檔案（略過結尾為 / 的目錄項）；用 index 定位避免路徑含空白時被切斷
        awk -F'\n' '
            /^MOVE /{
                split($0, a, " ")
                sz = a[2]
                rest = substr($0, index($0, sz) + length(sz) + 1)
                if (rest !~ /\/$/) printf "MOVE\t%s\t%s\n", sz, rest
            }' "$RSYNC_OUT" >> "$DETAIL_TMP" 2>/dev/null

        if [ "$RC" -ne 0 ]; then
            log "WARN   rsync 退出碼=$RC（已成功傳輸的檔仍安全落地；未完成者保留於來源）"
        fi

        if [ "$DRY_RUN" != 1 ]; then
            prune_moved_src_dirs
        fi
    fi
fi

# --- 保留階段：只對 $DST，依檔案原始 mtime 判定，超過保留期就刪 ----------------
# 這一階段完全不依賴來源 —— 即使 A PC 離線、封存階段被跳過，NAS 上的清理照常執行。
# 保留 1 年（RETENTION_DAYS=365）→ 年齡達 366 天的檔即刪除。
if [ "$DRY_RUN" = 1 ]; then
    log "DRYRUN 以下為將刪除（>${RETENTION_DAYS}天）清單（未實際刪除）"
    while IFS=$'\t' read -r sz rel; do
        log "DELETE $sz $DST/$rel"
        detail DELETE "$sz" "$rel"
        DEL_COUNT=$(( DEL_COUNT + 1 )); DEL_BYTES=$(( DEL_BYTES + sz ))
    done < <(find "$DST" -type f ! -newermt "$RET_CUTOFF" -printf '%s\t%P\n' 2>/dev/null)
else
    while IFS=$'\t' read -r sz rel; do
        log "DELETE $sz $DST/$rel"
        detail DELETE "$sz" "$rel"
        DEL_COUNT=$(( DEL_COUNT + 1 )); DEL_BYTES=$(( DEL_BYTES + sz ))
    done < <(find "$DST" -type f ! -newermt "$RET_CUTOFF" -printf '%s\t%P\n' -delete 2>/dev/null)
    find "$DST" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# --- log 自我歸檔清理 ---------------------------------------------------------
find "$LOG_DIR" -maxdepth 1 -name 'sync_*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

# --- 收尾 summary（txt log + summary_time.html） -----------------------------
DUR=$(( $(date +%s) - START_TS ))
log "SUMMARY moved=$MOVE_COUNT movedBytes=$MOVE_BYTES deleted=$DEL_COUNT deletedBytes=$DEL_BYTES rsync_rc=$RC dur=${DUR}s dry_run=$DRY_RUN srcUnavailable=$SRC_UNAVAILABLE"

# 失敗優先於 DRY_RUN 判定：演練的目的就是在上線前抓出環境問題
# （例如缺 rsync 會得到 rc=127），若一律記成 DRYRUN 並 exit 0 就驗不出來。
if [ "$SRC_UNAVAILABLE" = 1 ]; then
    append_summary "ERROR: $SRC_ERR"
elif [ "$RC" -ne 0 ]; then
    append_summary "ERROR: rsync rc=$RC"
elif [ "$DRY_RUN" = 1 ]; then
    append_summary "DRYRUN"
else
    append_summary "OK"
fi

# 來源不可用時保留階段已經跑完，但仍須以非零結束並通知，否則問題會被無聲吃掉
if [ "$SRC_UNAVAILABLE" = 1 ] || [ "$RC" -ne 0 ]; then
    _status_msg="rsync rc=$RC"
    [ "$SRC_UNAVAILABLE" = 1 ] && _status_msg="$SRC_ERR"
    if [ "$NOTIFY_ON_ERROR" = 1 ] && [ "$DRY_RUN" != 1 ] && [ -x /usr/syno/bin/synonotify ]; then
        /usr/syno/bin/synonotify "SYNOScheduledTaskComplete" \
            "{\"%TASKNAME%\":\"sync_archive\",\"%STATUS%\":\"$_status_msg\"}" 2>/dev/null || true
    fi
    [ "$SRC_UNAVAILABLE" = 1 ] && exit 1
    exit "$RC"
fi

exit 0
