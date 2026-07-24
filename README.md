# synology_sync — IPCAM 影片/PDF 安全封存腳本

在 Synology DSM 7.4 上，把透過 **CIFS 掛載的 A PC 分享夾**中的 IPCAM 影片與 PDF
**安全搬移**（copy → verify → delete source）到 NAS 本機封存目錄，並自動清除
NAS 上**超過一年**的舊檔。每次執行寫入每日封存 log（txt），並更新一份易讀的
`summary_time.html` 執行摘要。

## 檔案

| 檔案 | 說明 |
|---|---|
| `sync_archive.sh` | 主腳本 |
| `sync_archive.conf` | 設定檔（路徑、門檻）— 部署後依實際環境修改 |
| `make_testdata.sh` | 互動式測試資料產生器（僅測試用，不需部署到 NAS） |
| `README.md` / `README.html` | 使用說明（同內容，兩種格式） |

## 產出檔案（在 `LOG_DIR` 下）

| 檔案 | 說明 |
|---|---|
| `sync_YYYY-MM-DD.log` | 每日逐檔文字 log（MOVE / DELETE / SUMMARY） |
| `summary_time.html` | 最近 200 次執行的摘要表（時間、搬移/刪除檔數與容量、狀態）；**點任一列可展開該次的逐檔明細**，用瀏覽器開即可看 |
| `summary.tsv` | 摘要原始資料（HTML 由此產生，可另做分析） |
| `details/*.tsv` | 每次執行的逐檔明細（MOVE / DELETE），供 HTML 產生可展開的細項；保留最近 30 次 |

## 運作原理

- **安全搬移**：用 `rsync --remove-source-files`。每個檔**完整成功傳輸到 NAS 後**，
  才刪掉 A PC 上的來源檔。中途斷線只保留來源、不遺失資料 — 這就是「類似 mv」的安全語義。
- **以日期判斷要搬哪些檔**：用檔案 **mtime（修改時間）**與「基準日 00:00」比較
  （`find ! -newermt`），只搬**基準日之前**的檔。基準日 = 今天往前推
  `ARCHIVE_BEFORE_DAYS_AGO` 天（預設 `0`＝今天 00:00）。
  例：今天 7/23、預設 0 → 只封存 **7/22 及更早**的檔，**今天 7/23 仍在產生的檔完全不碰**。
  （註：Linux/CIFS 上以 mtime 為準；birthtime 建立時間多數檔案系統無法用 `find` 可靠查詢。）
- **兩階段職責分開**：
  1. **封存階段（SRC → DST）**：只負責搬移，**完全不做保留期判斷**。目標單純是釋放 A PC
     空間、NAS 上有一份。凡是 mtime 早於基準日的檔一律搬走。
  2. **保留階段（只對 DST）**：檔案該不該留，一律在 NAS 上決定。刪除 mtime 超過
     `RETENTION_DAYS` 的檔，以**原始 mtime** 為準（rsync `-a` 會保留原始時間）。
     保留 1 年 → 年齡達 366 天的檔即刪除。**絕不對來源執行刪除**。

  保留基準在**開跑時定格**成固定時間點，長時間執行（大批首搬 rsync 可能跑數小時）
  過程中判定基準不會隨「當下」漂移。

  > 因此來源上若有已超過保留期的舊檔，會先被搬到 NAS、再由保留階段刪除，log 會同時
  > 留下 `MOVE` 與 `DELETE` 兩筆紀錄。首次執行若 A PC 積壓大量一年以上的影片，會花時間
  > 傳一批馬上要刪的資料；日常運作（每天搬前一天的檔）不會遇到。
- **來源空目錄只做精準清理**：只對「本輪確實被搬空的目錄」由深至淺 `rmdir`（非空自然失敗），
  且 **`$SRC` 底下第一層的固定分類資料夾一律保留**。整個分類被搬空時若放任往上刪，
  `Enter_Leave/`、`Enter_Leave_Records/` 這類由 IPCAM 軟體建立的固定資料夾會被一起刪掉，
  攝影機下次要寫入就沒地方放。跨日剛建立、尚未寫入的日期資料夾也因為「本輪沒搬過」而不受影響。
- **健康檢查**：來源可以是 CIFS 掛載點或**本機資料夾**。設 `REQUIRE_MOUNTPOINT=1`
  （CIFS 部署建議）時會要求 `SRC` 必須是掛載點 —— 分享夾沒掛上時掛載點只是空目錄，
  不擋下來會誤以為「沒東西可搬」而靜默空轉；預設 `0` 只檢查目錄存在。
