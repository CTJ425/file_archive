#!/bin/bash
# ============================================================================
# make_testdata.sh — 互動式產生 sync_archive.sh 的「來源」測試樹
#
# 依 WizTree 截圖的目錄結構產生測試檔案，重點在「檔名 + mtime + 目錄結構」，
# 讓封存腳本的 mtime 判斷邏輯可被真實驗證。互動問答會依序問：
#
#   1. 位置 — 要把測試資料產生在哪
#   2. 時間 — 日期範圍、是否含今天、是否產生超過保留期的過舊檔
#   3. 亂數 — 亂數種子、每日檔案數範圍、檔案大小範圍
#
# 產生的日期刻意跨越「今天 00:00」這條分界：
#   - 今天之前的資料夾        → 腳本應「搬移封存」並留在 NAS
#   - 今天的資料夾            → 腳本應「完全不動」
#   - 超過保留期(>RETENTION)  → 腳本應「照樣搬移，再由保留階段從 NAS 刪除」
#                               （log 會同時有 MOVE 與 DELETE 兩筆）
#
# 用法：
#   bash make_testdata.sh                 # 互動問答
#   bash make_testdata.sh /path/to/src    # 同上，但位置預設帶入
#   bash make_testdata.sh -y [/path]      # 全部用預設值，不問（給 CI/腳本用）
#
# 非互動時可用環境變數覆寫預設：
#   ROOT DATE_FROM DATE_TO INCLUDE_TODAY MAKE_OLD OLD_DAYS
#   SEED FILES_MIN FILES_MAX SIZE_MIN_KB SIZE_MAX_KB SITE_PREFIX CAM_ID FORCE
# ============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODAY="$(date +%F)"

# --- 參數解析 -----------------------------------------------------------------
ASSUME_YES=0
POS_ROOT=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        # 印出開頭的說明區塊（讀到第二條 ==== 分隔線為止，不寫死行號免得改註解就截斷）
        -h|--help) awk 'NR==1{next} /^# ={10,}/{if(s)exit; s=1; next} {print}' \
                       "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "未知選項: $arg" >&2; exit 2 ;;
        *)  POS_ROOT="$arg" ;;
    esac
done

# 沒有 tty（例如被管線呼叫）就不互動，避免卡住
INTERACTIVE=1
{ [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; } && INTERACTIVE=0

# --- 預設值（可由環境變數覆寫）------------------------------------------------
# 輸出目錄預設直接採用 sync_archive.conf 的 SRC —— 否則預設值與封存腳本實際讀取的
# 來源不一致，位置那題按 Enter 就會把資料產到別的地方，然後 sync 掃不到任何檔案。
CONF_FILE="$SCRIPT_DIR/sync_archive.conf"
DEFAULT_ROOT="$SCRIPT_DIR/testfile"
ROOT_FROM_CONF=0
if [ -f "$CONF_FILE" ]; then
    _conf_src=""
    while IFS= read -r _line; do
        case "$_line" in
            SRC=*)
                _conf_src="${_line#SRC=}"
                _conf_src="${_conf_src%\"}"; _conf_src="${_conf_src#\"}"
                _conf_src="${_conf_src%\'}"; _conf_src="${_conf_src#\'}"
                ;;
        esac
    done < "$CONF_FILE"
    if [ -n "$_conf_src" ]; then
        DEFAULT_ROOT="$_conf_src"
        ROOT_FROM_CONF=1
    fi
fi

: "${ROOT:=${POS_ROOT:-$DEFAULT_ROOT}}"
: "${DATE_FROM:=$(date -d "$TODAY - 30 days" +%F)}"
: "${DATE_TO:=$TODAY}"
: "${INCLUDE_TODAY:=y}"
: "${MAKE_OLD:=y}"
: "${OLD_DAYS:=400}"
: "${SEED:=$RANDOM}"
: "${FILES_MIN:=3}"
: "${FILES_MAX:=8}"
: "${SIZE_MIN_KB:=1}"
: "${SIZE_MAX_KB:=64}"
: "${SITE_PREFIX:=SiteA}"
: "${CAM_ID:=CAM01}"
: "${FORCE:=0}"

# -y 的語意就是「一律同意」，含同意清空既有目錄；
# 沒有 tty 也沒給 -y 時則維持保守：確認題一律當成 n，寧可不動檔。
[ "$ASSUME_YES" = 1 ] && FORCE=1

# --- 問答工具 -----------------------------------------------------------------
# 一律從 /dev/tty 讀，即使 stdin 被重導向也能正常問答
ask() {  # $1=提示  $2=預設值 → stdout 答案
    local prompt="$1" def="$2" ans=""
    if [ "$INTERACTIVE" = 0 ]; then printf '%s' "$def"; return; fi
    read -r -p "  $prompt [$def]: " ans < /dev/tty || ans=""
    printf '%s' "${ans:-$def}"
}

