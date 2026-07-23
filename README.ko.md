<p align="center">
  <a href="https://github.com/jettoai/tally/releases/latest"><img src="assets/app-icon.svg" height="140" alt="Tally app icon"></a>
</p>
<h1 align="center">Tally</h1>
<p align="center"><sub>by <a href="https://jetto.ai">Jetto</a></sub></p>

<p align="center">보유한 모든 AI 구독의 잔여 한도를 macOS 메뉴 막대에서 한눈에.<br>게다가 모든 세션을 「한도가 가장 오래 버티는 계정」에 태워 주는 런처까지.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-0ea5e9?style=flat-square">
  <a href="https://github.com/jettoai/tally/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/jettoai/tally?style=flat-square&label=download&color=22c55e"></a>
</p>

<p align="center"><a href="https://github.com/jettoai/tally/releases/latest/download/Tally.dmg"><b>⬇ macOS용 다운로드 (macOS 14+)</b></a></p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b></p>

Tally는 **Claude와 Codex의 AI 사용량(사용 한도)을 모니터링하는 네이티브 macOS 메뉴
막대 앱**입니다. **여러 개의 Claude(Max/Pro)와 Codex 구독**을 운용하면서 「어느 계정에
아직 여유가 있지?」를 추측하는 데 지친 사람을 위해 만들어졌습니다. 각 계정의 5시간
세션, 주간, 최상위 모델 쿼터 창은 이를 하나의 합산 예산으로 모아 실측 속도로 얼마나
버틸지 예측하는 플릿 게이지 아래 나란히 표시되고, 스마트 선택은 남은 퍼센트뿐 아니라
리셋 시각까지 고려해 지금 여유가 가장 많은 계정으로 매번 새 세션을 시작합니다. 그리고
대화 도중에도 계속 작동합니다: 한도에 걸렸을 때의 핸드오프, 플래그십 모델이 다운그레이드
됐을 때의 구조, 그리고 어느 계정이 소모되고 있는지 보여 주는 status line 시그널까지.

<p align="center">
  <img src="assets/screenshot-menubar.png" alt="Tally 메뉴 막대: 번호 배지가 붙은 다섯 개의 Claude 계정과 세션/Fable 퍼센트, 이어서 네 개의 Codex 계정의 세션/주간" width="445">
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" alt="Tally 고정 패널: 프로바이더별 플릿 게이지가 아홉 개의 계정(Claude Max 다섯, Codex 넷)을 모아, Claude는 두 개의 잔량(Fable 풀과 주간 풀 막대, 각각 페이스 예측 '약 4d 12h 사용 가능'과 다음 시차 충전 포함), Codex는 주간 풀 하나(이 속도면 지속 가능)를 보여 줍니다. 그 아래에는 각 계정 고유의 카드가 5시간 세션, 주간, 최상위 모델 창을 리셋 시각, 한도 임박 경고, 그리고 런처가 현재 선택한 계정을 나타내는 보라색 스마트 선택 배지와 함께 보여 줍니다" width="834">
</p>

## 왜 Tally인가

메뉴 막대 사용량 미터는 이미 존재합니다. 없었던 것은 「여러 구독을 동시에 운용하는
사람」을 위한 것입니다:

- **계정마다 카드 하나, 폴백 체인이 아님.** 각 계정이 독립된 카드로 나란히 표시됩니다.
  멀티 구독 사용자가 정말 알고 싶은 것은 「어느 계정에 아직 여유가 있는가」이기 때문입니다.
- **구독 쿼터, 비용 추정이 아님.** Tally가 보여 주는 것은 벤더가 실제로 적용하는
  5시간/주간/최상위 모델 쿼터 창입니다. 토큰 수로 달러를 역산한 추측치가 아닙니다.
- **답에 따라 움직이는 런처.** 대시보드의 존재 이유는 「다음에 어느 계정으로 일할지」를
  정하는 것입니다. Tally가 그 결정을 매번 자동으로 내리고, 세션이 실행되는 동안에도
  계속 그 판단을 이어 갑니다(한도 도달 시 핸드오프, 모델 다운그레이드 시 구조).

