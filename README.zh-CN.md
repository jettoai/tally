<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>
<p align="center"><sub>by <a href="https://jetto.ai">Jetto</a></sub></p>

<p align="center">你的所有 AI 订阅额度，一眼看尽，就在 macOS 菜单栏，<br>还有一个启动器，让每个会话都跑在余量撑最久的账号上，<br>以及一块看板，盯着它启动过的每一段会话。</p>

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
并依你实测的节奏预测还能撑多久；智选会在每次开新会话时，依重置时间（不只看剩余百分比）
挑出当下余量撑最久的账号，并在对话进行中持续接管：额度撞墙时自动切换账号、旗舰模型被降级
时抢救回来、每次 `/clear` 都重新挑一次账号、账号快见底时在它下面每个会话里打上一行提醒，
还有一条 status line 信号随时显示哪个账号正在燃烧额度。最后由会话看板收尾：Tally 启动过
的每一段对话都是一张卡片，谁卡住在等你、每一段又占了机器多少资源，一目了然。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 菜单栏条：五个 Claude 账号带编号徽章与会话／Fable 百分比堆叠，后接四个 Codex 账号的会话／每周" width="445">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 面板：各 provider 的舰队仪表合并九个账号（五个 Claude Max、四个 Codex），Claude 同时显示两条跑道（Fable 池与周池长条，各附节奏预测“约可再用 4d 12h”与下一次错开回充）、Codex 一条周池（此节奏可持续）；顾问行以账号圆点显示各 provider 的每周实际需求，Claude 单一方案合并计算（5.8 acct/wk）、Codex 按方案拆分（Pro 1.7・Team 0.9），节奏超出时标示应加开一个账号；下方每个账号各自的毛玻璃卡片显示 5 小时会话、每周、旗舰模型额度窗，含重置时间、接近上限警示，以及标出启动器当前选择的紫色智选徽章；标题栏带有“用量／Token”切换" width="834">
</p>

<p align="center">
  <img src="assets/screenshot-tokens.png" alt="Tally 的 Token 分页：所选区间（今天／7 天／30 天／全部）的 Token 总计，附输入、缓存写入、缓存读取、输出的分项，Claude 与 Codex 的服务拆分，以及带占比长条的项目表，显示 Token 花到哪里去了；点一行项目会展开成一整年的每日活动，呈现为贡献记录风格的热力图，并附上过去一年的总计" width="834">
</p>

## 为什么是 Tally

菜单栏用量仪表早就存在，缺的是为「同时养好几个订阅」的人打造的那一个：

- **每个账号一张卡，不是 fallback 链。** 每个账号都是自己的卡片、并排呈现，因为多订阅
  用户真正想问的就是「哪个账号还有余量」。
- **订阅额度，不是花费估算。** Tally 显示的是厂商实际执行的 5 小时／每周／旗舰模型额度窗，
  而不是用 token 数推算的金额猜测。
- **仪表看完直接行动。** 仪表盘存在的意义就是决定「下一步用哪个账号」，所以 Tally 每次都
  自动帮你做完这个决定，并在会话运行期间持续做下去（额度撞墙自动接管、模型被降级时抢救、
  每次 `/clear` 免费重挑一次、账号快见底时打上一行提醒）。
- **会话本身，摊在一块看板上。** 没有任何同类用量工具看得到会话这一层：Tally 把它启动过
  的每一段对话画成一张卡片，指出哪一段卡住在等你，以及每一段正在吃掉机器多少资源，细到
  是哪个进程在吃内存。

## 功能

### 仪表盘

- **多账号优先。** 每个 `~/.claude*` 登录与 Codex 安装各自一张卡，N 个账号并排呈现，
  不是单账号 fallback。卡片可拖拽排序，顺序应用到所有界面。
- **舰队仪表。** 每个 provider 的账号合并成一条量表：连续 bar 代表合并后的每周预算，总量
  用账号份数表达（「剩 2.9/5」），加上下一次错开回充。预测会依你近期实测的节奏估算这个
  池子还能撑多久，并把每次重置补回的额度算进去：超支时显示「约可再用 4d 10h」，没超支时
  显示「此节奏可持续」。没有任何同类量表做过跨账号合并。
- **用量顾问。** 需要再多开一个账号吗？仪表下方每个 provider 各一行：每个你拥有的账号
  对应一个实心圆点，实测节奏要求再开一个时显示空心圆点，并标出可直接读出的每周实际需求
  数字（「5.8 acct/wk」）。横跨两种方案的舰队会按方案分开显示（「Pro 1.7・Team 0.9」），
  因为一个 200 美元方案账号周和一个 20 美元方案账号周不是同一种量，合并计算只会产生一个
  对不上任何订阅方案的数字。鼠标悬停可看按方案拆分的明细、当前燃烧速率、断粮时数与下一批
  回充；`tally status --json` 会用 `tierDemands` 发布同一份拆分。
