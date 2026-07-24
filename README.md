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
| `summary_time.html` | 最近 200 次執行的摘要表（時間、搬移/刪除檔數與容量、狀態）；**點任一列可展開該次的逐檔明細**，執行中會在最上面顯示一列 `PROG`，用瀏覽器開即可看 |
| `summary.tsv` | 摘要原始資料（HTML 由此產生，可另做分析） |
| `details/*.tsv` | 每次執行的逐檔明細（MOVE / DELETE），供 HTML 產生可展開的細項；檔名為 `<RUN_ID>.tsv`，保留最近 30 次 |
| `.running` | **執行中標記**（隱藏檔）。開跑寫入、收尾刪除，摘要頁靠它畫出 `PROG` 列。正常情況下你不會看到它 |
| `.sync_archive.lock` | **單一實例鎖**（隱藏檔）。沒有 `flock` 的環境會改用目錄鎖 `.sync_archive.lock.d` |

> `summary.tsv` **不會自我清理**（每次執行 1 行、約 80 bytes，一年約 30 KB），
> 只有 `sync_*.log` 會依 `LOG_RETENTION_DAYS` 清、`details/` 只留最近 30 份。

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
- **只同步「檔案」，不同步空資料夾**：待搬清單是 `find . -type f`，只列檔案；rsync 以
  `--files-from` 傳輸，**只有實際被搬的檔案，其所屬路徑才會在 `$DST` 建出來**。
  因此來源中的**空資料夾不會出現在 `$DST`，也不會被刪除**，log 與摘要頁上不會有它的任何紀錄
  —— 這是預期行為，不是漏搬。
  另外要注意：判斷「該不該搬」看的一律是**檔案的 mtime**，**資料夾自己的時間戳完全不參與判斷**。
  一個目錄時間顯示 2024 年、但裡面沒有檔案（或裡面的檔都是今天的）的資料夾，同樣不會有任何動作。
- **來源空目錄只做精準清理**：只對「本輪確實被搬空的目錄」由深至淺 `rmdir`（非空自然失敗），
  且 **`$SRC` 底下第一層的固定分類資料夾一律保留**。整個分類被搬空時若放任往上刪，
  `Enter_Leave/`、`Enter_Leave_Records/` 這類由 IPCAM 軟體建立的固定資料夾會被一起刪掉，
  攝影機下次要寫入就沒地方放。跨日剛建立、尚未寫入的日期資料夾也因為「本輪沒搬過」而不受影響。
- **`*.tmp` 一律不搬**：待搬清單排除 `*.tmp`（`! -name '*.tmp'`），因為那通常是「正在寫入中」
  的檔。就算它的 mtime 已經早於基準日也不會被搬走，會留在來源等下一輪。
- **`$DST` 的空目錄則是無差別清除**：保留階段刪完檔案後，會對 `$DST` 執行
  `find -mindepth 1 -type d -empty -delete`，**連第一層分類資料夾也會被清掉**。
  這和來源那邊的謹慎處理是刻意不對稱的 —— `$DST` 是封存區、沒有程式在寫入，
  目錄結構會在下次搬移時由 rsync 依需要重建；來源則有 IPCAM 隨時要寫入，動不得。
  （`DRY_RUN=1` 時不執行。）
- **健康檢查**：來源可以是 CIFS 掛載點或**本機資料夾**。設 `REQUIRE_MOUNTPOINT=1`
  （CIFS 部署建議）時會要求 `SRC` 必須是掛載點 —— 分享夾沒掛上時掛載點只是空目錄，
  不擋下來會誤以為「沒東西可搬」而靜默空轉；預設 `0` 只檢查目錄存在。
- **來源的問題不會拖累 NAS 清理**：來源未掛載或目錄不存在時，只會記 ERROR 並**跳過封存
  階段**，`$DST` 的保留期清理**照常執行** —— 否則 A PC 離線多久，NAS 就有多久不清理。
  腳本仍以非零結束並發通知，你不會漏掉來源出問題。
  且因搬移是「傳成功才刪來源」，就算來源異常最糟也只是該次不搬。