- **來源的問題不會拖累 NAS 清理**：來源未掛載或目錄不存在時，只會記 ERROR 並**跳過封存
  階段**，`$DST` 的保留期清理**照常執行** —— 否則 A PC 離線多久，NAS 就有多久不清理。
  腳本仍以非零結束並發通知，你不會漏掉來源出問題。
  且因搬移是「傳成功才刪來源」，就算來源異常最糟也只是該次不搬。
- **防重疊**：flock 單一實例鎖。

## 部署步驟（在 NAS 上）

1. **建立目錄並放置腳本**
   ```sh
   mkdir -p /volume1/scripts/synology_sync
   # 把 sync_archive.sh 與 sync_archive.conf 複製到上面目錄
   chmod +x /volume1/scripts/synology_sync/sync_archive.sh
   ```

2. **掛載 A PC 分享夾**：DSM → File Station → 工具 → 掛載遠端資料夾 → CIFS，
   指向 A PC 的 SMB 分享。掛好後查真實路徑：
   ```sh
   mount | grep -i cifs
   ```

3. **建立封存目錄**：
   ```sh
   mkdir -p /volume1/archive
   ```

4. **編輯 `sync_archive.conf`**，填入實際值：
   - `SRC`＝步驟 2 查到的 CIFS 掛載點
   - `DST`＝`/volume1/archive`
   - `LOG_DIR`＝`/volume1/scripts/synology_sync/logs`

5. **確認工具齊全**：`which rsync flock find mountpoint`（DSM 7 內建）。

## 產生測試資料（`make_testdata.sh`）

用來造一棵可重現的「來源」測試樹，驗證封存腳本的 mtime 判斷邏輯。直接執行會互動問答：

```sh
bash make_testdata.sh
```

問答分三段：

| 段落 | 會問什麼 |
|---|---|
| 1. 位置 | 輸出根目錄、站點/攝影機代號前綴 |
| 2. 時間 | 資料起訖日期、是否加入今天的資料、是否加入超過保留期的過舊檔及其天數 |
| 3. 亂數 | 亂數種子、每個日期資料夾的檔案數範圍、檔案大小範圍(KB) |

每題都有預設值，按 Enter 即可。產生的資料刻意跨越幾條分界，並在最後印出
**對 `sync_archive.sh` 的預期行為**（應搬移／應留在來源／搬完隨即刪除 各幾檔），
可直接與 log 的 `SUMMARY` 對帳：

- 今天之前的資料夾 → 應被搬移封存
- 今天的資料夾 → 應完全不動
- 超過保留期的檔 → 會被搬到 NAS，接著在同一輪由保留階段刪除（log 有 `MOVE` 與 `DELETE` 兩筆）

檔案內容取自 `/dev/urandom`（真實大小），目錄的 mtime 會對齊成「該目錄內最新一筆的時間」，
貼近真實 IPCAM 分享夾。**同一個亂數種子會產生完全相同的結構與時間戳記**，方便重現問題。

非互動用法（給 CI 或反覆測試）：

```sh
bash make_testdata.sh -y                       # 全用預設值，不問（也同意覆寫既有目錄）
ROOT=/path/to/src SEED=42 DATE_FROM=2026-07-01 DATE_TO=2026-07-20 \
  INCLUDE_TODAY=y MAKE_OLD=y FILES_MIN=2 FILES_MAX=5 SIZE_MIN_KB=1 SIZE_MAX_KB=64 \
  bash make_testdata.sh -y
```

> 輸出目錄會先被清空，因此腳本會拒絕根目錄、家目錄本身與**掛載點**（避免誤指到真的
> CIFS 來源分享夾），目錄已存在且非空時也會要求確認。偵測不到 tty 時自動轉非互動，
> 確認題一律當成否，不會卡住也不會亂刪。

## 上線前測試（務必依序做）

```sh
cd /volume1/scripts/synology_sync

# 1) 演練：設 DRY_RUN=1 執行，log 應只列 MOVE/DELETE 清單、未真的動檔
#    演練模式下 rsync 若失敗（例如環境缺 rsync），腳本會以該 rc 非零結束並記 ERROR，
#    所以這一步就能驗出環境問題 —— 看到 exit 0 才算通過。
sed -i 's/^DRY_RUN=.*/DRY_RUN=1/' sync_archive.conf
sudo bash sync_archive.sh; echo "exit=$?"
cat logs/sync_$(date +%F).log

# 2) 小量真跑：DRY_RUN=0，在 A PC 分享夾放測試檔：
#    - 昨天日期的檔（touch -d yesterday）→ 應被搬走
#    - 今天日期的檔（touch -d today）    → 應保留在來源（今天的不搬）
sed -i 's/^DRY_RUN=.*/DRY_RUN=0/' sync_archive.conf
sudo bash sync_archive.sh
# 確認：DST 出現昨天檔且內容一致、mtime 保留；來源昨天檔消失、今天檔仍在；
#       用瀏覽器開 logs/summary_time.html 看摘要

# 3) 保留邏輯
touch -d '400 days ago' /volume1/archive/test_old.mp4   # 應被刪
touch -d '300 days ago' /volume1/archive/test_new.mp4   # 應保留
sudo bash sync_archive.sh
grep DELETE logs/sync_$(date +%F).log

# 4) 掛載異常測試（需 conf 設 REQUIRE_MOUNTPOINT=1）：卸載 CIFS 後執行，log 應出現
#    ERROR、來源未被動、腳本以非零結束，但 DST 的保留期清理仍應照常執行
```