- **菜单栏条。** 默认每个提供商一段，把该提供商的账号合计成机队量表画的同一个池，徽章标示
  这一段代表几个账号；想把账号分开看，可切换成一账号一个标记。两种模式都是会话叠在每周
  之上，鼠标悬停会列出账号、完整数字，以及没进池的账号是谁。
- **可固定的毛玻璃面板。** 把仪表固定成永远置顶的毛玻璃窗口，拖拽标题栏放到任何位置。账号
  卡片本身也会在面板背景之上以玻璃质感呈现（你关掉半透明、或系统要求降低透明度时，改为
  不透明）。
- **卡片，或每账号一行。** 账号超过六个左右，卡片格线就会撑爆屏幕，所以面板还有第二种
  密度：每个账号一行，识别信息在左侧，每个额度窗都画成一条小 bar 加数字，启动控制缩成
  图标。它藏起来的是文字、不是信息，所以窗名称、重置时间与每个控制项的作用都移进 hover
  提示（Tally 自己画在面板的玻璃上，不等系统 tooltip）。每种密度各自记住自己的栏数，列表
  密度的「自动」会问屏幕能并排几行，而不是数卡片数。
- **版面随你安排，一次一张卡。** 页脚的查看选项卡用版面图块设定密度与栏数（每个图块直接
  画出它产生的版面）、开关舰队仪表与用量顾问，把 provider 收折到自己的仪表下面，也能开启
  「按服务分组」让卡片各自落在所属 provider 的区块里，区块内同样可拖拽排序。收折的
  provider 会留着标题，这也是它回来的办法。舰队高过屏幕时会改成滚动，而不是掉出画面外。
- **Token 用量，按项目拆分。** 每个界面的标题栏切换后面都有一个 Token 视图：今天／7 天／
  30 天／全部区间的 Token 总计，附输入、缓存与输出分项、按 provider 的拆分，以及一张项目表，
  连 agent 与 workflow 的会话都会追溯回它服务的项目。点一行项目，就会展开成一整年的
  每日活动，一张按该项目自身量级分级、贡献记录风格的热力图，每天的总计只要鼠标悬停就能
  看到。数据读自 CLI 自己的本地 transcript，经增量缓存汇总（没有新数据时刷新远低于
  一秒），而且永远不离开你的电脑。
- **每个窗口自己的重置时间。** 点任何重置文字，全部在「2d 4h 后重置」与「07/18 20:00 重置」
  之间切换。
- **登录会自己照顾自己。** 鼠标悬停在卡片上就能看到该账号登录的 email；登录失效时，卡片会用
  红色标签直说，只发一条通知，点一下就在后台安静跑完该服务自己的登录流程，只需要浏览器授权
  （看得见的终端窗口是备用方案，两种做法 Tally 都不会碰到任何凭证）。
- **不用离开 app 就能添加账号。** 设置会先备好下一个账号的配置目录，默认提供共享主账号的配置
  （一套配置服务所有账号）并附上白话的隐私说明，接着跑同一套安静登录；浏览器把结果交回来时，
  新卡片就会出现。已经有的账号也能事后加入同一套共享配置（`tally share`，或设置里的那一行）：
  对话、inbox 与记忆笔记会并进主账号，什么都不删（挡路的东西会被改名、留在原地），那一行
  也白话写明共享的意思：从此每个账号都读得到每个账号的对话。
- **Codex 额度重置存量，看得见也能兑换。** 累积的额度重置会直接显示在卡片上（「3 枚额度重置
  可兑换」），让你在撞墙前就知道自己还有几条退路。点一下就能兑换一枚，兑换前会弹出确认
  窗口，指名账号、列清楚成本，并在兑换多半会浪费时给出警告；最快到期的额度优先花，Tally
  永不自动帮你花掉。

<p align="center">
  <img src="assets/screenshot-list.png" alt="同样九个账号在 Tally 的精简列表密度下、两栏并排：每个账号一行，带 provider 标记、账号名称与方案，接着每个额度窗都是一条附百分比的小 bar，登录失效的账号有警告三角形，有额度重置存量的 Codex 行显示存量数字，启动器当前选择的账号有紫色智选标记，每行末尾是固定与拖拽控制；上方是与卡片密度相同的舰队仪表与顾问行，Codex 显示 Pro 1.7・Team 0.9" width="900">