- **防重疊**：`flock` 單一實例鎖（鎖檔 `$LOG_DIR/.sync_archive.lock`）；環境沒有 `flock`
  時自動退化成目錄鎖 `.sync_archive.lock.d`。偵測到已有實例在跑時，本次會**直接結束並
  回傳 0**（不算失敗，DSM 排程不會報錯），log 留一行 `SKIP`，
  但**摘要頁與 `summary.tsv` 完全不會多出一列** —— 被鎖跳過的執行在摘要上是看不到的。
- **`$DST` 會自動建立**：`mkdir -p` 後再用一個探測檔（`.write_test_<PID>`）確認可寫；
  不可寫就中止（回傳 1），因為此時兩個階段都做不了。

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
| 2. 時間 | 資料起訖日期、是否加入今天的資料、是否加入保留期驗證檔（過舊檔＋邊界檔）及其天數、是否加入 `*.tmp` |
| 3. 亂數 | 亂數種子、每個日期資料夾的檔案數範圍、檔案大小範圍(KB) |

每題都有預設值，按 Enter 即可。產生的資料刻意跨越幾條分界，並在最後印出
**對 `sync_archive.sh` 的預期行為**（應搬移／應留在來源／搬完隨即刪除 各幾檔），
可直接與 log 的 `SUMMARY` 對帳：

- 今天之前的資料夾 → 應被搬移封存
- 今天的資料夾 → 應完全不動
- 超過保留期的檔 → 會被搬到 NAS，接著在同一輪由保留階段刪除（log 有 `MOVE` 與 `DELETE` 兩筆）
- **保留期邊界前後各一檔** → `retention_edge_keep_<N>d.pdf`（年齡 = `RETENTION_DAYS`）應留在 `$DST`，
  `retention_edge_delete_<N+1>d.pdf`（年齡 = `RETENTION_DAYS + 1`）應被刪除。
  兩者只差一天，保留判定若有 off-by-one 會立刻現形（過舊檔差 35 天驗不出來）。
- **`*.tmp`（mtime 已早於基準日）** → 應被 `! -name '*.tmp'` 排除而留在來源，
  模擬 IPCAM 正在寫入中的檔；同時驗證那個日期資料夾因為還有東西而不會被 `rmdir` 收掉。

> **保留天數以 `sync_archive.conf` 的 `RETENTION_DAYS` 為準**（讀不到才用 365），
> 過舊檔與邊界檔的天數都由它計算，所以 conf 改了保留期，對帳數字仍然正確。
> 產生時會印出這個天數是取自 conf 還是被環境變數蓋掉。
>
> 邊界檔的判定基準是 sync **開跑當下**的時刻，只留 1 小時緩衝 ——
> 請在產生測試資料後 1 小時內執行 `sync_archive.sh`，否則邊界檔的預期結果會反轉。

檔案內容取自 `/dev/urandom`（真實大小），目錄的 mtime 會對齊成「該目錄內最新一筆的時間」，
貼近真實 IPCAM 分享夾。**同一個亂數種子會產生完全相同的結構與時間戳記**，方便重現問題。

非互動用法（給 CI 或反覆測試）：

```sh
bash make_testdata.sh -y                       # 全用預設值，不問（也同意覆寫既有目錄）
ROOT=/path/to/src SEED=42 DATE_FROM=2026-07-01 DATE_TO=2026-07-20 \
  INCLUDE_TODAY=y MAKE_OLD=y MAKE_TMP=y FILES_MIN=2 FILES_MAX=5 SIZE_MIN_KB=1 SIZE_MAX_KB=64 \
  bash make_testdata.sh -y

# 保留期不同時（RETENTION_DAYS 會蓋掉 conf 的值，邊界檔天數跟著算）
RETENTION_DAYS=30 bash make_testdata.sh -y /path/to/src
```

