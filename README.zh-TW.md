<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>
<p align="center"><sub>by <a href="https://jetto.ai">Jetto</a></sub></p>

<p align="center">你所有的 AI 訂閱額度，一眼看盡，就在 macOS 選單列，<br>還有一個啟動器，讓每個 session 都跑在餘量撐最久的帳號上。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ 下載 macOS 版（macOS 14+）</b></a></p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Tally 是原生的 **macOS 選單列 AI 用量監控工具（Claude／Codex 額度）**，為同時養著**多個 Claude
（Max/Pro）與 Codex 訂閱**、厭倦了猜「哪個帳號還有餘量」的重度使用者而生：每個帳號的 5 小時
工作階段、每週、旗艦模型額度窗並排呈現在艦隊儀表下，艦隊儀表把它們合池成一條總預算，並
依你實測的節奏預測還能撐多久，智選會在每次開新 session 時，依重置時間（不只看剩餘百分比）
挑出當下餘量撐最久的帳號，並在對話進行中持續接手：額度撞牆時自動換帳號、
旗艦模型被降級時搶救回來，還有一條 status line 訊號隨時顯示哪個帳號正在燃燒額度。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 選單列 strip：五個 Claude 帳號帶編號徽章與工作階段／Fable 百分比堆疊，後接四個 Codex 帳號的工作階段／每週" width="445">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 釘選面板：各 provider 的艦隊儀表合池九個帳號（五個 Claude Max、四個 Codex），Claude 同時顯示兩條跑道（Fable 池與週池長條，各附節奏預測「約可再用 4d 12h」與下一筆錯開回充）、Codex 一條週池（此節奏可持續）；下方每個帳號各自的卡片顯示 5 小時工作階段、每週、旗艦模型額度窗，含重置時間、接近上限警示，以及標出啟動器目前選擇的紫色智選徽章" width="834">
</p>

## 為什麼是 Tally

選單列用量儀表早就存在，缺的是為「同時養好幾個訂閱」的人打造的那一個：

- **每帳號一張卡，不是 fallback 鏈。** 每個帳號都是自己的卡片、並排呈現，因為多訂閱使用者
  真正想問的就是「哪個帳號還有餘量」。
- **訂閱額度，不是花費估算。** Tally 顯示的是原廠實際執行的 5 小時／每週／旗艦模型額度窗，
  而不是用 token 數推算的金額猜測。
- **儀表看完直接行動。** 儀表板存在的意義就是決定「下一步用哪個帳號」，所以 Tally 每次都
  自動幫你做完這個決定，並在 session 執行期間持續做下去（額度撞牆自動接手、模型被降級時
  搶救）。

## 功能

### 儀表板

- **多帳號優先。** 每個 `~/.claude*` 登入與 Codex 安裝各自一張卡，N 個帳號並排呈現，
  不是單帳號 fallback。卡片可拖曳排序，順序套用到所有介面。
- **艦隊儀表。** 每個 provider 的帳號合併成一條量表：連續 bar 代表合併後的每週預算，總量
  用帳號份數表達（「剩 2.9/5」），加上下一筆錯開回充。預測會依你近期實測的節奏估算這個
  池子還能撐多久，並把每次重置補回的額度算進去：超支時顯示「約可再用 4d 10h」，沒超支時
  顯示「此節奏可持續」。沒有任何同類量表做過跨帳號合池。
- **選單列 strip。** 每帳號品牌標記＋工作階段／每週百分比堆疊；同服務多帳號有迷你編號；
  滑鼠懸停看全部帳號的完整數字。
- **可釘選的毛玻璃面板。** 把儀表釘成永遠置頂的毛玻璃視窗，拖曳標題列放到任何位置，多帳號可展開成 2、3 或 4 欄。
- **每個窗自己的重置時間。** 點任何重置文字，全部在「2d 4h 後重置」與「07/18 20:00 重置」
  之間切換。
- **Codex 額度重置存量，看得到也能兌換。** 累積的額度重置會直接顯示在卡片上（「3 枚額度重置
  可兌換」），讓你在撞牆前就知道自己還有幾條退路。點一下就能兌換一枚，兌換前會跳出確認
  視窗，指名帳號、列清楚成本，並在兌換多半會浪費時提出警告；最快到期的額度優先花，Tally
  永不自動幫你花掉。

### 啟動控制平面

- **智選。** 新 session 一律啟動在「當下燒錢速率最高」的帳號上：用剩餘百分比除以到重置的
  時間，橫跨 5 小時、每週、旗艦模型三個額度窗計算。快要重置的額度優先燒（放著不用就蒸發）；
  得撐好幾天的額度會被留著；設有遲滯機制，避免噪音等級的差異讓你在帳號間跳來跳去。面板徽章
  標出目前的選擇，理由寫在 tooltip 裡。
- **每個 provider 三種模式。** 智選（每次啟動都由演算法決定）、手動（卡片上的圓圈可以
  釘住一個帳號；點勾勾就會釋放回智選，即時生效，連正在跑的 session 也適用）、關閉
  （純儀表板，不介入啟動）。
- **session 中途接手。** 撞到用量上限時，tally 在餘量最好的下一個帳號上續跑*同一段對話*
  （內建 10 分鐘 3 次熔斷，可用 `--no-handoff` 或 `TALLY_AUTO_HANDOFF=0` 關閉）。若伺服器
  悄悄把你的模型降級，會優先切到還能提供原本模型的手足帳號接手對話，只有在沒人能提供時，
  才會套用你設定的 fallback 配對。不緊急的切換會等到回合之間的空檔再做。
