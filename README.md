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
| `README.md` / `README.html` | 使用說明（同內容，兩種格式） |

## 產出檔案（在 `LOG_DIR` 下）

| 檔案 | 說明 |
|---|---|
| `sync_YYYY-MM-DD.log` | 每日逐檔文字 log（MOVE / DELETE / SUMMARY） |
| `summary_time.html` | 最近 200 次執行的摘要表（時間、搬移/刪除檔數與容量、跳過(過舊)筆數、狀態），用瀏覽器開即可看 |
| `summary.tsv` | 摘要原始資料（HTML 由此產生，可另做分析） |

## 運作原理

- **安全搬移**：用 `rsync --remove-source-files`。每個檔**完整成功傳輸到 NAS 後**，
  才刪掉 A PC 上的來源檔。中途斷線只保留來源、不遺失資料 — 這就是「類似 mv」的安全語義。
- **以日期判斷要搬哪些檔**：用檔案 **mtime（修改時間）**與「基準日 00:00」比較
  （`find ! -newermt`），只搬**基準日之前**的檔。基準日 = 今天往前推
  `ARCHIVE_BEFORE_DAYS_AGO` 天（預設 `0`＝今天 00:00）。
  例：今天 7/23、預設 0 → 只封存 **7/22 及更早**的檔，**今天 7/23 仍在產生的檔完全不碰**。
  （註：Linux/CIFS 上以 mtime 為準；birthtime 建立時間多數檔案系統無法用 `find` 可靠查詢。）
- **保留一年**：只在 NAS 本機封存目錄 `$DST` 上 `find -mtime +RETENTION_DAYS -delete`，
  以檔案**原始 mtime**為準（rsync `-a` 會保留原始時間）。**絕不對來源執行刪除**。
- **過舊來源檔不搬也不刪**：來源上 mtime 已超過 `RETENTION_DAYS` 的檔（搬過去也會在同一輪
  被保留期立刻刪掉，等於來源與封存同時消失），一律**原地保留在來源**，只在 log 記
  `SKIPOLD` 並於摘要顯示「跳過(過舊)」筆數，交由人工判斷要保存還是自行清除。
  搬移清單與保留刪除使用**同一個 `-mtime +RETENTION_DAYS` 判斷式**，邊界保證一致。
- **健康檢查**：CIFS 未掛載即中止並記 ERROR；且因搬移是「傳成功才刪來源」，就算來源異常最糟也只是該次不搬。
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

# 4) 掛載中止測試：卸載 CIFS 後執行，log 應出現 ERROR 且來源未被動
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
  SKIPOLD 524288  ./cam1/2024-01/clip_old.mp4        ← 超過保留期，留在來源不動
  DELETE 1048576  /volume1/archive/2025/.../old.mp4
  2026-07-23 03:04:12  SUMMARY moved=2 movedBytes=... deleted=1 deletedBytes=... skippedOld=1 skippedBytes=... rsync_rc=0 dur=251s dry_run=0
  ```
- **HTML 摘要**：`logs/summary_time.html` — 每次執行後自動更新，用瀏覽器開即可看最近
  200 次執行（時間、狀態、搬移/刪除檔數與容量、耗時），可經 DSM File Station 下載或
  用 Web Station 分享。
- 舊 log 由腳本依 `LOG_RETENTION_DAYS`（預設 90 天）自我清理。

## 可調參數（在 conf 內）

| 參數 | 預設 | 說明 |
|---|---|---|
| `ARCHIVE_BEFORE_DAYS_AGO` | 0 | 封存基準日＝今天往前推幾天的 00:00。0＝只搬今天之前（昨天及更早） |
| `RETENTION_DAYS` | 365 | NAS 保留天數，超過即刪 |
| `LOG_RETENTION_DAYS` | 90 | log 保留天數 |
| `DRY_RUN` | 0 | 1＝只演練不動檔 |
| `NOTIFY_ON_ERROR` | 1 | 失敗時發 DSM 通知 |