ask_yn() {  # $1=提示  $2=預設 y/n → 回傳 0(是)/1(否)
    local prompt="$1" def="$2" ans
    while :; do
        ans="$(ask "$prompt (y/n)" "$def")"
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "  ！請輸入 y 或 n" >&2; [ "$INTERACTIVE" = 0 ] && return 1 ;;
        esac
    done
}

ask_int() {  # $1=提示  $2=預設  $3=下限  $4=上限 → stdout 整數
    local prompt="$1" def="$2" lo="$3" hi="$4" ans
    while :; do
        ans="$(ask "$prompt" "$def")"
        if [ -n "$ans" ] && [ -z "${ans//[0-9]/}" ] && [ "$ans" -ge "$lo" ] && [ "$ans" -le "$hi" ]; then
            printf '%s' "$ans"; return
        fi
        echo "  ！請輸入 $lo–$hi 之間的整數" >&2
        [ "$INTERACTIVE" = 0 ] && { printf '%s' "$def"; return; }
    done
}

ask_date() {  # $1=提示  $2=預設 → stdout YYYY-MM-DD
    local prompt="$1" def="$2" ans norm
    while :; do
        ans="$(ask "$prompt" "$def")"
        if norm="$(date -d "$ans" +%F 2>/dev/null)"; then printf '%s' "$norm"; return; fi
        echo "  ！日期格式無法解析（請用 YYYY-MM-DD）" >&2
        [ "$INTERACTIVE" = 0 ] && { printf '%s' "$def"; return; }
    done
}

# --- 1. 位置 ------------------------------------------------------------------
echo "===== 1/3 位置 ====="
[ "$ROOT_FROM_CONF" = 1 ] && [ "$ROOT" = "$DEFAULT_ROOT" ] && \
    echo "  （預設值取自 sync_archive.conf 的 SRC，封存腳本就是讀這個目錄）"
ROOT="$(ask "測試資料要產生在哪個目錄" "$ROOT")"
# 尾斜線剝到底（"///" 只剝一層會變 "//" 而繞過下面的根目錄檢查）
while [ "$ROOT" != "/" ] && [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done

# 安全檢查：這個目錄等一下會被清空，絕不能是根目錄或掛載點
case "$ROOT" in
    ""|"/") echo "拒絕：輸出目錄不可為根目錄" >&2; exit 2 ;;
    "$HOME") echo "拒絕：輸出目錄不可為家目錄本身" >&2; exit 2 ;;
esac
if mountpoint -q "$ROOT" 2>/dev/null; then
    echo "拒絕：$ROOT 是掛載點，清空掛載點過於危險（也可能是真的來源分享夾）" >&2
    echo "      請改指定掛載點底下的子目錄，或先卸載。" >&2
    exit 2
fi