- **啟動預設值，就在設定裡。** 預設權限模式、啟動模式（continue 或 new）、模型與 reasoning
  effort 綁成一組，另外還有一組獨立的 fallback 配對（fallback 模型＋自己的 effort＋額外
  旗標）。只在你沒自己打旗標時才會注入：你自己下的參數永遠優先。
- **模型改一次，所有 session 跟著換。** 把預設模型或 effort 指到別處，每個執行中的受監督
  session 都會在下一個安靜時刻跟進、接續同一段對話；不用逐個 terminal 打 `/model`。
  你自己打的模型或 effort 永遠不會被碰，`--no-follow` 可讓單一 session 退出跟隨。
- **Shell 整合。** 一鍵安裝 PATH shim，讓連裸的 `claude` / `codex` 指令都遵循你的啟動策略；
  一鍵移除，乾淨不留痕跡。
- **Status line 整合。** Claude Code 的 status line 會多一個紫色 ✦ Tally 訊號（代表這個
  session 跑在 Tally 底下）與目前使用的帳號名稱；選擇開啟完整額度線後，整條額度線會用 app
  同款色板呈現：進度條、百分比與重置倒數，涵蓋這個 session 實際消耗的模型層級窗、5 小時窗，
  以及每週預算（艦隊儀表開著時顯示合池後的艦隊預算），並跟隨面板的「已用量／剩餘」切換。
  既有自訂的 status line 會原封不動繼續執行、只是後面多接一段訊號；移除時逐位元組還原成
  原樣，就算你不解除安裝直接刪掉 Tally 也照常運作。
- **`tally` CLI。** `tally claude [參數…]`、`tally resume`（把目前目錄最新的一段對話搬到
  另一個帳號）、`tally claude --account <名稱>`、`tally status`、`tally add <provider>`
  （再登入一個帳號：自動挑下一個空編號、目錄也幫你建好）、`tally best-dir <provider>`，
  全部對腳本友善。

### 介面與細節

- **五種語言。** English、繁體中文、简体中文、日本語、한국어，app 內即時切換。
- **原生。** Swift 6 + SwiftUI + AppKit，沒有 Electron。唯一的第三方依賴是
  [Sparkle](https://sparkle-project.org)（macOS 標準更新框架），app 和 CLI 各一個 binary。

## 運作方式（以及它絕不做的事）

- **零憑證接觸。** Tally 從不碰 token、Keychain 密鑰或任何 vendor 端點。用量透過各家
  **官方 CLI 本人**讀取（`claude -p "/usage"` 與 `codex app-server`），由官方客戶端用
  自己的第一方身分與自己管理的憑證向原廠取數。帳號偵測只確認「登入存在」（屬性層探測），
  永不讀出任何內容。
- **永遠只有一個輪詢者。** 只有選單列 app 會執行 CLI（預設每 1 分鐘，可放寬到 2／5／15 分鐘）。
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

或者完全跳過符號連結和別名：**設定 → Integrations** 一鍵安裝 CLI 工具、shell shim
（讓裸的 `claude` / `codex` 也遵循你的策略）與 status line 訊號，各自一鍵安裝、乾淨移除。

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

**Tally 跟 ccusage 或其他用量工具有什麼不同？**
[ccusage](https://github.com/ryoppippi/ccusage) 這類工具是終端機 CLI，從本機 log 估算 token
花費；多數 menu bar 儀表也只看單一帳號。Tally 是原生 GUI，顯示的是廠商實際強制的額度視窗
（5 小時、每週、旗艦模型），同時涵蓋多個 Claude 與 Codex 帳號，還附一個依這些數字行動的
啟動器。唯讀，只用於你自己付費的訂閱。

**為什麼 macOS 從不跳鑰匙圈授權視窗？**
因為 Tally 根本不讀憑證：用量透過官方 CLI 取得，帳號偵測只做屬性層的 Keychain 探測
（不取回密鑰 → 不觸發授權視窗）。

**所有帳號都滿了會怎樣？**
不會有戲劇性後果：儀表照實顯示，`tally claude` 警告後直接裸啟動官方 CLI，
自動接手則原地不動、不會空轉迴圈。

**自動接手會弄丟我的對話嗎？**
不會：它在下一個帳號上續跑同一份 session 紀錄（只新增、原始紀錄永不被修改）。
被中斷的工具呼叫可能會在切換後重跑一次。

**status line 整合會弄壞我自訂的 status line 嗎？**
不會。你自己的指令會照原樣繼續執行，餵進同一份 session JSON；Tally 只是在後面加一段
訊號，如果你已經顯示帳號名稱就會跳過那部分，移除時逐位元組還原成原本的註冊，就算
tally 這個 binary 哪天不見了，也會直接 fallback 回執行你原本的指令。

## 致謝

Tally 走在幾個優秀專案開出的路上：

- [ccusage](https://github.com/ryoppippi/ccusage)：最早把 Claude Code 本機日誌變成用量洞察，
  證明了開發者有多想看到自己的數字。
- [OpenUsage](https://github.com/robinebers/openusage) 與
  [AIUsage](https://github.com/sylearn/AIUsage)：確立了選單列儀表一眼看用量的形式；
  Tally 的存在，是因為我們想把這一眼同時看遍多個帳號。
- [Sparkle](https://sparkle-project.org)：驅動 app 內自動更新。

## 授權

[MIT](LICENSE) © [jetto](https://jetto.ai)