</p>

### 会话看板

- **每一段对话，都在同一块看板上。** 标题栏切换的第三个位置，就排在「用量」与「Token」
  旁边：每一段受监督的会话各一张卡片，写明它是什么（账号、模型、effort、跑在哪个
  worktree）、现在正在做什么，以及对话已经长到多大（「142k context」）。四种状态由会话
  自己的 supervisor 发布，而不是从外面猜：工作中、卡住、空闲，以及没有足够新的回报时诚实
  写出的「未回报」。点一张卡片，Tally 就把那个会话的终端标签页带到最前面（Ghostty 靠 tty，
  其他终端靠 app）。
- **卡住就是它在等你。** 唯一需要人介入的状态：Claude Code 弹出权限请求、提问或计划确认
  而没人回答时，卡片会亮起红边、开始计时等待，鼠标悬停直接写明它要什么（「Claude needs
  your permission to use Bash」）。摘要行统计整块看板的工作中／卡住／空闲／未回报，而且
  只有「卡住」那个数字会上色，也只有它大于零时才上色。
- **面板关着也看得到红点。** 只要有任何会话在等你，菜单栏条就会长出一个小红点，一个都不剩
  时立刻收掉；鼠标悬停会说有几个。
- **每段会话占了机器多少。** 每张卡片保留该会话下面整棵进程树最近十五分钟的记录：CPU、
  内存与进程数各一条 sparkline，附当前数字与这段期间的峰值，并指名吃得最凶的那个
  （「(bun)」、「(Google Chrome Helper)」），加上它派出了几个 subagent、占住哪些 port
  （就是你下一次 `pnpm dev` 会撞到的那些），以及写入磁盘的速度。警示看的是「对不对得上」
  而不是「大不大」：build 到一半的会话吃掉 300% 的核心就只是在 build，同样的燃烧发生在
  回合结束二十秒后就是残留，会拿到一个琥珀色注记；吃掉机器大半内存的会话会拿到红色注记，
  而内存要有两个证人（进程树自己的数字，加上内核回报的压力值）Tally 才敢这样说。任何读数
  都要持续好几秒才会变成警示，所以一次 GC 停顿永远不会闪红。没有任何同类用量工具读到会话
  这一层，更别说进程层。
- **一块你学得会的看板。** 按状态排序只在看板打开的那一刻决定座位，之后就定在那里（一块
  每秒重排两次的看板，没有人学得会）；拖动任何一张卡，顺序就变成你的。筛选可以只看已连接
  的会话、也可以全部显示，未回报的会变暗但仍然点得动；看板还记住自己的栏数，与仪表盘的
  分开算。

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
- **窗口边界是免费的搬家机会。** 你敲下 `/clear` 的那一刻，对话是空的：没有回合会被打断、
  没有 context 要重载、没有东西可以损失。所以 Tally 会在那一刻再问一次账号的问题，改成
  一件工作问一次、而不是一次启动问一次，并在当前这个账号快见底时，把全新的窗口搬到余量
  最多的账号上。触发依据是事实、不是猜测：Claude Code 自己的 status line 会回报新的对话
  id，所以被提示吞掉的 `/clear` 不会搬动任何东西。
- **快用完的账号会自己说出来。** 当一个账号的瓶颈额度窗掉到 15% 以下，Tally 会在它下面
  每个会话的输入框打上一行，指名是哪个窗卡住、什么时候回充、有几个会话在分它，以及哪个
  兄弟账号还有余量：「收个尾换账号，或者等它重置。」若所有账号都没有余裕，它就诚实地这样
  讲。要回到 30% 才会重新上膛，所以在门槛上下徘徊的账号只会讲一次；而快要重置的窗算作满
  的，因为为了一份马上就要回充的额度把你叫停，是在跟你作对。
- **叫一个正在跑的会话做事。** `tally session send "<文字>"` 会在受监督会话自己的终端里
  打上一行并按下 Enter，跟你亲手打进去一模一样：`/clear`、`/compact`、回答一条权限提示
  都行。它会在第一个安全时机落地（会话正在等待、空闲，或刚结束一个回合），时机还没到就
  排队（排进队列就算成功；被拒绝则是立刻回复并说明理由），永不打断回合，也永不跟正在那个
  窗口打字的人抢；会话派出去的 subagent 不会把它挡着。`tally session clear` 是同一个动作，
  但多了一项打字做不到的本事：如果那个会话的账号快见底、而兄弟账号还有余量，清空后的窗口
  会在同一个动作里改开在更好的账号上。所有内容都只写进你自己的终端、永远不会送给任何
  vendor，上限 200 bytes，并记录在本机。