# 已存在且非空 → 明確確認才清空
if [ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    n_exist="$(find "$ROOT" -type f 2>/dev/null | wc -l)"
    echo "  ⚠ $ROOT 已存在且非空（$n_exist 個檔案），產生前會先清空。"
    if [ "$FORCE" != 1 ]; then
        ask_yn "  確定要清空並重建嗎" "n" || { echo "已取消，未動任何檔案。"; exit 0; }
    fi
fi

CAM="${SITE_PREFIX}-${CAM_ID}"
CAM="$(ask "攝影機/站點代號前綴" "$CAM")"

# --- 2. 時間 ------------------------------------------------------------------
echo
echo "===== 2/3 時間 ====="
echo "  （今天是 $TODAY；今天的資料夾應被封存腳本保留不動）"
DATE_FROM="$(ask_date "資料起始日期" "$DATE_FROM")"
DATE_TO="$(ask_date "資料結束日期" "$DATE_TO")"
if [ "$(date -d "$DATE_FROM" +%s)" -gt "$(date -d "$DATE_TO" +%s)" ]; then
    echo "  ！起始日晚於結束日，自動對調" >&2
    _t="$DATE_FROM"; DATE_FROM="$DATE_TO"; DATE_TO="$_t"
fi
# 未來日期的檔 mtime 比封存基準新、不會被搬，但會被算進「應搬移」讓對帳失準 → 壓回今天
if [ "$(date -d "$DATE_TO" +%s)" -gt "$(date -d "$TODAY" +%s)" ]; then
    echo "  ！結束日期在未來，已改為今天 $TODAY（未來的檔不會被封存，對帳會失準）" >&2
    DATE_TO="$TODAY"
fi
if [ "$(date -d "$DATE_FROM" +%s)" -gt "$(date -d "$TODAY" +%s)" ]; then
    DATE_FROM="$TODAY"
fi

if ask_yn "額外加入今天($TODAY)的資料（驗證「今天的不搬」）" "$INCLUDE_TODAY"; then
    INCLUDE_TODAY=y
else
    INCLUDE_TODAY=n
fi

if ask_yn "額外加入超過保留期的過舊檔（驗證搬移後由保留階段刪除）" "$MAKE_OLD"; then
    MAKE_OLD=y
    OLD_DAYS="$(ask_int "過舊檔要距今幾天（需 > RETENTION_DAYS，預設 365）" "$OLD_DAYS" 366 36500)"
else
    MAKE_OLD=n
fi

# --- 3. 亂數 ------------------------------------------------------------------
echo
echo "===== 3/3 亂數 ====="
SEED="$(ask_int "亂數種子（同一個種子會產生同樣的結構，方便重現）" "$SEED" 0 999999)"
FILES_MIN="$(ask_int "每個日期資料夾最少幾個檔" "$FILES_MIN" 1 1000)"
FILES_MAX="$(ask_int "每個日期資料夾最多幾個檔" "$FILES_MAX" "$FILES_MIN" 1000)"
SIZE_MIN_KB="$(ask_int "檔案最小大小 (KB)" "$SIZE_MIN_KB" 1 1048576)"
SIZE_MAX_KB="$(ask_int "檔案最大大小 (KB)" "$SIZE_MAX_KB" "$SIZE_MIN_KB" 1048576)"

RANDOM="$SEED"   # 固定種子 → 檔案數/大小/時間可重現（檔案內容取自 /dev/urandom，不重現）

# --- 產生 ---------------------------------------------------------------------
# 亂數一律在「當前 shell」取值、以全域變數回傳，不可用 $(...) 包起來：
# bash 5 會替每個子 shell 重新播種 RANDOM，放進命令替換裡種子就失效、無法重現。
RND=0
rnd() { RND=$(( $1 + RANDOM % ($2 - $1 + 1) )); }   # $1=下限 $2=上限（含）→ $RND

# 建一個指定大小的亂數內容檔，並把 mtime 設成指定時間
mkfile() {  # $1=路徑  $2=大小KB  $3=時間 "YYYY-MM-DD HH:MM:SS"
    local path="$1" kb="$2" when="$3"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/urandom of="$path" bs=1024 count="$kb" status=none
    touch -d "$when" "$path"
}

RT=""
rand_time() {  # → $RT = "HH:MM:SS"
    local h m s
    rnd 0 23; h=$RND
    rnd 0 59; m=$RND
    rnd 0 59; s=$RND
    printf -v RT '%02d:%02d:%02d' "$h" "$m" "$s"
}

echo
echo "===== 產生中 ====="
printf '輸出根目錄 : %s\n' "$ROOT"
printf '日期範圍   : %s ~ %s%s\n' "$DATE_FROM" "$DATE_TO" \
    "$([ "$INCLUDE_TODAY" = y ] && echo " (+今天 $TODAY)")"
printf '亂數       : seed=%s 每日 %s~%s 檔 每檔 %s~%s KB\n' \
    "$SEED" "$FILES_MIN" "$FILES_MAX" "$SIZE_MIN_KB" "$SIZE_MAX_KB"
echo

rm -rf "${ROOT:?}"
mkdir -p "$ROOT"

# 展開日期清單（去重、排序）
dates=""
d="$DATE_FROM"
while [ "$(date -d "$d" +%s)" -le "$(date -d "$DATE_TO" +%s)" ]; do
    dates="$dates $d"
    d="$(date -d "$d + 1 day" +%F)"
done
[ "$INCLUDE_TODAY" = y ] && dates="$dates $TODAY"
dates="$(echo "$dates" | tr ' ' '\n' | grep -v '^$' | sort -u)"

n_move=0; n_keep=0; n_expired=0

# ---- Enter_Leave/ （PDF；過舊檔也放這裡） -----------------------------------
first_date="$(echo "$dates" | head -1)"
for i in 01 02 03; do
    rnd "$SIZE_MIN_KB" "$SIZE_MAX_KB"; kb=$RND
    rand_time
    mkfile "$ROOT/Enter_Leave/enter_leave_$i.pdf" "$kb" "$first_date $RT"
    if [ "$first_date" = "$TODAY" ]; then n_keep=$((n_keep+1)); else n_move=$((n_move+1)); fi
done

if [ "$MAKE_OLD" = y ]; then
    old_date="$(date -d "$OLD_DAYS days ago" +%F)"
    for i in 01 02 03; do
        rnd "$SIZE_MIN_KB" "$SIZE_MAX_KB"; kb=$RND
        rand_time
        mkfile "$ROOT/Enter_Leave/old_record_$i.pdf" "$kb" "$old_date $RT"
        n_expired=$((n_expired+1))
    done
fi

# ---- Enter_Leave_Records/<date>/  (ALPR 辨識截圖 .jpg) ----------------------
# ---- Enter_Leave_Records_video/<date>/ (影片 .avi) --------------------------
for d in $dates; do
    for kind in jpg avi; do
        case "$kind" in
            jpg) sub="Enter_Leave_Records" ;;
            avi) sub="Enter_Leave_Records_video" ;;
        esac
        rnd "$FILES_MIN" "$FILES_MAX"; cnt=$RND
        for _ in $(seq 1 "$cnt"); do
            # 同一天抽到同一秒會同名覆寫，讓上面的計數與實際檔數對不上 → 重抽到不重複
            # （同一種子下重抽序列也固定，不影響可重現性；FILES_MAX 上限 1000 << 86400 秒，必能抽到）
            while :; do
                rand_time; t="$RT"
                hh="${t%%:*}"; rest="${t#*:}"; mm="${rest%%:*}"; ss="${rest##*:}"
                fname="${CAM}_${d}_${hh}H-${mm}M-${ss}S.$kind"
                [ -e "$ROOT/$sub/$d/$fname" ] || break
            done
            rnd "$SIZE_MIN_KB" "$SIZE_MAX_KB"; kb=$RND
            mkfile "$ROOT/$sub/$d/$fname" "$kb" "$d $t"
            if [ "$d" = "$TODAY" ]; then n_keep=$((n_keep+1)); else n_move=$((n_move+1)); fi
        done
    done
