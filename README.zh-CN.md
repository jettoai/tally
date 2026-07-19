<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>

<p align="center">你的所有 AI 订阅额度，一眼看尽，就在 macOS 菜单栏，<br>还有一个启动器，让每个会话都跑在余量撑最久的账号上。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ 下载 macOS 版（macOS 14+）</b></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-TW.md">繁體中文</a> · <b>简体中文</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

Tally 是原生的 **macOS 菜单栏 AI 用量监控工具（Claude／Codex 额度）**，为同时养着**多个
Claude（Max/Pro）与 Codex 订阅**、厌倦了猜「哪个账号还有余量」的重度用户而生：每个账号
的 5 小时会话、每周、旗舰模型额度窗并排呈现在舰队仪表下，舰队仪表把它们合并成一条总预算，
并依你实测的节奏预测还能撑多久，智选会在每次开新会话时，依重置时间（不只看剩余百分比）
挑出当下余量撑最久的账号，并在对话进行中持续接管：额度撞墙时自动切换账号、
旗舰模型被降级时抢救回来，还有一条 status line 信号随时显示哪个账号正在燃烧额度。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 菜单栏条：五个 Claude 账号带编号徽章与会话／每周百分比堆叠，后接三个 Codex 账号" width="418">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 固定面板：各 provider 的舰队仪表把九个账号（五个 Claude Max、四个 Codex）合并成各自一条每周预算长条，附节奏预测（约可再用 4d 10h；此节奏可持续）与下一次错开回充；下方每个账号各自的卡片显示 5 小时会话、每周、旗舰模型额度窗，含重置时间、接近上限警示，以及标出启动器当前选择的紫色智选徽章" width="834">
</p>

## 为什么是 Tally

菜单栏用量仪表早就存在，缺的是为「同时养好几个订阅」的人打造的那一个：

- **每个账号一张卡，不是 fallback 链。** 每个账号都是自己的卡片、并排呈现，因为多订阅
  用户真正想问的就是「哪个账号还有余量」。
- **订阅额度，不是花费估算。** Tally 显示的是厂商实际执行的 5 小时／每周／旗舰模型额度窗，
  而不是用 token 数推算的金额猜测。
- **仪表看完直接行动。** 仪表盘存在的意义就是决定「下一步用哪个账号」，所以 Tally 每次都
  自动帮你做完这个决定，并在会话运行期间持续做下去（额度撞墙自动接管、模型被降级时
  抢救）。

## 功能

### 仪表盘

- **多账号优先。** 每个 `~/.claude*` 登录与 Codex 安装各自一张卡，N 个账号并排呈现，
  不是单账号 fallback。卡片可拖拽排序，顺序应用到所有界面。
- **舰队仪表。** 每个 provider 的账号合并成一条量表：连续 bar 代表合并后的每周预算，总量
  用账号份数表达（「剩 2.9/5」），加上下一次错开回充。预测会依你近期实测的节奏估算这个
  池子还能撑多久，并把每次重置补回的额度算进去：超支时显示「约可再用 4d 10h」，没超支时
  显示「此节奏可持续」。没有任何同类量表做过跨账号合并。
- **菜单栏条。** 每个账号的品牌标记＋会话／每周百分比堆叠；同服务多账号有迷你编号；
  鼠标悬停查看全部账号的完整数字。
- **可固定的毛玻璃面板。** 把仪表固定成永远置顶的毛玻璃窗口，拖拽标题栏放到任何位置，多账号可展开为 2、3 或 4 列。
- **每个窗口自己的重置时间。** 点任何重置文字，全部在「2d 4h 后重置」与「07/18 20:00 重置」
  之间切换。
- **Codex 额度重置存量，看得见也能兑换。** 累积的额度重置会直接显示在卡片上（「3 枚额度重置
  可兑换」），让你在撞墙前就知道自己还有几条退路。点一下就能兑换一枚，兑换前会弹出确认
  窗口，指名账号、列清楚成本，并在兑换多半会浪费时给出警告；最快到期的额度优先花，Tally
  永不自动帮你花掉。

### 启动控制平面

- **智选。** 新会话一律启动在「当下燃烧速率最高」的账号上：用剩余百分比除以距重置的
  时间，横跨 5 小时、每周、旗舰模型三个额度窗计算。快要重置的额度优先烧（放着不用就蒸发）；
  得撑好几天的额度会被留着；设有迟滞机制，避免噪音级别的差异让你在账号间跳来跳去。面板徽章
  标出当前选择，理由写在 tooltip 里。
- **每个 provider 三种模式。** 智选（每次启动都由算法决定）、手动（卡片上的圆圈可以
  固定一个账号；点勾选就会释放回智选，实时生效，连正在跑的会话也适用）、关闭
  （纯仪表盘，不介入启动）。
- **会话中途接管。** 撞到用量上限时，tally 在余量最好的下一个账号上续跑*同一段对话*
  （内置 10 分钟 3 次熔断，可用 `--no-handoff` 或 `TALLY_AUTO_HANDOFF=0` 关闭）。若服务器
  悄悄把你的模型降级，会优先切到仍能提供原模型的兄弟账号接管对话，只有在没人能提供时，
  才会套用你设置的 fallback 配对。不紧急的切换会等到回合之间的空档再做。
- **启动默认值，就在设置里。** 默认权限模式、启动模式（continue 或 new）、模型与 reasoning
  effort 绑成一组，另外还有一组独立的 fallback 配对（fallback 模型＋自己的 effort＋额外
  标志）。只在你没自己打标志时才会注入：你自己给的参数始终优先。
- **Shell 集成。** 一键安装 PATH shim，让连裸的 `claude` / `codex` 命令都遵循你的启动策略；
  一键移除，干净不留痕迹。
- **Status line 集成。** Claude Code 的 status line 会多一个紫色 ✦ Tally 信号（代表这个
  会话跑在 Tally 之下）与当前使用的账号名称；选择开启完整额度线后，整条额度线会用 app
  同款色板呈现：进度条、百分比与重置倒计时，涵盖这个会话实际消耗的模型层级窗、5 小时窗，
  以及每周预算（舰队仪表开启时显示合并后的舰队预算），并跟随面板的「已用量／剩余」切换。
  你原本自定义的 status line 会原封不动继续运行、只是后面多接一段信号；移除时逐字节还原成
  原样，就算你不卸载直接删掉 Tally 也照常运行。
- **`tally` CLI。** `tally claude [参数…]`、`tally resume`（把当前目录最新的一段对话搬到
  另一个账号）、`tally claude --account <名称>`、`tally status`、`tally best-dir <provider>`，
  全部对脚本友好。

### 外观与细节

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

或者完全跳过符号链接和别名：**设置 → Integrations** 一键安装 CLI 工具、shell shim
（让裸的 `claude` / `codex` 也遵循你的策略）与 status line 信号，各自一键安装、干净移除。

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

**status line 集成会破坏我自定义的 status line 吗？**
不会。你自己的命令会照原样继续运行，喂进同一份 session JSON；Tally 只是在后面加一段
信号，如果你已经显示账号名称就会跳过那部分，移除时逐字节还原成原本的注册，就算
tally 这个二进制哪天消失了，也会直接回退到运行你原本的命令。

## 许可证

[MIT](LICENSE) © [jetto](https://jetto.ai)