## 기능

### 대시보드

- **멀티 계정 우선.** `~/.claude*`의 각 로그인과 Codex 설치가 각각의 카드가 되어 N개의
  계정을 나란히 표시합니다. 카드는 드래그로 순서를 바꿀 수 있고, 그 순서는 모든 화면에
  적용됩니다.
- **플릿 게이지.** 각 프로바이더의 계정을 하나의 게이지로 모읍니다: 연속된 막대가 합산된
  주간 예산을 나타내고, 총량은 계정 단위로 표시되며(「2.9/5 남음」), 다음 시차 충전도
  함께 보여 줍니다. 예측은 최근 실측 속도를 바탕으로 이 풀이 얼마나 버틸지 추정하며,
  리셋마다 돌아오는 한도도 함께 계산합니다: 충전 주기보다 빠르게 소비 중이면
  「약 4d 10h 사용 가능」, 그렇지 않으면 「이 속도면 지속 가능」이 표시됩니다. 계정을
  모아 풀링하는 사용량 게이지는 다른 어디에도 없습니다.
- **메뉴 막대 표시.** 계정별 브랜드 마크에 세션/주간 퍼센트를 세로로 쌓아 표시. 같은
  프로바이더의 여러 계정에는 작은 번호 배지가 붙고, 호버하면 모든 계정의 전체 수치를
  볼 수 있습니다.
- **고정 가능한 글래스 패널.** 대시보드를 항상 위에 떠 있는 반투명 패널로 고정하고,
  헤더를 드래그해 원하는 위치로 옮기세요. 여러 계정을 2, 3, 4열로 펼쳐서 볼 수도 있습니다.
- **모든 창에 리셋 시각.** 아무 리셋 표시나 클릭하면 전체가 「2d 4h 후 리셋」과
  「07/18 20:00 리셋」 사이에서 전환됩니다.
- **Codex 리셋 뱅킹을 한눈에 보고 그 자리에서 사용.** 쌓아 둔 한도 리셋이 카드에 그대로
  표시됩니다(「3 회 리셋 사용 가능」). 벽에 부딪히기 전에 자신의 탈출구를 미리 알 수
  있습니다. 클릭 한 번으로 하나를 사용할 수 있으며, 사용 전 계정을 명시하고 비용을
  정확히 알려 주며 사용해도 대부분 낭비될 때는 경고하는 확인 창이 뜹니다. 가장 먼저
  만료되는 크레딧부터 사용되며, Tally가 자동으로 사용하는 일은 절대 없습니다.

### 실행 컨트롤 플레인

- **스마트 선택.** 새 세션은 5시간, 주간, 최상위 모델 각 쿼터 창에서 「소비 속도가 가장
  높은」 계정으로 시작합니다(남은 퍼센트를 리셋까지 남은 시간으로 나눠 계산). 곧 리셋될
  쿼터를 먼저 소진하고(쓰지 않으면 그냥 증발하므로), 며칠을 버텨야 하는 쿼터는 아껴
  둡니다. 히스테리시스 덕분에 노이즈 수준의 차이로 계정 사이를 오가지도 않습니다. 패널
  배지가 현재 선택을 표시하고, 이유는 tooltip에 담겨 있습니다.
- **프로바이더별 3가지 모드.** 스마트(실행할 때마다 알고리즘이 판단), 수동(카드의 원을
  클릭해 계정을 고정. 체크 표시를 클릭하면 스마트로 즉시 복귀, 실행 중인 세션에도 적용),
  끄기(대시보드 기능만 하고 실행에는 관여하지 않음).
- **세션 도중 후속 처리.** 사용 한도에 도달하면 tally가 다음으로 좋은 계정에서 *같은 대화*를
  이어 갑니다(10분당 3회 퓨즈 내장, `--no-handoff` 또는 `TALLY_AUTO_HANDOFF=0`으로 끌 수
  있음). 서버가 조용히 모델을 다운그레이드하면, 원래 모델을 아직 제공할 수 있는 형제
  계정이 대화를 대신 이어받고, 아무도 제공할 수 없을 때만 설정해 둔 폴백 조합이 적용됩니다.
  급하지 않은 전환은 턴 사이의 조용한 순간까지 기다립니다.
