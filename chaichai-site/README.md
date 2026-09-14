# 柴柴 ChaiChai — me.chaihome.cc

一個純靜態的個人自介網站。沒有 React、沒有 Vue、沒有任何建置流程，
**下載下來就是可以直接上傳的成品**，不需要 wrangler、不需要打指令。

---

## 一、這包裡面有什麼

```
index.html      ← 網頁本體（文字內容都在這裡）
style.css       ← 外觀、顏色、排版
script.js       ← 年齡自動計算、語錄隨機、燈箱、彩蛋…
robots.txt      ← 給搜尋引擎看的
sitemap.xml     ← 給搜尋引擎看的
assets/         ← 所有圖片
  hero.jpg              人像照
  night-01 ~ 06.jpg     照片牆的六張
  og.jpg                分享到社群時的預覽圖
  favicon.png           瀏覽器分頁小圖
  apple-touch-icon.png  加到手機桌面的小圖
  shiba.jpg             備用的柴犬頭像
```

> 🎵 **音樂播放器**
>
> 左下角常駐一張 240×135 的小卡片（手機約佔畫面 16%），寫著「配著自介一起食用」，
> 封面刻意做成黑白、看不出是什麼歌。點一下就開始播，封面淡掉、露出播放器，
> 右上角出現 ✕。按 ✕ 或 Esc 關掉，關掉時 iframe 會被移除，音樂是真的停。
>
> **為什麼 iPhone 上只要點一次**：iframe 在開頁時就先載好（`autoplay=0`），
> 使用者點下去時只是把「同一個既有的 iframe」重新導向到帶 `autoplay=1` 的網址。
> 對 WebKit 來說這是發生在使用者手勢之中的導向，所以會放行。
> 如果改成點擊當下才新建 iframe，iOS 會擋掉，就得點兩次 —— 這是很容易踩到的坑，
> 之後要改這段的話請保留「先建好、再換 src」的順序。
>
> **要換歌**：`script.js` 最上面 `var YT_ID = 'dQw4w9WgXcQ';`，
> 換成 YouTube 網址 `watch?v=` 後面那串。
>
> **要改字**：`index.html` 搜尋 `player__label`（「配著自介一起食用」）
> 和 `player__hint`（「點這裡任何地方，會直接開始播」）。

---

## 二、部署到 Cloudflare（全程用網頁後台，不用打指令）

### 步驟 1：先準備好 ZIP

**這一步最容易出錯，請看仔細：**

ZIP 打開後，第一層要**直接看到 `index.html`**，不可以先看到一層資料夾。

✅ 正確
```
我的網站.zip
 ├── index.html
 ├── style.css
 ├── script.js
 └── assets/
```

❌ 錯誤（多包了一層，網站會打不開）
```
我的網站.zip
 └── chaichai-site/
      ├── index.html
      └── ...
```

**Mac 的做法**：打開資料夾 → 全選裡面的檔案（⌘A）→ 右鍵 → 「壓縮 N 個項目」。
**注意是進到資料夾裡面全選檔案，不是對著資料夾本身按壓縮。**

**Windows 的做法**：進到資料夾 → 全選（Ctrl+A）→ 右鍵 → 傳送到 → 壓縮的資料夾。

> 我附給你的 ZIP 已經是正確格式了，可以直接用。這段是之後你自己改完要重傳時看的。

### 步驟 2：上傳

1. 到 <https://dash.cloudflare.com> 登入。
2. 左邊選單找 **Workers & Pages**（有些帳號顯示為「Compute」或「運算」）。
3. 按 **Create / 建立**。
4. 找到**上傳靜態檔案**的選項，按下去。依帳號不同，按鈕可能叫：
   - **Upload assets／上傳資產**（新版，建立的是一個 Worker）
   - 或先切到 **Pages** 分頁 → **Upload assets／直接上傳**（舊版）
   - 兩個都可以，選得到哪個就用哪個。
5. 幫它取個名字，例如 `chaichai`。
6. 把步驟 1 的 ZIP 拖進去（或按 select from computer 選檔案）。
7. 按 **Deploy／部署**，等幾秒。

