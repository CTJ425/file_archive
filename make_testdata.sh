#!/bin/bash
# ============================================================================
# make_testdata.sh — 依 WizTree 截圖的目錄結構，在 testfile/ 下產生測試檔案
#
# 用途：給 sync_archive.sh 一個可重現的「來源」測試樹。重點在「檔名 + mtime +
#       目錄結構」，不在檔案大小，所以每個檔只有數 bytes；mtime 會設成與檔名
#       所編碼的時間一致，讓封存的 mtime 判斷邏輯可被真實驗證。
#
# 產生的日期刻意跨越「今天 00:00」這條分界：
#   - 今天(TODAY)之前的資料夾  → 腳本應「搬移封存」
#   - 今天(TODAY)的資料夾      → 腳本應「完全不動」
#
# 用法：bash make_testdata.sh [輸出根目錄]   (預設 ./testfile)
# ============================================================================
set -eu

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testfile}"
TODAY="$(date +%F)"                 # 例：2026-07-23
# 攝影機/站點前綴：以中性代號取代真實客戶名稱，可用環境變數覆寫
# 例：SITE_PREFIX="SiteB" CAM_ID="CAM02" bash make_testdata.sh
CAM="${SITE_PREFIX:-SiteA}-${CAM_ID:-CAM01}"

echo "輸出根目錄: $ROOT"
echo "今天       : $TODAY (此日期的資料夾應被腳本保留不動)"
rm -rf "$ROOT"
mkdir -p "$ROOT"

# 建一個小檔並把 mtime 設為指定時間 (格式: "YYYY-MM-DD HH:MM:SS")
mkfile() {  # $1=路徑  $2=時間  $3=內容標記
    local path="$1" when="$2" tag="$3"
    mkdir -p "$(dirname "$path")"
    printf 'test-fixture %s\n' "$tag" > "$path"
    touch -d "$when" "$path"
}

# ---- 1) Enter_Leave/ （少量檔，較舊，應被封存） ----------------------------
for i in 01 02 03; do
    mkfile "$ROOT/Enter_Leave/enter_leave_$i.pdf" "2021-06-22 06:04:52" "EL-$i"
done

# ---- 2) Enter_Leave_Records/ （每日資料夾，ALPR 小檔紀錄） ------------------
# 幾個舊日期(應封存) + 今天(應保留)
records_dates="2026-07-20 2026-07-22 $TODAY"
for d in $records_dates; do
    for n in $(seq 1 5); do
        hh=$(printf '%02d' $((8 + n)))
        mkfile "$ROOT/Enter_Leave_Records/$d/${CAM}_${d}_${hh}H-00M-0${n}S.jpg" \
               "$d ${hh}:00:0${n}" "REC-$d-$n"
    done
done

# ---- 3) Enter_Leave_Records_video/ （每日資料夾，.avi 影片） ----------------
# 命名規則： <站點>-<攝影機>_YYYY-MM-DD_HHH-MMM-SSS.avi  (例：SiteA-CAM01_...)
video_dates="2026-06-25 2026-07-22 $TODAY"
for d in $video_dates; do
    # 每個日期產 6 段影片，約每 3 分鐘一段，從 21:02 起
    base_min=$((21*60 + 2))
    for n in $(seq 0 5); do
        tot=$((base_min + n*3))
        HH=$(printf '%02d' $((tot / 60)))
        MM=$(printf '%02d' $((tot % 60)))
        SS=$(printf '%02d' $((55 + (n%3))) )   # 55/56/57 交替，貼近截圖
        [ "$SS" -gt 59 ] && SS=59
        fname="${CAM}_${d}_${HH}H-${MM}M-${SS}S.avi"
        mkfile "$ROOT/Enter_Leave_Records_video/$d/$fname" \
               "$d ${HH}:${MM}:${SS}" "VID-$d-$n"
    done
done

echo
echo "===== 產生完成，結構如下 ====="
find "$ROOT" -mindepth 1 -maxdepth 2 -printf '%y %p\n' | sort
echo
echo "===== 檔案 mtime 抽樣（驗證封存分界用） ====="
find "$ROOT" -type f -printf '%TY-%Tm-%Td %TH:%TM  %p\n' | sort | sed -n '1p;$p'
echo
printf '檔案總數: %s\n' "$(find "$ROOT" -type f | wc -l)"