- **설정의 실행 기본값.** 기본 권한 모드, 시작 모드(continue vs new), 모델과 reasoning
  effort를 하나의 조합으로, 그리고 별도의 폴백 조합(폴백 모델 + 자체 effort + 추가 플래그)을
  설정할 수 있습니다. 직접 플래그를 입력하지 않았을 때만 주입되므로, 직접 넘긴 인자가
  항상 우선합니다.
- **모델을 한 번 바꾸면 모든 세션이 따라옵니다.** 기본 모델이나 effort를 바꾸면 실행 중인
  감독 세션들이 각자 다음 조용한 순간에 같은 대화를 이어가며 따라옵니다. 터미널을 돌며
  `/model`을 하나씩 입력할 필요가 없습니다. 직접 입력한 모델이나 effort는 절대 건드리지
  않으며, `--no-follow`로 개별 세션을 제외할 수 있습니다.
- **셸 통합.** 클릭 한 번으로 PATH shim을 설치해 맨몸의 `claude` / `codex` 명령도 실행
  정책을 따르게 합니다. 클릭 한 번으로 깔끔하게 제거할 수 있습니다.
- **Status line 통합.** Claude Code의 status line에 보라색 ✦ Tally 시그널(이 세션이 Tally
  아래에서 실행 중임을 표시)과 현재 계정 이름이 추가됩니다. 전체 쿼터 라인을 켜면 앱과
  같은 색상 팔레트로 미터 바, 퍼센트, 리셋 카운트다운을 한 번에 보여 줍니다. 대상은 이
  세션이 실제로 소비 중인 모델 티어의 창, 5시간 창, 그리고 주간 예산(플릿 게이지가 켜져
  있으면 합산된 플릿 예산)이며, 패널의 사용량／남음 전환을 그대로 따릅니다. 기존에 쓰던
  커스텀 status line은 그대로 실행되며 시그널만 뒤에 붙습니다. 제거하면 바이트 단위로
  원래 상태로 복원되고, Tally를 제거하지 않고 그냥 삭제해도 계속 동작합니다.
- **Claude Code 스킬.** 클릭 한 번으로 각 Claude 계정의 skills 폴더에 작은 스킬을 넣어,
  agent 세션이 `tally status --json`으로 쿼터 질문에 답하고 계정을 고르도록 가르칩니다
  (무거운 멀티 에이전트 작업 전에 병목이 되는 창을 확인하는 것까지). 제거도 똑같이
  깔끔하게 정리됩니다.
- **`tally` CLI.** `tally claude [인자…]`, `tally resume`(현재 디렉터리의 최신 대화를 다른
  계정으로 옮김), `tally claude --account <이름>`, `tally status`(`--json`을 붙이면 버전이
  명시된 기계 판독형 리포트를 출력: 모든 계정의 창과 리셋 시각, 그리고 지금 실행하면 어느
  계정에 배정되는지까지, 직접 만든 스크립트, 훅, agent skill에 바로 쓸 수 있음),
  `tally add <provider>`(계정 하나 더 로그인: 다음 빈 번호 선택과 설정 디렉터리 생성까지
  자동, 메인 계정의 CLAUDE.md/AGENTS.md, skills, hooks, agents, 설정, 대화 기록은 기본으로
  새 디렉터리에 심볼릭 링크로 연결되어 한 벌의 설정으로 모든 계정을 사용,
  `--no-share`로 옵트아웃),
  `tally best-dir <provider>`. 모두 스크립트 친화적입니다.

### 외관과 디테일