完成後會給你一個網址，長得像 `chaichai.你的帳號.workers.dev` 或 `chaichai.pages.dev`。
先點開來確認網站正常。

### 步驟 3：綁上 me.chaihome.cc

1. 進到剛剛建立的那個專案。
2. 找 **Settings／設定** → **Domains & Routes**（或 **Custom domains／自訂網域**）。
3. 按 **Add／新增**，輸入 `me.chaihome.cc`，送出。
4. `chaihome.cc` 這個網域如果已經在你這個 Cloudflare 帳號底下，DNS 會自動設好，
   等一下下（通常幾分鐘內）就能用了。

---

## 三、以後想改東西

改完之後，重新照「步驟 1 → 步驟 2」做一次，在同一個專案裡按
**Upload／上傳新版本**（不是重新建一個），網址不會變。

常見的幾個修改，都在 `index.html` 裡面，用記事本或 VS Code 打開搜尋就好：

| 想改什麼 | 搜尋這個關鍵字 | 說明 |
|---|---|---|
| 最後更新日期 | `id="updated"` | 兩個地方都要改：`datetime="2026-09-14"` 和後面顯示的 `2026 / 09 / 14` |
| 語錄句子 | `var QUOTES` | 在 **`script.js`** 裡，每句用 `'單引號'` 包住，句尾加逗號 |
| 社群連結 | `dir__p` | 把對應那行的 `href="..."` 換掉即可 |
| 遊戲清單 | `roster__n` | 照著現有格式複製一行加上去 |
| 照片牆說明文字 | `figcaption` | 改 `<figcaption>` 中間的字 |

**年齡不用改。** 網頁會自己用 2006/03/15 算出來，每年生日自動 +1。

### 之後要新增社群連結

照著現有那幾行的格式複製一行就好。另外有兩個小功能可以用：

- 還沒有網址 → 寫成 `<a href="#" data-pending>`，點下去會顯示「這個連結還沒補上」，不會跳到怪地方。
- 想讓人點一下就複製（例如某個 ID）→ 寫成 `<a href="#" data-copy="要複製的文字">`。

### 換照片

把新圖片放進 `assets/`，檔名取成跟原本一樣（例如 `night-03.jpg`）直接蓋掉，最省事。
如果檔名不一樣，要去 `index.html` 把對應的 `src="assets/night-03.jpg"` 改掉，
順便把同一行的 `width="..."` `height="..."` 改成新圖片的實際尺寸（避免版面跳動）。

> 照片上傳前建議先縮到長邊 1300px 左右。
> 這包裡的圖我已經壓縮過，也**清掉了 EXIF 裡的 GPS 定位資訊**，
> 你自己換新圖時記得注意這件事（iPhone 拍的照片預設會夾帶拍攝地點）。

---

## 四、先在自己電腦看看（選用）

直接用瀏覽器打開 `index.html` 就能看，大部分功能都正常。
只有「複製這句」按鈕在 `file://` 開啟時可能被瀏覽器擋住，上線後就正常了。

---

## 五、技術規格（給之後可能幫你改的人看）

- 純 HTML / CSS / 原生 JavaScript，零相依套件、零建置流程
- 手機優先的 RWD，測過 320 / 360 / 390 / 430 / 768 / 1024 / 1440px，無橫向捲動
- 圖片 `loading="lazy"`、音檔 `preload="none"`
- 具備 meta description、Open Graph、Twitter Card、JSON-LD (schema.org Person)
- 尊重 `prefers-reduced-motion`：使用者關閉動畫時，星空與進場效果會自動停用
- 鍵盤可操作（Tab 導覽、照片可用 Enter 開啟、Esc 關閉燈箱），有 skip link
- 字體來自 Google Fonts（思源宋體 / 思源黑體 / JetBrains Mono），
  載不到時會自動退回系統字體，版面不會壞掉

---

> 這份 README 一起放在 ZIP 裡了。上傳後它會變成一個公開檔案（`me.chaihome.cc/README.md`），
> 內容沒有敏感資訊，不介意的話放著就好；想乾淨一點的話，上傳前把它刪掉即可。