> 輸出目錄會先被清空，因此腳本會拒絕根目錄、家目錄本身與**掛載點**（避免誤指到真的
> CIFS 來源分享夾），目錄已存在且非空時也會要求確認。偵測不到 tty 時自動轉非互動，
> 確認題一律當成否，不會卡住也不會亂刪。

其他值得知道的行為：

- `-h` / `--help` 會印出檔頭的完整說明；`-y` 等於「全部同意」，**包含同意清空既有目錄**。
- 輸出目錄的預設值直接取自 `sync_archive.conf` 的 `SRC` —— 否則按 Enter 會把資料產到別處，
  然後 sync 掃不到任何檔案。
- 日期會自動修正：起始日晚於結束日**自動對調**；結束日在未來會**壓回今天**
  （未來的檔不會被封存，會讓對帳數字失準）。
- 同一天抽到同一秒的檔名會**重抽**，避免同名覆寫讓「應搬移幾檔」與實際檔數對不上。
- **種子只保證結構與時間戳記可重現**；檔案內容取自 `/dev/urandom`，內容本身不重現。

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
#    注意：來源若有空資料夾，它不會被搬、也不會出現在 DST（只同步檔案），
#          且第一層分類資料夾即使被搬空也會原地保留 —— 這都是預期行為

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
  - **執行中會有一列 `PROG`**：腳本一開跑，頁面最上面就會多一列狀態為 `PROG`（執行中）的紀錄，
    只顯示開始時間與即時遞增的耗時，搬移／刪除的數字一律留白（`—`）。
    你因此分得出「還在跑」與「排程根本沒觸發」。
  - **正式數字只在完整收尾後才寫入**：頁面用「先寫暫存檔再原子替換」的方式產生，
    該次執行的數字要等完整收尾才會取代 `PROG` 列 —— 不會出現半套數字造成誤判。
    中途被中斷時 `PROG` 列會消失、退回上一次完整執行的結果（被 `kill -9` 或斷電則會停在
    `PROG`，看開始時間即可辨認，下次執行就會覆蓋）。
  - **「rsync」那一欄是 rsync 的退出碼，不是檔案數** —— `0` 才是正常，非 0 代表該次搬移有問題。
  - **狀態徽章共四種**：`OK`（綠）／`DRYRUN`（黃）／`ERROR`（紅）／`PROG`（藍，執行中）。
    失敗優先於演練：`DRY_RUN=1` 但 rsync 失敗時顯示的是 `ERROR` 而不是 `DRYRUN`。
  - **三個上限**：摘要列 200 筆、可展開明細 30 次執行、單次明細 2000 筆
    （超出會在明細最後插入一列 `TRUNCATED`，請改查當日 log）。超過 30 次或舊格式的列
    找不到明細檔，會渲染成不可展開的一般列。
  - **單檔自足**：CSS（與執行中才有的那段 JS）全部內嵌，沒有任何外部資源，
    複製到別台機器也能直接開；配色**跟隨系統深色／淺色**。
- 舊 log 由腳本依 `LOG_RETENTION_DAYS`（預設 90 天）自我清理。

## 退出碼（排程判讀用）

| 退出碼 | 意義 |
|---|---|
| `0` | 正常完成（含 `DRY_RUN` 正常結束），**或**偵測到另一個實例正在跑而跳過本次 |
| `1` | 前置致命錯誤（`$DST` 不可寫、算不出基準日…），或來源不可用（未掛載／目錄不存在） |
| `2` | 設定檔問題：找不到 conf，或 conf 缺少 `SRC` / `DST` / `LOG_DIR` |
| rsync 的退出碼 | 封存階段 rsync 失敗時**原樣傳出**（例：`127`＝找不到 rsync、`23`＝部分檔案傳輸失敗） |
| `130` | 執行中收到 `INT` / `TERM` / `HUP` 而中斷（log 留一行 `ABORT`，不寫任何摘要列） |

> 來源不可用時**仍會先跑完 `$DST` 的保留期清理**，最後才以非零結束 ——
> 非零只代表「這次有問題要看」，不代表什麼都沒做。