- **5개 언어.** English, 繁體中文, 简体中文, 日本語, 한국어. 앱 안에서 즉시 전환.
- **네이티브.** Swift 6 + SwiftUI + AppKit, Electron 없음. 유일한 서드파티 의존성은
  macOS 표준 업데이트 프레임워크인 [Sparkle](https://sparkle-project.org)이며, 앱과 CLI
  각각 단일 바이너리.

## 동작 방식 (그리고 절대 하지 않는 것)

- **자격 증명에 일절 접근하지 않음.** Tally는 토큰도, Keychain 비밀도, 벤더 엔드포인트도
  건드리지 않습니다. 사용량은 각 프로바이더의 **공식 CLI 자체**(`claude -p "/usage"`와
  `codex app-server`)를 통해 읽습니다. 공식 클라이언트가 자신의 퍼스트파티 신원과 스스로
  관리하는 자격 증명으로 벤더와 통신합니다. 계정 탐지는 「로그인이 존재하는가」의 속성
  수준 확인뿐이며, 내용을 읽어 내지 않습니다.
- **폴링은 언제나 하나.** CLI를 실행하는 것은 메뉴 막대 앱뿐입니다(기본 1분 간격, 2/5/15분으로
  완화 가능). `tally` 런처는 로컬 스냅숏(`~/.tally/snapshot.json`: 퍼센트와 경로만, 토큰은
  절대 없음)만 읽으므로 터미널을 열 개 열어도 추가 읽기는 없습니다.
- **오직 당신의 계정만.** 멀티 계정이란 *당신이* 결제하고 *당신의* 기기에 있는 구독을
  말합니다. Tally는 프록시도, 계정 풀 공유도, 재판매도 하지 않습니다. 계정 전환은 이미
  소유한 config 디렉터리로 공식 CLI를 실행하는 것뿐입니다.
- **완전 로컬.** 텔레메트리 없음, 서버 없음. 사용량 읽기 외에는 아무것도 기기 밖으로
  나가지 않습니다.

## 요구 사항

- macOS 14+
- 로그인된 [Claude Code](https://claude.com/claude-code). 추가 계정은 config 디렉터리를
  하나 더 만들면 됩니다(`CLAUDE_CONFIG_DIR=~/.claude2 claude`로 로그인). 그리고/또는
- 로그인된 Codex CLI (`~/.codex`)

## 설치

[Releases](https://github.com/jettoai/tally/releases/latest)에서 최신 공증 DMG를
다운로드하고 **Tally.app**을 응용 프로그램 폴더로 드래그한 뒤 실행하세요. 이후
업데이트는 앱 안에서 자동으로 도착합니다.

`tally` CLI를 쓰려면 앱에 번들된 바이너리를 PATH에 링크하세요:

```sh
ln -s /Applications/Tally.app/Contents/Helpers/tally /usr/local/bin/tally
```

<details>
<summary>소스에서 빌드하기</summary>

```sh
brew install xcodegen   # 최초 1회
git clone https://github.com/jettoai/tally && cd tally
xcodegen generate
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'platform=macOS'
xcodebuild build -project Tally.xcodeproj -scheme TallyCLI -configuration Release -destination 'platform=macOS'
```

`Tally.app`을 DerivedData에서 응용 프로그램 폴더로 옮기고 `tally` 바이너리를 PATH에
두세요:

```sh
ln -s <build-products>/tally /usr/local/bin/tally
```

</details>

심볼릭 링크와 별칭을 아예 건너뛸 수도 있습니다: **설정 → Integrations**에서 CLI 도구,
셸 shim(맨몸의 `claude` / `codex`도 정책을 따르게 함), status line 시그널을 각각
클릭 한 번으로 설치하고 깔끔하게 제거할 수 있습니다.

선택 사항인 셸 별칭:

```sh
alias c='tally claude'
alias cc='tally claude --continue'
```

## 현지화

Tally는 English, 繁體中文, 简体中文, 日本語, 한국어를 내장하며 설정에서 재시작 없이
즉시 전환됩니다. 모든 문자열은 하나의 Xcode String Catalog
([`Tally/Resources/Localizable.xcstrings`](Tally/Resources/Localizable.xcstrings))에
있어, 언어 추가는 「열 하나를 채우는」 단일 파일 PR입니다. 기준은 「번역이 아니라 OS의
네이티브 문구처럼 읽힐 것」. 기존 언어의 교정도 새 언어만큼 환영합니다.

## 기여하기

이슈와 풀 리퀘스트를 환영합니다. 빌드 환경은 위의 「소스에서 빌드하기」를 참고하세요.
프로젝트를 건강하게 유지하는 두 가지 관례가 있습니다:

- `project.yml`이 유일한 진실의 원천입니다. `Tally.xcodeproj`는 XcodeGen이 생성하며
  손으로 편집하지 않습니다.
- 사용자에게 보이는 새 문자열은 반드시 `L("…")` 헬퍼를 거쳐 String Catalog에 넣고,
  5개 언어를 모두 채웁니다.

PR은 하나의 의도로 좁히고, 「왜」를 설명에 적어 주세요.

## FAQ

**Tally는 ccusage나 다른 사용량 트래커와 무엇이 다른가요?**
[ccusage](https://github.com/ryoppippi/ccusage) 같은 도구는 로컬 로그에서 토큰 지출을
추정하는 터미널 CLI이고, 대부분의 메뉴 막대 미터는 단일 계정만 지원합니다. Tally는 벤더가
실제로 적용하는 쿼터 윈도우(5시간, 주간, 플래그십 모델)를 여러 Claude / Codex 계정에 걸쳐
동시에 보여주는 네이티브 GUI이며, 그 숫자에 따라 동작하는 런처도 제공합니다. 읽기 전용이며,
본인이 결제한 구독만 대상으로 합니다.

**왜 macOS가 키체인 권한을 묻지 않나요?**
Tally는 자격 증명을 읽지 않기 때문입니다. 사용량은 공식 CLI를 통해 가져오고, 계정
탐지는 속성 수준의 Keychain 확인뿐입니다(비밀을 꺼내지 않음 → 권한 대화 상자 없음).

**모든 계정이 한도에 도달하면?**
극적인 일은 없습니다. 대시보드는 그대로 보여 주고, `tally claude`는 경고 후 순정 CLI를
실행하며, 자동 핸드오프는 루프 없이 제자리에 머뭅니다.

**자동 핸드오프로 대화를 잃지 않나요?**
잃지 않습니다. 다음 계정에서 같은 세션 기록을 이어 갑니다(추가 기록만 하며 원본 기록은
절대 수정되지 않음). 중단된 도구 호출은 전환 후 한 번 다시 실행될 수 있습니다.

**status line 통합이 커스텀 status line을 망가뜨리지 않나요?**
아닙니다. 여러분의 명령어는 같은 session JSON을 받으며 이전과 똑같이 계속 실행됩니다.
Tally는 그 뒤에 시그널만 추가하며, 이미 계정 이름을 표시하고 있다면 그 부분은
생략합니다. 제거하면 바이트 단위로 원래 등록 상태로 복원되고, 혹시 tally 바이너리가
사라지더라도 여러분의 명령어를 직접 실행하는 방식으로 대체됩니다.

## 감사의 말

Tally는 이 분야를 먼저 개척한 훌륭한 프로젝트들의 길 위에 서 있습니다:

- [ccusage](https://github.com/ryoppippi/ccusage): Claude Code의 로컬 로그를 사용량
  인사이트로 바꾼 선구자로, 개발자들이 자신의 숫자를 얼마나 보고 싶어 하는지 보여주었습니다.
- [OpenUsage](https://github.com/robinebers/openusage)와
  [AIUsage](https://github.com/sylearn/AIUsage): 메뉴 막대에서 한눈에 보는 사용량 미터라는
  형식을 확립했습니다. Tally는 그 한눈을 여러 계정에 동시에 향하게 하고 싶어 태어났습니다.
- [Sparkle](https://sparkle-project.org): 앱 내 자동 업데이트를 담당합니다.

## 라이선스

[MIT](LICENSE) © [jetto](https://jetto.ai)
