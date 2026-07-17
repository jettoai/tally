<h1 align="center">Tally</h1>

<p align="center">あなたの AI サブスクリプションの残量を、macOS メニューバーでひと目で。<br>さらに、常に「いちばん余裕のあるアカウント」で作業を始める CLI 付き。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ macOS 版をダウンロード（macOS 14+）</b></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.zh-CN.md">简体中文</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a></p>

Tally は **Claude と Codex のレート制限を監視する、ネイティブの macOS メニューバー
アプリ**です。**複数の Claude（Max/Pro）や Codex サブスクリプション**を運用していて、
「どのアカウントにまだ余裕があるのか」を推測するのに疲れた人のために作られました。
各アカウントの 5 時間セッション、毎週、最上位モデルのクォータ窓を横並びで表示し、
`tally claude` は最も余裕のあるアカウントで次の Claude Code セッションを開始、
レート制限に当たれば会話の途中でも自動でアカウントを切り替えます。

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally のメニューバー表示：番号バッジ付きの 5 つの Claude アカウントとセッション／毎週のパーセンテージ、続いて 3 つの Codex アカウント" width="418">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally のピン留めパネル：8 アカウントを横並びで表示（Claude Max が 5 つ、Codex が 3 つ）。それぞれの 5 時間セッション、毎週、最上位モデルの使用状況、リセット時刻、上限接近の警告" width="560">
</p>

## なぜ Tally なのか

メニューバーの使用量メーターはすでに存在します。なかったのは「複数サブスクリプションを
同時に運用する人」のためのものです：

- **アカウントごとのカード。フォールバックチェーンではない。** 各アカウントが独立した
  カードとして横並びに表示されます。マルチアカウントユーザーが本当に知りたいのは
  「どのアカウントにまだ余裕があるか」だからです。
- **サブスクリプションのクォータ。金額の推定ではない。** Tally が表示するのは、ベンダー
  自身が実際に適用している 5 時間／毎週／最上位モデルのクォータ窓です。トークン数から
  ドル換算する推測値ではありません。
- **答えに基づいて動くランチャー。** ダッシュボードの目的は「次にどのアカウントで働くか」
  を決めることです。`tally claude` はその判断を毎回、自動で行います。

## 機能

- **マルチアカウント第一。** `~/.claude*` の各ログインと Codex インストールがそれぞれの
  カードになり、N 個のアカウントを横並びで表示。カードはドラッグで並べ替えでき、
  その順序はすべての画面に適用されます。
- **メニューバー表示。** アカウントごとのブランドマークにセッション／毎週のパーセンテージを
  縦積みで表示。同一プロバイダの複数アカウントには小さな番号バッジ。ホバーで全アカウントの
  完全な数値を確認できます。
- **ピン留めできるガラスパネル。** ダッシュボードを常に最前面のすりガラスパネルとして
  ピン留めし、ヘッダーをドラッグして好きな場所へ。
- **すべての窓にリセット時刻。** どのリセット表示をクリックしても、全体が
  「あと 2d 4h でリセット」と「07/18 20:00 にリセット」の間で切り替わります。
- **`tally` CLI。**
  - `tally claude [引数…]`：実測で最も余裕のあるアカウントで Claude Code を起動。
    引数はそのまま透過します。
  - **自動ハンドオフ**：セッション中に使用上限へ達すると、tally はクリーンに終了して
    最適なアカウントを選び直し、同じターミナルで*同じ会話*を再開します。10 分間に
    3 回のヒューズ内蔵、`--no-handoff` または `TALLY_AUTO_HANDOFF=0` で無効化できます。
  - `tally resume`：同じハンドオフを手動で行うワンライナー版。
  - `tally claude --account <名前>`：自分で選びたいときはアカウントを明示指定。
  - `tally status` / `tally best-dir <provider>`：スクリプトやシェルからの確認用。
- **5 言語対応。** English、繁體中文、简体中文、日本語、한국어。アプリ内で即時切り替え。
- **ネイティブ、依存ゼロ。** Swift 6 + SwiftUI + AppKit。Electron なし、外部パッケージなし、
  アプリと CLI はそれぞれ単一バイナリ。

## 仕組み（そして決してしないこと）