done

# --- 目錄時間戳記對齊 ---------------------------------------------------------
# 寫入檔案會把父目錄的 mtime 改成「當下」，導致日期資料夾掛著今天的時間、
# 和裡面檔案的日期對不起來。這裡由深至淺（find -depth：先處理內容再處理目錄本身）
# 把每個目錄的 mtime 設成「該目錄內最新一筆的時間」，貼近真實 IPCAM 分享夾
# ——日期資料夾的時間 = 那天最後一次寫入的時間，且子目錄先算好、父目錄才跟著對齊。
align_dir_times() {
    local d ts
    find "$ROOT" -depth -type d -print0 | while IFS= read -r -d '' d; do
        # 只看直屬內容；取 epoch 值再 touch，避免路徑含空白造成解析問題
        ts="$(find "$d" -mindepth 1 -maxdepth 1 -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
        [ -n "$ts" ] && touch -d "@${ts%.*}" "$d"
    done
}
align_dir_times

# --- 結果報告 -----------------------------------------------------------------
total=$(find "$ROOT" -type f | wc -l)
bytes=$(find "$ROOT" -type f -printf '%s\n' | awk '{s+=$1} END{printf "%d", s+0}')
human=$(awk -v b="$bytes" 'BEGIN{split("B KB MB GB TB",u," ");s=1;
    while(b>=1024&&s<5){b/=1024;s++} if(s==1)printf "%d %s",b,u[s]; else printf "%.1f %s",b,u[s]}')

echo "===== 產生完成（目錄時間戳記已與內容對齊）====="
find "$ROOT" -mindepth 1 -maxdepth 2 -type d -printf '  %TY-%Tm-%Td %TH:%TM  %p\n' | sort -k3
echo
echo "  檔案總數 : $total（共 $human）"
echo "  亂數種子 : $SEED   ← 用 SEED=$SEED 可重現同樣的結構"
echo
echo "===== 對 sync_archive.sh 的預期行為 ====="
if [ "$MAKE_OLD" = y ]; then
    printf '  應被搬移封存 : %s 檔（mtime 早於今天 00:00，含下面那 %s 個過舊檔）\n' \
           "$(( n_move + n_expired ))" "$n_expired"
else
    printf '  應被搬移封存 : %s 檔（mtime 早於今天 00:00）\n' "$n_move"
fi
printf '  應留在來源   : %s 檔（今天 %s 的檔，腳本不碰）\n' "$n_keep" "$TODAY"
if [ "$MAKE_OLD" = y ]; then
    printf '  搬完隨即刪除 : %s 檔（%s，已超過保留期，搬到 NAS 後由保留階段刪掉）\n' \
           "$n_expired" "$old_date"
    printf '                 → 最終 dst 只會留下 %s 檔\n' "$n_move"
fi
echo
echo "  提示：conf 設 REQUIRE_MOUNTPOINT=0（預設）時可直接對本機資料夾執行；"
echo "        設 1 時來源必須是掛載點，本機驗證可用 sudo mount --bind $ROOT $ROOT"
echo "        （注意：掛載後本腳本會拒絕再對同一路徑產生資料，需先 umount）"
