<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>

<p align="center">你所有的 AI 訂閱額度，一眼看盡，就在 macOS 選單列，<br>還有一個永遠幫你挑「餘量最多的帳號」開工的 CLI。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ 下載 macOS 版（macOS 14+）</b></a></p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Tally 是原生的 **macOS 選單列 AI 用量監控工具（Claude／Codex 額度）**，為同時養著**多個 Claude
（Max/Pro）與 Codex 訂閱**的重度使用者而生：每個帳號的 5 小時工作階段、每週、旗艦模型
額度窗並排呈現，`tally claude` 自動用餘量最好的帳號開新的 Claude Code session，撞到
rate limit 時還會自動換帳號、續跑同一段對話。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 選單列 strip：五個 Claude 帳號帶編號徽章與工作階段／每週百分比堆疊，後接三個 Codex 帳號" width="418">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 釘選面板：八個帳號並排（五個 Claude Max、三個 Codex），各自的 5 小時工作階段、每週、旗艦模型額度窗、重置時間與接近上限警示" width="560">
</p>

## 為什麼是 Tally

選單列用量儀表早就存在，缺的是為「同時養好幾個訂閱」的人打造的那一個：

- **每帳號一張卡，不是 fallback 鏈。** 每個帳號都是自己的卡片、並排呈現，因為多訂閱使用者
  真正想問的就是「哪個帳號還有餘量」。
- **訂閱額度，不是花費估算。** Tally 顯示的是原廠實際執行的 5 小時／每週／旗艦模型額度窗，
  而不是用 token 數推算的金額猜測。
- **儀表看完直接行動。** 儀表板存在的意義就是決定「下一步用哪個帳號」，所以 `tally claude`
  每次都自動幫你做完這個決定。

## 功能

- **多帳號優先。** 每個 `~/.claude*` 登入與 Codex 安裝各自一張卡，N 個帳號並排呈現，
  不是單帳號 fallback。卡片可拖曳排序，順序套用到所有介面。
- **選單列 strip。** 每帳號品牌標記＋工作階段／每週百分比堆疊；同服務多帳號有迷你編號；
  滑鼠懸停看全部帳號的完整數字。
- **可釘選的毛玻璃面板。** 把儀表釘成永遠置頂的毛玻璃視窗，拖曳標題列放到任何位置。
- **每個窗自己的重置時間。** 點任何重置文字，全部在「2d 4h 後重置」與「07/18 20:00 重置」
  之間切換。
- **`tally` CLI。**
  - `tally claude [參數…]`：用實測餘量最多的帳號啟動 Claude Code，所有參數原樣透傳。
  - **自動接手**：session 中途撞到額度上限時，tally 溫和收掉、重選最佳帳號、
    在同一個終端*續跑同一段對話*，內建 10 分鐘 3 次熔斷，可用 `--no-handoff` 或
    `TALLY_AUTO_HANDOFF=0` 關閉。
  - `tally resume`：同一個接手動作的手動一鍵版。
  - `tally claude --account <名稱>`：想自己選帳號時明示指定。
  - `tally status` / `tally best-dir <provider>`：給腳本或 shell 用。
- **五種語言。** English、繁體中文、简体中文、日本語、한국어，app 內即時切換。
- **原生、零依賴。** Swift 6 + SwiftUI + AppKit。沒有 Electron、沒有套件，
  app 和 CLI 各一個 binary。

## 運作方式（以及它絕不做的事）

- **零憑證接觸。** Tally 從不碰 token、Keychain 密鑰或任何 vendor 端點。用量透過各家
  **官方 CLI 本人**讀取（`claude -p "/usage"` 與 `codex app-server`），由官方客戶端用
  自己的第一方身分與自己管理的憑證向原廠取數。帳號偵測只確認「登入存在」（屬性層探測），
  永不讀出任何內容。
- **永遠只有一個輪詢者。** 只有選單列 app 會執行 CLI（預設每 5 分鐘，可調到 1 分鐘）。
  `tally` 啟動器只讀本機快照（`~/.tally/snapshot.json`，只有百分比和路徑、絕無 token），
  開十個終端也不多讀一次。
- **只碰你自己的帳號。** 多帳號指的是*你自己*付費、在*你自己*機器上的訂閱。Tally 不代理、
  不共享帳號池、不轉售；切換帳號只是用你本來就擁有的 config 目錄啟動官方 CLI。
- **完全本機。** 無遙測、無伺服器，除了用量讀取本身，沒有任何東西離開你的機器。

## 需求

- macOS 14+
- 已登入的 [Claude Code](https://claude.com/claude-code)，額外帳號就是多一個 config 目錄
  （`CLAUDE_CONFIG_DIR=~/.claude2 claude` 登入即可），與／或
- 已登入的 Codex CLI（`~/.codex`）

## 安裝

從 [Releases](https://github.com/jettoai/tally/releases/latest) 下載最新的公證 DMG，
把 **Tally.app** 拖進「應用程式」後啟動即可，之後的更新會在 app 內自動送達。

要使用 `tally` CLI，把 app 內建的那份連結到 PATH：

```sh
ln -s /Applications/Tally.app/Contents/Helpers/tally /usr/local/bin/tally
```

<details>
<summary>或從原始碼建置</summary>

```sh
brew install xcodegen   # 一次性
git clone https://github.com/jettoai/tally && cd tally
xcodegen generate
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'platform=macOS'
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release -destination 'platform=macOS'
```

把 `Tally.app` 從 DerivedData 移到「應用程式」，並把 `tally` 放進 PATH：

```sh
ln -s <build-products>/tally /usr/local/bin/tally
```

</details>

可選的 shell 捷徑：

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## 在地化

Tally 內建 English、繁體中文、简体中文、日本語、한국어，設定頁即時切換、免重啟。
所有字串集中在單一 Xcode String Catalog
（[`Tally/Resources/Localizable.xcstrings`](Tally/Resources/Localizable.xcstrings)），
新增語言就是「多填一欄」的單檔 PR。標準是「讀起來像作業系統原生文案、不像翻譯」；
修正既有語言與新增語言一樣歡迎。

## 參與貢獻

歡迎 issue 與 pull request。開發環境照上方「從原始碼建置」，另有兩條讓專案保持健康的慣例：

- `project.yml` 是唯一真相來源；`Tally.xcodeproj` 由 XcodeGen 產生、永不手改。
- 新增使用者可見字串一律走 `L("…")` helper 進 String Catalog，五種語言一次填齊。

每個 PR 保持單一意圖，並把「為什麼」寫進描述。

## 常見問題

**為什麼 macOS 從不跳鑰匙圈授權視窗？**
因為 Tally 根本不讀憑證：用量透過官方 CLI 取得，帳號偵測只做屬性層的 Keychain 探測
（不取回密鑰 → 不觸發授權視窗）。

**所有帳號都滿了會怎樣？**
不會有戲劇性後果：儀表照實顯示，`tally claude` 警告後直接裸啟動官方 CLI，
自動接手則原地不動、不會空轉迴圈。

**自動接手會弄丟我的對話嗎？**
不會：它在下一個帳號上續跑同一份 session 紀錄（只新增、原始紀錄永不被修改）。
被中斷的工具呼叫可能會在切換後重跑一次。

## 授權

[MIT](LICENSE) © [jetto](https://jetto.ai)