- **資格情報には一切触れない。** Tally はトークンにも Keychain の秘密にもベンダーの
  エンドポイントにも触れません。使用量は各プロバイダの**公式 CLI 自身**
  （`claude -p "/usage"` と `codex app-server`）を通じて読み取ります。公式クライアントが
  自身のファーストパーティの身元と自己管理の資格情報でベンダーと通信します。アカウント検出は
  「ログインが存在するか」の属性レベルの確認のみで、中身は決して読み出しません。
- **ポーリングは常にひとつ。** CLI を実行するのはメニューバーアプリだけです（デフォルト
  5 分間隔、最短 1 分）。`tally` ランチャーはローカルのスナップショット
  （`~/.tally/snapshot.json`：パーセンテージとパスのみ、トークンは決して含まない）を
  読むだけなので、ターミナルを 10 個開いても追加の読み取りはゼロです。
- **自分のアカウントだけ。** マルチアカウントとは、*あなた自身*が支払い、*あなたの*マシン上に
  あるサブスクリプションのことです。Tally はプロキシも、アカウントプールの共有も、転売も
  しません。アカウント切り替えは、あなたがすでに所有している config ディレクトリで公式 CLI を
  起動するだけです。
- **完全ローカル。** テレメトリなし、サーバーなし。使用量の読み取り以外、何もマシンの外へ
  出ません。

## 動作要件

- macOS 14+
- サインイン済みの [Claude Code](https://claude.com/claude-code)。追加アカウントは config
  ディレクトリを増やすだけ（`CLAUDE_CONFIG_DIR=~/.claude2 claude` でログイン）、および／または
- サインイン済みの Codex CLI（`~/.codex`）

## インストール

[Releases](https://github.com/jettoai/tally/releases/latest) から最新の公証済み DMG を
ダウンロードし、**Tally.app** をアプリケーションフォルダへドラッグして起動してください。
以降のアップデートはアプリ内で自動的に届きます。

`tally` CLI を使うには、アプリに同梱されたバイナリを PATH にリンクします：

```sh
ln -s /Applications/Tally.app/Contents/Helpers/tally /usr/local/bin/tally
```

<details>
<summary>ソースからビルドする場合</summary>

```sh
brew install xcodegen   # 初回のみ
git clone https://github.com/jettoai/tally && cd tally
xcodegen generate
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'platform=macOS'
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release -destination 'platform=macOS'
```

`Tally.app` を DerivedData からアプリケーションフォルダへ移動し、`tally` バイナリを
PATH に置きます：

```sh
ln -s <build-products>/tally /usr/local/bin/tally
```

</details>

お好みで shell エイリアスも：

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## ローカライズ

Tally は English、繁體中文、简体中文、日本語、한국어 を同梱し、設定から再起動なしで
即時に切り替えられます。すべての文字列はひとつの Xcode String Catalog
（[`Tally/Resources/Localizable.xcstrings`](Tally/Resources/Localizable.xcstrings)）に
あり、言語の追加は「列をひとつ埋める」だけの単一ファイル PR です。基準は「翻訳ではなく
OS のネイティブ文言のように読めること」。既存言語の修正も新しい言語と同じく歓迎します。

## コントリビュート

Issue と Pull Request を歓迎します。ビルド環境は上の「ソースからビルドする場合」を
参照してください。プロジェクトを健全に保つ約束事が二つあります：

- `project.yml` が唯一の情報源です。`Tally.xcodeproj` は XcodeGen が生成するもので、
  手で編集しません。
- ユーザーに見える文字列は必ず `L("…")` ヘルパー経由で String Catalog に入れ、
  5 言語すべてを埋めます。

PR はひとつの意図に絞り、「なぜ」を説明に書いてください。

## FAQ

**なぜ macOS がキーチェーンの許可を求めてこないの？**
Tally は資格情報を読まないからです。使用量は公式 CLI 経由で取得し、アカウント検出は
属性レベルの Keychain 確認のみ（秘密を取り出さない → 許可ダイアログが出ない）。

**すべてのアカウントが上限に達したら？**
劇的なことは起きません。ダッシュボードはそのまま表示し、`tally claude` は警告して素の
CLI を起動し、自動ハンドオフはループせずその場に留まります。

**自動ハンドオフで会話は失われない？**
失われません。次のアカウントで同じセッションの記録を再開します（追記のみ。元の記録が
変更されることはありません）。中断されたツール呼び出しは、切り替え後に一度だけ再実行される
ことがあります。

## ライセンス

[MIT](LICENSE) © jetto