## 執行者與權限（重要）

權限分成**兩層**，兩層都要對，檔案才搬得動、來源才刪得掉：

### 第 1 層：NAS 上由誰執行腳本 → 建議 `root`

DSM 的「掛載遠端資料夾（CIFS）」掛點通常**只有 root 能完整存取**，而且腳本要跨 volume
寫入、刪除來源與封存檔。用 **root** 最單純可靠，也是 DSM 維護型排程腳本的常規做法。

> 不建議改用一般使用者：一般帳號多半無法進入遠端掛載點，還要另外調 CIFS 掛載參數與
> 共用資料夾權限，很容易卡在「permission denied」；除非你有硬性資安需求，否則用 root。

### 第 2 層：掛載 A PC 時用的 Windows 帳號 → 需有「修改/刪除」權限

在 DSM「掛載遠端資料夾」對話框輸入的那組 A PC 帳密，決定 NAS 對 A PC 分享夾的存取權。
因為本腳本用 `rsync --remove-source-files`（搬完要**刪來源**），這組帳號在 Windows 端必須有
**讀取 + 寫入 + 刪除（Modify）** 權限，否則檔案搬到 NAS 後刪不掉、會一直堆在 A PC。

- Windows 分享權限（共用 + NTFS）都要給該帳號 **Modify** 以上。
- 建議在 A PC 建一個專用帳號（例如 `nas_sync`），只對 IPCAM 分享夾開 Modify，最小權限。

## 設為每日排程

DSM → Control Panel → **Task Scheduler** → Create → **Scheduled Task → User-defined script**：

- **User**：`root`（見上「第 1 層」）
- **Schedule**：每天，離峰時段（例如 03:00）
- **Run command**：
  ```
  bash /volume1/scripts/synology_sync/sync_archive.sh
  ```
- 勾選「Send run details by email」，失敗時第一時間收到通知。

## Log 與摘要

- **逐檔文字 log**：`logs/sync_YYYY-MM-DD.log`，格式如：
  ```
  2026-07-23 03:00:01  START  src=... dst=... 封存基準=<2026-07-23 00:00:00 之前> retention=365d
  MOVE   1048576  cam1/2026-07/clip_0900.mp4
  DELETE 1048576  /volume1/archive/2025/.../old.mp4
  2026-07-23 03:04:12  SUMMARY moved=2 movedBytes=... deleted=1 deletedBytes=... rsync_rc=0 dur=251s dry_run=0 srcUnavailable=0
  ```
- **HTML 摘要**：`logs/summary_time.html` — 用瀏覽器開即可看最近 200 次執行
  （時間、狀態、搬移/刪除檔數與容量、耗時），可經 DSM File Station 下載或用 Web Station 分享。
  - **可展開細項**：點任一列會展開該次執行的逐檔明細（哪些檔被搬走、哪些被刪除、各自大小），
    方便自行核對。明細保留最近 30 次執行，單次上限 2000 筆，超出的部分請查當日 log。
  - **只在執行完整收尾後才更新**：頁面用「先寫暫存檔再原子替換」的方式產生，
    搬移進行到一半或中途被中斷時，頁面完全不會變動 —— 你看到的一定是某次完整執行的結果，
    不會出現半套數字造成誤判。
- 舊 log 由腳本依 `LOG_RETENTION_DAYS`（預設 90 天）自我清理。

## 可調參數（在 conf 內）

| 參數 | 預設 | 說明 |
|---|---|---|
| `ARCHIVE_BEFORE_DAYS_AGO` | 0 | 封存基準日＝今天往前推幾天的 00:00。0＝只搬今天之前（昨天及更早） |
| `RETENTION_DAYS` | 365 | NAS 保留天數，超過即刪（只作用於 `$DST`，來源永不因保留期被刪） |
| `LOG_RETENTION_DAYS` | 90 | log 保留天數 |
| `DRY_RUN` | 0 | 1＝只演練不動檔 |
| `NOTIFY_ON_ERROR` | 1 | 失敗時發 DSM 通知 |
| `REQUIRE_MOUNTPOINT` | 0 | 1＝要求 `SRC` 必須是掛載點（CIFS 部署建議開）；0＝允許本機資料夾 |