- **平行的工作线。** `tally claude -w <名称>` 会在 git worktree 里开会话，需要时创建
  `../<repo>-<名称>`、把项目的 Claude 记忆连过去，并执行该 repo 自己的 setup 脚本；只打
  `-w` 会列出既有的工作线让你挑。`tally worktree tree / list / root / remove` 负责照看
  它们，`remove` 会干净地收掉一条已合并的线：结束该线的所有会话、移除 worktree 与分支，
  除非你另外交代，否则 transcript 一律保留。
- **把一段对话，或一个 repo，固定住。** `tally account <名称>` 会在当前回合结束时，把你
  执行它的那个会话搬到另一个账号、对话原封不动，并一直留在那里，直到 `tally account
  --auto` 放开它。`tally model <模型> [effort]` 让这一段对话终生跑在那个模型上，撑过每一次
  重启（额度接管、重载、app 更新），这是 Claude Code 自己的 `/model` 在 supervisor 从自己
  的命令行重启之后给不了的保证。`tally project set --model <m> [--account <n>]` 声明这个
  repo（以及它的每一个 worktree）启动时用什么；app 的默认值会让位给它，而你自己打的标志
  又赢过它。在 Claude Code 里面，随附的 `/tally` 命令可以切换账号或模型而不用唤醒模型，
  `/tally-account` ／ `/tally-model` 不带参数则会叫出 app 自己画的原生选择面板：一份列表、
  点一下，答案就回到 CLI。
- **配置改一次，所有会话重载。** `tally reload` 会让每个受监督的会话在下一个安静时刻重新
  启动，于是改过的 hook、skill 或 CLAUDE.md 不必你逐个终端走一遍，就能送到每一个开着的
  窗口。对话会留着（重启走的是与额度接管同一条 resume 路径），正在流式输出或正在被打字
  的会话不会被动到，而反正都要重启的会话，也顺便从快见底的账号上搬走。
- **启动默认值，就在设置里。** 默认权限模式、启动模式（continue 或 new）、模型与 reasoning
  effort 绑成一组，另外还有一组独立的 fallback 配对（fallback 模型＋自己的 effort＋额外
  标志）。只在你没自己打标志时才会注入：你自己给的参数始终优先。
- **模型改一次，所有 session 跟着换。** 把默认模型或 effort 指到别处，每个运行中的受监督
  session 都会在下一个安静时刻跟进、接续同一段对话；不用逐个 terminal 打 `/model`。
  你自己输入的模型或 effort 永远不会被碰，`--no-follow` 可让单个 session 退出跟随。
- **Shell 集成。** 一键安装 PATH shim，让连裸的 `claude` / `codex` 命令都遵循你的启动策略；
  一键移除，干净不留痕迹。
- **Status line 集成。** Claude Code 的 status line 会多一个紫色 ✦ Tally 信号（代表这个
  会话跑在 Tally 之下）、当前使用的账号名称，以及这个会话正在跑的模型与 effort；选择开启
  完整额度线后，整条额度线会用 app 同款色板呈现：进度条、百分比与重置倒计时，涵盖 5 小时窗
  与这个账号的每周预算，并跟随面板的「已用量／剩余」切换。合并后的舰队视图留在 app 与
  `tally status`，那里才有空间好好呈现。
  你原本自定义的 status line 会原封不动继续运行、只是后面多接一段信号；移除时逐字节还原成
  原样，就算你不卸载直接删掉 Tally 也照常运行。
- **Claude Code skill。** 一键把一个小 skill 放进每个 Claude 账号的 skills 文件夹，让 agent
  会话学会从 `tally status --json` 回答额度问题、挑选账号（也会在重度多 agent 工作开跑前
  先确认瓶颈额度窗）；移除时同样干净不留痕迹。同一次安装还会加上 `/tally` 命令，并注册
  原生选择面板背后的 MCP server。