## `summary.tsv` 欄位格式

TAB 分隔、無標題列，每次執行結束時追加一行：

| # | 欄位 | 說明 |
|---|---|---|
| 1 | 結束時間 | `YYYY-MM-DD HH:MM:SS` |
| 2 | 搬移檔數 | |
| 3 | 搬移位元組 | |
| 4 | 刪除檔數 | 保留階段在 `$DST` 刪掉的 |
| 5 | 刪除位元組 | |
| 6 | rsync 退出碼 | |
| 7 | 耗時（秒） | |
| 8 | `DRY_RUN` | 0／1 |
| 9 | 狀態 | `OK`／`DRYRUN`／`ERROR: <原因>` |
| 10 | `RUN_ID` | `YYYYMMDD_HHMMSS_<PID>`，對應 `details/<RUN_ID>.tsv` |

`RUN_ID` 帶 PID 是因為**同一秒內結束的兩次執行會撞名**，導致明細互相覆蓋。
更早期版本的第 10 欄是已停用的 skipped 計數，會被當成找不到的 RUN_ID —— 那些列只是不可展開，不會錯亂。

`details/<RUN_ID>.tsv` 同樣是 TAB 分隔三欄：**動作**（`MOVE`／`DELETE`／`TRUNCATED`）、
**位元組**、**路徑**（`MOVE` 是相對 `$SRC` 的路徑，`DELETE` 是相對 `$DST` 的路徑）。

## 通知行為（DSM `synonotify`）

- 只有 `NOTIFY_ON_ERROR=1` **且**系統存在 `/usr/syno/bin/synonotify` 時才會發 ——
  非 DSM 環境（例如本機測試）不會發也不會報錯。
- 事件用 `SYNOScheduledTaskComplete`，帶入 `%TASKNAME%=sync_archive` 與 `%STATUS%=<錯誤訊息>`。
- **演練模式的差異**：收尾階段的失敗（rsync 非 0、來源不可用）在 `DRY_RUN=1` 時**不發**通知；
  但前置致命錯誤（`$DST` 不可寫這類）**即使演練也會發** —— 演練的目的就是抓環境問題。

## 其他實作細節

- **conf 路徑可以用第一個參數指定**：`bash sync_archive.sh /path/to/other.conf`。
  想用同一支腳本跑多組來源，就給每組一份 conf（記得 `LOG_DIR` 也分開，鎖與摘要才不會打架）。
- `SRC` / `DST` 的尾端斜線會被自動剝除（`mount` 比對與路徑組合才不會出錯）。
- **沒有符合基準的檔時完全不呼叫 rsync**，直接進入保留階段。
- rsync 實際參數：`-a --from0 --files-from=<NUL 分隔清單> --out-format='MOVE %l %n'`；
  `DRY_RUN=1` 時改加 `--dry-run` 且**不加** `--remove-source-files`。
- 暫存檔（待搬清單、明細、rsync 輸出）建在 `$TMPDIR`（未設則 `/tmp`），結束時由 trap 清掉。
- 腳本以 `set -u` + `set -o pipefail` 執行（刻意不用 `set -e`，避免中途 return 非 0 就整支中止）。

## 可調參數（在 conf 內）

| 參數 | 預設 | 說明 |
|---|---|---|
| `ARCHIVE_BEFORE_DAYS_AGO` | 0 | 封存基準日＝今天往前推幾天的 00:00。0＝只搬今天之前（昨天及更早） |
| `RETENTION_DAYS` | 365 | NAS 保留天數，超過即刪（只作用於 `$DST`，來源永不因保留期被刪） |
| `LOG_RETENTION_DAYS` | 90 | log 保留天數 |
| `DRY_RUN` | 0 | 1＝只演練不動檔 |
| `NOTIFY_ON_ERROR` | 1 | 失敗時發 DSM 通知 |
| `REQUIRE_MOUNTPOINT` | 0 | 1＝要求 `SRC` 必須是掛載點（CIFS 部署建議開）；0＝允許本機資料夾 |
