<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>

<p align="center">你的所有 AI 订阅额度，一眼看尽，就在 macOS 菜单栏，<br>外加一个永远帮你挑「余量最多的账号」开工的 CLI。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ 下载 macOS 版（macOS 14+）</b></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-TW.md">繁體中文</a> · <b>简体中文</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Tally 是原生的 **macOS 菜单栏 Claude／Codex 额度监控工具**，为同时养着**多个 Claude
（Max/Pro）与 Codex 订阅**的重度用户而生：每个账号的 5 小时会话、每周、旗舰模型额度窗
并排呈现，`tally claude` 自动用余量最好的账号启动新的 Claude Code 会话，撞到 rate limit
时还会自动切换账号、续跑同一段对话。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 菜单栏条：五个 Claude 账号带编号徽章与会话／每周百分比堆叠，后接三个 Codex 账号" width="418">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 固定面板：八个账号并排（五个 Claude Max、三个 Codex），各自的 5 小时会话、每周、旗舰模型额度窗、重置时间与接近上限警示" width="560">
</p>

## 为什么是 Tally

菜单栏用量仪表早就存在，缺的是为「同时养好几个订阅」的人打造的那一个：

- **每个账号一张卡，不是 fallback 链。** 每个账号都是自己的卡片、并排呈现，因为多订阅
  用户真正想问的就是「哪个账号还有余量」。
- **订阅额度，不是花费估算。** Tally 显示的是厂商实际执行的 5 小时／每周／旗舰模型额度窗，
  而不是用 token 数推算的金额猜测。
- **仪表看完直接行动。** 仪表盘存在的意义就是决定「下一步用哪个账号」，所以 `tally claude`
  每次都自动帮你做完这个决定。

## 功能

- **多账号优先。** 每个 `~/.claude*` 登录与 Codex 安装各自一张卡，N 个账号并排呈现，
  不是单账号 fallback。卡片可拖拽排序，顺序应用到所有界面。
- **菜单栏条。** 每个账号的品牌标记＋会话／每周百分比堆叠；同服务多账号有迷你编号；
  鼠标悬停查看全部账号的完整数字。
- **可固定的毛玻璃面板。** 把仪表固定成永远置顶的毛玻璃窗口，拖拽标题栏放到任何位置。
- **每个窗口自己的重置时间。** 点任何重置文字，全部在「2d 4h 后重置」与「07/18 20:00 重置」
  之间切换。
- **`tally` CLI。**
  - `tally claude [参数…]`：用实测余量最多的账号启动 Claude Code，所有参数原样透传。
  - **自动接管**：会话中途撞到额度上限时，tally 平滑收掉、重选最佳账号、
    在同一个终端*续跑同一段对话*，内置 10 分钟 3 次熔断，可用 `--no-handoff` 或
    `TALLY_AUTO_HANDOFF=0` 关闭。
  - `tally resume`：同一个接管动作的手动一键版。
  - `tally claude --account <名称>`：想自己选账号时明示指定。
  - `tally status` / `tally best-dir <provider>`：给脚本或 shell 用。
- **五种语言。** English、繁體中文、简体中文、日本語、한국어，应用内实时切换。
- **原生、零依赖。** Swift 6 + SwiftUI + AppKit。没有 Electron、没有第三方包，
  应用和 CLI 各一个二进制。

## 工作原理（以及它绝不做的事）

- **零凭证接触。** Tally 从不碰 token、Keychain 密钥或任何厂商端点。用量通过各家
  **官方 CLI 本身**读取（`claude -p "/usage"` 与 `codex app-server`），由官方客户端用
  自己的第一方身份与自己管理的凭证向厂商取数。账号检测只确认「登录存在」（属性层探测），
  永不读出任何内容。
- **永远只有一个轮询者。** 只有菜单栏应用会执行 CLI（默认每 5 分钟，可调到 1 分钟）。
  `tally` 启动器只读本机快照（`~/.tally/snapshot.json`，只有百分比和路径、绝无 token），
  开十个终端也不多读一次。
- **只碰你自己的账号。** 多账号指的是*你自己*付费、在*你自己*机器上的订阅。Tally 不代理、
  不共享账号池、不转售；切换账号只是用你本来就拥有的 config 目录启动官方 CLI。
- **完全本机。** 无遥测、无服务器，除了用量读取本身，没有任何东西离开你的机器。

## 要求

- macOS 14+
- 已登录的 [Claude Code](https://claude.com/claude-code)，额外账号就是多一个 config 目录
  （`CLAUDE_CONFIG_DIR=~/.claude2 claude` 登录即可），与／或
- 已登录的 Codex CLI（`~/.codex`）

## 安装

从 [Releases](https://github.com/jettoai/tally/releases/latest) 下载最新的公证 DMG，
把 **Tally.app** 拖进「应用程序」后启动即可，之后的更新会在应用内自动送达。

要使用 `tally` CLI，把应用内置的那份链接到 PATH：

```sh
ln -s /Applications/Tally.app/Contents/Helpers/tally /usr/local/bin/tally
```

<details>
<summary>或从源码构建</summary>

```sh
brew install xcodegen   # 一次性
git clone https://github.com/jettoai/tally && cd tally
xcodegen generate
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'platform=macOS'
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release -destination 'platform=macOS'
```

把 `Tally.app` 从 DerivedData 移到「应用程序」，并把 `tally` 放进 PATH：

```sh
ln -s <build-products>/tally /usr/local/bin/tally
```

</details>

可选的 shell 快捷方式：

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## 本地化

Tally 内置 English、繁體中文、简体中文、日本語、한국어，设置页实时切换、免重启。
所有字符串集中在单一 Xcode String Catalog
（[`Tally/Resources/Localizable.xcstrings`](Tally/Resources/Localizable.xcstrings)），
新增语言就是「多填一列」的单文件 PR。标准是「读起来像操作系统原生文案、不像翻译」；
修正既有语言与新增语言一样欢迎。

## 参与贡献

欢迎 issue 与 pull request。开发环境照上方「从源码构建」，另有两条让项目保持健康的惯例：

- `project.yml` 是唯一事实来源；`Tally.xcodeproj` 由 XcodeGen 生成、永不手改。
- 新增用户可见字符串一律走 `L("…")` helper 进 String Catalog，五种语言一次填齐。

每个 PR 保持单一意图，并把「为什么」写进描述。

## 常见问题

**为什么 macOS 从不弹钥匙串授权窗口？**
因为 Tally 根本不读凭证：用量通过官方 CLI 获取，账号检测只做属性层的 Keychain 探测
（不取回密钥 → 不触发授权窗口）。

**所有账号都满了会怎样？**
不会有戏剧性后果：仪表如实显示，`tally claude` 警告后直接裸启动官方 CLI，
自动接管则原地不动、不会空转循环。

**自动接管会弄丢我的对话吗？**
不会：它在下一个账号上续跑同一份会话记录（只新增、原始记录永不被修改）。
被中断的工具调用可能会在切换后重跑一次。

## 许可证

[MIT](LICENSE) © [jetto](https://jetto.ai)