- **`tally` CLI。** 启动：`tally claude [参数…]`、`tally claude --account <名称>`、
  `tally claude -w <名称>`（worktree）、`tally resume`（把当前目录最新的一段对话搬到另一个
  账号）、`tally add <provider>`（再登录一个账号：自动挑下一个空编号、配置目录也帮你建好；
  主账号那一套配置，CLAUDE.md/AGENTS.md、skills、hooks、agents、设置与对话记录，默认就会
  用符号链接接进来，一套配置服务所有账号，加 `--no-share` 可退出）、`tally share`（把你
  已经有的账号放上同一套配置）。查看：`tally status`（加上 `--json` 会输出版本化的机器
  可读报告：每个账号的额度窗与重置时间、现在启动会落在哪个账号，以及每个受监督的会话
  正在跑什么，可直接喂给你自己的脚本、hook 与 agent skill）、`tally worktree tree|list|root`、
  `tally best-dir <provider>`。操控：`tally account`、`tally model`、`tally project`、
  `tally session send|clear`、`tally reload`。维护：`tally update`、`tally completion zsh`、
  `tally worktree remove`。全部对脚本友好。

### 外观与细节

- **五种语言。** English、繁體中文、简体中文、日本語、한국어，应用内实时切换。
- **原生。** Swift 6 + SwiftUI + AppKit，没有 Electron。唯一的第三方依赖是
  [Sparkle](https://sparkle-project.org)（macOS 标准更新框架），应用和 CLI 各一个二进制。

## 工作原理（以及它绝不做的事）

- **零凭证接触。** Tally 从不碰 token、Keychain 密钥或任何厂商端点。用量通过各家
  **官方 CLI 本身**读取（`claude -p "/usage"` 与 `codex app-server`），由官方客户端用
  自己的第一方身份与自己管理的凭证向厂商取数。账号检测只确认「登录存在」（属性层探测），
  永不读出任何内容。
- **只读，只有一个明确例外。** `claude auth login` 完成 OAuth 流程后就停手，所以 Tally
  帮你新建并登录的配置 home，第一次启动时仍会撞见首次运行向导：主题选择，以及要求你登录
  刚刚才登录的那个账号。所以在 Tally 自己驱动的一次登录之后（新增账号，或从卡片续签），
  它会把 Claude Code 自己记录「向导已完成」的那个字段 `hasCompletedOnboarding` 合并进
  那一个 home 的状态文件，Tally 新建的 home 也会预先带入你在既有账号上已经回答过的文件夹
  信任答案。只合并，绝不整份覆盖；解析不了的文件会直接拒写，而不是被改写；已经跑过向导
  的 home 会原封不动、逐字节保留。永不碰凭证，也永不扫描其他 home 去修补。
- **永远只有一个轮询者。** 只有菜单栏应用会执行 CLI（默认每 1 分钟，可放宽到 2／5／15 分钟）。
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

或者完全跳过符号链接和别名：**设置 → Integrations** 里每一项都是一键安装、一键干净移除，
上方还有一个「全部安装」开关管住整组：CLI 工具、shell shim（让裸的 `claude` / `codex`
也遵循你的策略）、status line 信号、会话看板的通知 hook、subagent 计数 hook，以及带着
`/tally` 命令的 Claude Code skill。每一行 hook 都给同一个承诺：你原本注册在那个事件上的
东西照常运行，移除时也只拿掉 Tally 自己那一条。把既有账号接上共享配置在这里也有一行，
但刻意不纳入「全部安装」：那一项会在 config home 之间搬动对话，而一个意思是「全部打开」
的按键，未必也代表那件事。

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

**Tally 和 ccusage 或其他用量工具有什么不同？**
[ccusage](https://github.com/ryoppippi/ccusage) 这类工具是终端 CLI，从本地 log 估算 token
花费；多数菜单栏仪表也只看单个账号。Tally 是原生 GUI，显示的是厂商实际强制的额度窗口
（5 小时、每周、旗舰模型），同时覆盖多个 Claude 与 Codex 账号，还附带一个依据这些数字
行动的启动器。Token 视图也把「我到底烧了多少、烧在哪」这题一并覆盖，按项目拆分，直接读
本地 transcript，不做金额猜测。而会话看板又比它们都再深一层：每一段运行中的会话都是一张
卡片，谁卡住在等你、每一段又占了机器多少资源，细到是哪个进程占着内存。只读，仅用于你自己
付费的订阅。

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

## 致谢

Tally 走在几个优秀项目开出的路上：

- [ccusage](https://github.com/ryoppippi/ccusage)：最早把 Claude Code 本地日志变成用量洞察，
  证明了开发者有多想看到自己的数字。
- [OpenUsage](https://github.com/robinebers/openusage) 与
  [AIUsage](https://github.com/sylearn/AIUsage)：确立了菜单栏仪表一眼看用量的形式；
  Tally 的存在，是因为我们想把这一眼同时看遍多个账号。
- [Sparkle](https://sparkle-project.org)：驱动应用内自动更新。

## 许可证

[MIT](LICENSE) © [jetto](https://jetto.ai)
