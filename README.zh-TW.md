<h1 align="center">Tally</h1>

<p align="center">你所有的 AI 訂閱額度，一眼看盡，就在 macOS 選單列 ——<br>還有一個永遠幫你挑「餘量最多的帳號」開工的 CLI。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
</p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b></p>

為同時養著**多個 Claude（Max/Pro）與 Codex 訂閱**的重度使用者而生：Tally 把每個帳號的
5 小時工作階段、每週、旗艦模型額度並排呈現，`tally claude` 自動用餘量最好的帳號開新
session，額度撞牆時還會自動換帳號、續跑同一段對話。

<!-- TODO: 截圖（選單列 strip + 釘選面板） -->

## 功能

- **多帳號優先。** 每個 `~/.claude*` 登入與 Codex 安裝各自一張卡，N 個帳號並排呈現，
  不是單帳號 fallback。卡片可拖曳排序，順序套用到所有介面。
- **選單列 strip。** 每帳號品牌標記＋工作階段／每週百分比堆疊；同服務多帳號有迷你編號；
  滑鼠懸停看全部帳號的完整數字。
- **可釘選的毛玻璃面板。** 把儀表釘成永遠置頂的毛玻璃視窗，拖曳標題列放到任何位置。
- **每個窗自己的重置時間。** 點任何重置文字，全部在「2d 4h 後重置」與「07/18 20:00 重置」
  之間切換。
- **`tally` CLI。**
  - `tally claude [參數…]` — 用實測餘量最多的帳號啟動 Claude Code，所有參數原樣透傳。
  - **自動接手**：session 中途撞到額度上限時，tally 溫和收掉、重選最佳帳號、
    在同一個終端*續跑同一段對話* — 內建 10 分鐘 3 次熔斷，可用 `--no-handoff` 或
    `TALLY_AUTO_HANDOFF=0` 關閉。
  - `tally resume` — 同一個接手動作的手動一鍵版。
  - `tally claude --account <名稱>` — 想自己選帳號時明示指定。
  - `tally status` / `tally best-dir <provider>` — 給腳本或 shell 用。
- **五種語言。** English、繁體中文、简体中文、日本語、한국어 — app 內即時切換。
- **原生、零依賴。** Swift 6 + SwiftUI + AppKit。沒有 Electron、沒有套件，
  app 和 CLI 各一個 binary。

## 運作方式（以及它絕不做的事）

- **唯讀設計。** Tally 只讀你的 CLI 已經存在本機的 OAuth 憑證，呼叫官方 CLI 自己在輪詢的
  同一個用量端點，並誠實帶 `Tally` User-Agent。它永不寫入、刷新或輪替 token，
  所以永遠不可能弄壞你的 CLI 登入。
- **永遠只有一個輪詢者。** 只有選單列 app 會連網（預設每 5 分鐘一次）。CLI 只讀本機快照
  （`~/.tally/snapshot.json` — 只有百分比和路徑，絕無 token），開十個終端也不多打一次 API。
- **只碰你自己的帳號。** 多帳號指的是*你自己*付費、在*你自己*機器上的訂閱。Tally 不代理、
  不共享帳號池、不轉售；切換帳號只是用你本來就擁有的 config 目錄啟動官方 CLI。
- **完全本機。** 無遙測、無伺服器，除了用量讀取本身，沒有任何東西離開你的機器。

## 需求

- macOS 14+
- 已登入的 [Claude Code](https://claude.com/claude-code) — 額外帳號就是多一個 config 目錄
  （`CLAUDE_CONFIG_DIR=~/.claude2 claude` 登入即可），與／或
- 已登入的 Codex CLI（`~/.codex`）

## 安裝

簽章、自動更新的 Release 版即將推出。目前請從原始碼建置：

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

可選的 shell 捷徑：

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## 常見問題

**為什麼 macOS 從不跳鑰匙圈授權視窗？**
Tally 透過 Apple 自家的 `security` 工具讀取憑證項目（
[OpenUsage](https://github.com/robinebers/openusage) 驗證過的做法），macOS 天然信任它，
app 更新也不會重新詢問。

**所有帳號都滿了會怎樣？**
不會有戲劇性後果：儀表照實顯示，`tally claude` 警告後直接裸啟動官方 CLI，
自動接手則原地不動、不會空轉迴圈。

**自動接手會弄丟我的對話嗎？**
不會 — 它在下一個帳號上續跑同一份 session 紀錄（只新增、原始紀錄永不被修改）。
被中斷的工具呼叫可能會在切換後重跑一次。

## 授權

[MIT](LICENSE) © jetto · 部分做法與概念改編自
[OpenUsage](https://github.com/robinebers/openusage) 與
[headroom](https://github.com/domanski-ai/headroom) — 詳見
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。
