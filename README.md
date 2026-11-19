# AGY Monitor

[English](#english) | [中文](#中文)

<table>
  <tr>
    <td align="center"><img src="docs/cost.png" width="250" alt="Cost tab"/><br/><sub><b>Cost</b> — Today / Week / Month API-equivalent spend, model split, daily chart</sub></td>
    <td align="center"><img src="docs/tokens.png" width="250" alt="Tokens tab"/><br/><sub><b>Tokens</b> — by type (in / out / cache) and by Antigravity model family</sub></td>
    <td align="center"><img src="docs/plan.png" width="250" alt="Plan tab"/><br/><sub><b>Plan</b> — rolling Gemini &amp; Claude quota left + Google One AI Credits</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/time-week.png" width="250" alt="Time — week view"/><br/><sub><b>Time · Week</b> — Apple-Health-style timeline, colored by model</sub></td>
    <td align="center"><img src="docs/time-month.png" width="250" alt="Time — month view"/><br/><sub><b>Time · Month</b> — one row per week of the month</sub></td>
    <td align="center"><img src="docs/time-year.png" width="250" alt="Time — year heatmap"/><br/><sub><b>Time · Year</b> — GitHub-style activity heatmap</sub></td>
  </tr>
  <tr>
    <td align="center" colspan="3"><img src="docs/session.png" width="360" alt="Session tab"/><br/><sub><b>Sessions</b> — live Antigravity sessions grouped by workspace, click to jump to terminal or IDE</sub></td>
  </tr>
</table>

<sub>Screenshots are rendered from the app's real SwiftUI views (<code>docs/render_mockups.swift</code>) with synthetic demo data — no real usage.</sub>

### ✳ Notch mode

<table>
  <tr>
    <td width="300"><img src="docs/notch.png" width="300" alt="Notch display mode"/></td>
    <td valign="middle">
      Prefer the MacBook notch to the menu bar? Switch the display into <b>notch mode</b> and your Antigravity telemetry lives in the display notch — hover to drop the full popover across all five tabs.
      <ul>
        <li><b>Idle pill</b> — Antigravity logo + your current value, hugging the notch</li>
        <li><b>Hover to expand</b> — the black notch grows seamlessly into the full popover</li>
        <li><b>Every display</b> — a synthetic notch appears on external monitors too</li>
        <li><b>Respects fullscreen</b> — hides for immersion; push the pointer against the top 8pt edge (the same gesture that summons the menu bar) and it slides back in cleanly</li>
      </ul>
      <sub><b>Enable:</b> click <b>⋯</b> in the popover footer → <b>Display location</b> → <b>Notch</b>.</sub>
    </td>
  </tr>
</table>

---

## English

macOS menu bar & notch app that tracks your **Google Antigravity** (`agy` CLI, Antigravity 2.0 Desktop, and Antigravity IDE) token usage, API-equivalent cost, active coding time, live sessions, and plan quota. Parses local transcripts and session metadata — zero tokens consumed, local session data stays on your Mac.

### Why this exists

Antigravity runs across multiple surfaces — the `agy` CLI in your terminal, Antigravity 2.0 Desktop, Antigravity IDE, and multi-agent Swarms spawning background worker conversations. Interactive `/usage` and `/credits` overlays only show current bucket percentages inside a single TUI session, with no cross-workspace token totals, historical trends, active-time heatmaps, or unified live-session switcher.

`AGYMonitor` aggregates every Antigravity surface on disk into one lightweight native macOS status item (or notch pill).

### What you get

- **Cost & Tokens** — switch seamlessly between API-equivalent spend and token volume, broken down by Antigravity model family (**Gemini Carbon**, **Gemini Argon**, **Gemini Neon**, **Gemini Hydrogen**, **Gemini Flash**, **Claude**, and **Other**)
- **Time** — *when* you actually worked with Antigravity, computed from 10-minute gap-merged step timestamps:
  - **Week** — an Apple-Health-style timeline (`Mon–Sun × 0–24h`), each active block colored by dominant model family
  - **Month** — one timeline row per week of the month
  - **Year** — a 53×7 Monday-first GitHub-style activity heatmap
- **Sessions** — live list of running Antigravity sessions grouped by workspace folder. Each row shows a priority status dot (**working** / **waiting for input** / **just finished, unseen** / **idle**), conversation title, and latest prompt. **Click any row to jump straight to its terminal pane/tab** (Otty, Apple Terminal, iTerm2, WezTerm, plus Ghostty/Kitty/Alacritty/Antigravity IDE app-activate). The **Antigravity icon spins smoothly while any session is working** — in the menu bar, the notch, and the popover header — and displays an amber/green attention dot until viewed
- **Plan & AI Credits** — dedicated tab showing how much quota is **left** across Antigravity's rolling ~5-hour model buckets (**Gemini Models** and **Claude & Partner**) with live reset countdowns, alongside your **Plan Tier** and **Google One AI Credits** (`Prompt`, `Flow`, `Flex`)
- **Today / This Week / This Month** — summary cards with token distribution by type (uncached input, output + thinking, cache read, cache write)
- **Daily stacked bar chart** — hover any day for exact per-day cost or token details
- **Month navigation & durable archive** — browse historical months; local daily archive (`~/Library/Application Support/AGYMonitor/`) preserves stats even if old transcripts are cleaned up
- **4 languages** — English, 简体中文, 繁體中文, 日本語
- **Auto-refresh & ⌘R** — FSEvents file watching updates shortly after real usage (coalesced and rate-limited), backed by a 30-minute timer and screen-wake observer. **⌘R** forces an immediate full scan and live quota refresh
- **Menu bar or Notch** — `LSUIElement=true` accessory app with no Dock icon

### Requirements

- macOS 13+ (Universal binary: Apple Silicon `arm64` & Intel `x86_64`)
- Python 3.9+ (bundled with macOS / Xcode Command Line Tools at `/usr/bin/python3`)
- Google Antigravity CLI (`agy`), Antigravity 2.0 Desktop, or Antigravity IDE (`~/.gemini/`)

### Install

#### Download DMG

Grab `AGYMonitor.dmg` from [Releases](../../releases) and drag `AGYMonitor.app` to `Applications`.

First launch: right-click → **Open** (bypasses Gatekeeper for ad-hoc / self-signed builds).

#### Build from source

```bash
git clone https://github.com/kuen54/AGYMonitor.git
cd AGYMonitor
bash setup_signing.sh   # optional, one-time — creates a stable local signing identity
bash build.sh
open build/AGYMonitor.app
```

> If `swiftc` reports `redefinition of module 'SwiftBridging'`, run `bash fix_swift.sh`.

> **`setup_signing.sh`** (optional, run once) creates a `"AGYMonitor Self-Signed"` certificate in your login keychain so rebuilds keep a constant Designated Requirement. Without it, `build.sh` automatically falls back to ad-hoc signing (`-`).

#### Development notes

- **Swift Core unit tests** — `swift test` runs the `AGYCoreTests` suite (Swift Testing `import Testing`, requiring Xcode 16+ / Swift 6) against the pure Foundation-only `Sources/Core_*.swift` layer. `Package.swift` is a test harness only; the app itself compiles directly via `swiftc` in `build.sh`.
- **Python scanner tests** — `/usr/bin/python3 -m unittest discover -s Tests -p "test_*.py"` verifies `Resources/analyze_usage.py` under macOS system Python 3.9+.
- **Mockup screenshots** — `docs/render_mockups.swift` compiles against the real SwiftUI views in `Sources/` (excluding `main.swift`) to render `docs/*.png` via `ImageRenderer`.

### How it works

#### 1. Local Usage & Active Time (`Resources/analyze_usage.py`)

`AGYMonitor` invokes the bundled Python 3.9-compatible scanner across all three Antigravity data roots:

```
~/.gemini/antigravity-cli/brain/<conv-id>/.system_generated/logs/transcript.jsonl
~/.gemini/antigravity/brain/<conv-id>/.system_generated/logs/transcript.jsonl
~/.gemini/antigravity-ide/brain/<conv-id>/.system_generated/logs/transcript.jsonl
    → analyze_usage.py --json
    → Incremental per-file cache (~/Library/Caches/AGYMonitor/)
    → SwiftUI Popover / Notch
```

- Counts `PLANNER_RESPONSE` steps deduplicated by `(conversation_id, step_index)`, including swarm coordinator and worker trajectories (`brain/*`) while skipping `.system_generated/logs/chunks/` to never double-count.
- Respects Antigravity's exact token semantics: `input_tokens` is **uncached new input only**, `cache_read_tokens` is cached prompt input, and `output_tokens` combines thinking + response tokens (`total = input + output + cache_read + cache_write`). Supplements `cache_write` from `conversations/<conv-id>.db` (`gen_metadata`) when present.

#### 2. Live Sessions & Click-to-Jump (`SessionMonitor` & `SessionJumper`)

- Combines `~/.gemini/antigravity-cli/presence/*.lock` open-FD process detection, `~/.gemini/antigravity-cli/conversation_summaries.db` (with immutable-read WAL fallback) / `cache/conversation_metadata.json`, and tail-read `transcript.jsonl` step states to track live `agy` and IDE sessions in real time.
- Resolves each process's controlling TTY and parent GUI app to jump directly to the exact pane/tab in Otty (`otty-cli`), Apple Terminal, iTerm2, or WezTerm, or bring Ghostty / Kitty / Alacritty / Antigravity IDE forward.

#### 3. Plan Quota & AI Credits (`QuotaService`)

- Queries Cloud Code PA quota endpoints when live credentials are available and falls back cleanly to cached `antigravityUnifiedStateSync.userStatus` & `modelCredits` in `~/Library/Application Support/{Antigravity,Antigravity IDE}/User/globalStorage/state.vscdb` plus `~/.gemini/antigravity-cli/log/cli-*.log` account metadata.

### Project structure

No `.xcodeproj` — compiled directly with `swiftc` into a universal macOS binary. `Package.swift` exists strictly for `swift test`.

```
Sources/
  main.swift                  ← single-instance guard + NSApp .accessory bootstrap
  AppDelegate.swift           ← menu bar status item, NSPopover, timers, FSEvents watcher
  UsageStore.swift            ← @Published usage/time/quota state + archive & scan orchestration
  UsageArchive.swift          ← durable monthly archive in ~/Library/Application Support/AGYMonitor/
  UsageScriptClient.swift     ← off-main Python scanner runner with timeout escalation
  ProcessRunner.swift         ← bounded subprocess helper
  QuotaService.swift          ← Antigravity quota buckets, AI Credits & state.vscdb reader
  SessionStore.swift          ← isolated @Published live-session state + jump feedback
  SessionMonitor.swift        ← presence/*.lock + conversation_summaries.db + FSEvents liveness
  SessionJumper.swift         ← click-to-jump across Otty, Terminal, iTerm2, WezTerm & IDEs
  AITitleReader.swift         ← bounded tail reader for session titles & latest prompts
  AGYLogo.swift               ← official Antigravity cubic-bezier vector mark (UI + icon generator)
  Theme.swift                 ← Antigravity cosmic indigo brand accent & status palette
  Formatters.swift            ← currency, token (k/m/b), and relative time formatters
  Localization.swift          ← 4-language i18n dictionary (en, zh-Hans, zh-Hant, ja)
  Models.swift                ← app-layer quota, DisplayTab, TimeRange & DisplayMode models
  NotchFullscreen.swift       ← runtime SkyLight fullscreen space & detector wrappers
  NotchController.swift       ← per-display NotchPanel geometry, hover dwell & fullscreen edge gate
  NotchView.swift             ← NotchShape + compact pill ↔ expanded popover transition
  Views*.swift                ← SwiftUI popover, cards, charts, Time, Sessions, Plan & menus
  Core_*.swift                ← pure Foundation-only core (models, ModelClass, usage/date/time
                                 math, monotonic archive, session & transcript parsers, AGYQuotaParser)
Tests/
  AGYCoreTests/               ← Swift Testing unit test suites covering Core_*.swift
  test_analyze_usage.py       ← Python unit tests for the local usage scanner
Resources/analyze_usage.py    ← bundled Python 3.9+ Antigravity usage & active-time scanner
docs/render_mockups.swift     ← SwiftUI ImageRenderer generator for docs/*.png screenshots
generate_icon.swift           ← ASCII-art macOS squircle icon generator
build.sh                      ← universal swiftc build + icon + codesign + DMG packager
setup_signing.sh              ← optional one-time self-signed certificate setup
fix_swift.sh                  ← Command Line Tools SwiftBridging modulemap workaround
.github/workflows/build.yml   ← CI: plist lint → py_compile & unittest → swift test → DMG build
Info.plist                    ← LSUIElement=true; single source of app version (1.0.4)
```

### On pricing accuracy

Google Antigravity plans combine rolling model quotas and Google One AI Credits rather than raw per-token invoices. `AGYMonitor` computes **API-equivalent cost estimates** using [LiteLLM](https://github.com/BerriAI/litellm) public rates (cached 24h) combined with Google's official standard (non-promotional) API list-rate floor for Antigravity model families (`Gemini Carbon`, `Argon`, `Neon`, `Hydrogen`, `3.8 Flash`, `Claude Opus/Sonnet`, `GPT-OSS`) so you can compare workload intensity across projects and days.

### Durable historical archive

`AGYMonitor` keeps a compact monotonic daily archive in `~/Library/Application Support/AGYMonitor/archive/YYYY-MM.json` (**enabled by default**). Even if you prune old transcripts under `~/.gemini/`, historical daily cost, token, and active-time totals remain intact. Toggle or clear the archive anytime from the footer **⋯** menu.

### Acknowledgments

Architecture, Notch interaction model, and UI polish inspired by [CCCostMonitor](https://github.com/kuen54/CCCostMonitor).

---

## 中文

macOS 菜单栏与刘海（Notch）原生监控应用，一站式查看 **Google Antigravity**（`agy` CLI、Antigravity 2.0 桌面端、Antigravity IDE）的 Token 用量、API 等效花费、活跃编码时长、实时会话与套餐配额。直接解析本地会话记录与状态库 —— **零额外 Token 消耗**，本地会话数据完全留在你的 Mac 上。

### 为什么做这个

Antigravity 同时运行在多个入口：终端里的 `agy` CLI、Antigravity 2.0 桌面应用、Antigravity IDE，以及多智能体 Swarm 派生的后台 worker 会话。内置的 `/usage` 和 `/credits` 仅能在单个交互式终端内查看当前配额百分比，无法跨工作区汇总 Token 与等效开销、回顾每日/每月趋势、查看活跃时间热力图或一键跳转到正在等待输入的终端窗口。

`AGYMonitor` 将本机所有 Antigravity 数据源汇总到一个轻量的菜单栏图标（或屏幕刘海悬浮条）中。

### 功能亮点

- **费用 & Tokens 双视图** — 按 Antigravity 模型家族精细拆分（**Gemini Carbon**、**Gemini Argon**、**Gemini Neon**、**Gemini Hydrogen**、**Gemini Flash**、**Claude** 与 **Other**）
- **活跃时长（Time）** — 基于 10 分钟间隔合并算法还原你**何时**在使用 Antigravity：
  - **周视图** — Apple 健康睡眠风格的 `周一~周日 × 0–24h` 时间轴，按各时段主力模型着色
  - **月视图** — 按周分行展示整月时间轴
  - **年视图** — 53×7 GitHub 风格年度活跃热力图
- **实时会话（Sessions）** — 按工作区文件夹分组展示正在运行的 Antigravity 会话，实时显示状态圆点（**运行中** / **等待输入** / **刚完成未读** / **空闲**）、会话标题与最新指令。**点击任意会话即可直接跳转到对应终端分屏/标签页**（支持 Otty、系统 Terminal、iTerm2、WezTerm 精确定位，以及 Ghostty / Kitty / Alacritty / Antigravity IDE 前台唤起）。当任一会话正在工作时，**Antigravity 图标会平滑旋转**，并在需要确认或刚完成时亮起琥珀色/绿色提醒点
- **套餐配额 & AI Credits（Plan）** — 独立标签页展示 Antigravity ~5 小时滚动模型配额池（**Gemini Models**、**Claude & Partner**）的**剩余百分比**与重置倒计时，同时展示当前订阅等级与 **Google One AI Credits**（`Prompt`、`Flow`、`Flex` 积分）
- **今日 / 本周 / 本月卡片 & 每日堆叠柱状图** — 按未缓存输入、输出（含思考 Token）、缓存命中、缓存写入清晰拆分，支持按日悬浮查看明细
- **月份导航 & 本地持久归档** — 自由翻阅历史月份；每日汇总自动归档至 `~/Library/Application Support/AGYMonitor/`（默认开启），清理旧日志后历史统计依然完整保留
- **4 种语言** — English、简体中文、繁體中文、日本語
- **智能自动刷新 & ⌘R** — FSEvents 监听本地目录变化并合并限频刷新，配合 30 分钟定时兜底与唤醒刷新；按 **⌘R** 立即强制全量扫描并拉取最新配额
- **纯粹菜单栏 / 刘海体验** — 无 Dock 图标；可在底部 **⋯** → **显示位置** → **刘海** 开启全屏友好的刘海模式（外接显示器亦支持合成刘海）

### 系统要求

- macOS 13+（Apple Silicon `arm64` 与 Intel `x86_64` 通用二进制）
- Python 3.9+（macOS / Xcode Command Line Tools 自带 `/usr/bin/python3`）
- 已安装 Google Antigravity CLI（`agy`）、Desktop 或 IDE（数据位于 `~/.gemini/`）

### 安装方式

#### 下载 DMG

从 [Releases](../../releases) 下载 `AGYMonitor.dmg`，将 `AGYMonitor.app` 拖入 `Applications`。

首次打开请右键点击应用 → 选择**打开**（绕过未公证应用的 Gatekeeper 提示）。

#### 从源码构建

```bash
git clone https://github.com/kuen54/AGYMonitor.git
cd AGYMonitor
bash setup_signing.sh   # 可选，仅首次运行 — 生成本地稳定自签名证书
bash build.sh
open build/AGYMonitor.app
```

> 若 `swiftc` 提示 `redefinition of module 'SwiftBridging'`，请运行 `bash fix_swift.sh`。

### 工作原理

1. **本地 Token 与时长扫描（`Resources/analyze_usage.py`）**：扫描 `~/.gemini/{antigravity-cli,antigravity,antigravity-ide}/brain/*/.system_generated/logs/transcript.jsonl` 中的 `PLANNER_RESPONSE` 步骤（包含 Swarm 子智能体会话，自动跳过 `chunks/` 防止重复计数），按 `(conversation_id, step_index)` 去重，并通过增量文件指纹缓存（`~/Library/Caches/AGYMonitor/`）实现毫秒级热启动扫描。严格遵循 Antigravity 的计费字段语义：`input_tokens` 仅为未缓存的新增输入，总 Token = `input_tokens + output_tokens + cache_read_tokens + cache_write`。
2. **实时会话检测与终端跳转（`SessionMonitor` & `SessionJumper`）**：结合 `~/.gemini/antigravity-cli/presence/*.lock` 进程文件锁、`conversation_summaries.db`（支持只读 WAL immutable 回退）与 `transcript.jsonl` 尾部状态，实时追踪会话忙闲并在点击时精准聚焦对应终端窗格。
3. **套餐配额与积分（`QuotaService`）**：支持通过 Cloud Code PA 接口获取实时配额，并在离线或桌面端缓存场景下无缝回退读取 `state.vscdb`（`antigravityUnifiedStateSync.userStatus` / `modelCredits`）与 CLI 日志账户信息。

### 关于费用估算

Google Antigravity 采用滚动模型配额池与 Google One AI Credits 机制计费。`AGYMonitor` 结合 [LiteLLM](https://github.com/BerriAI/litellm) 公开价格表（本地缓存 24 小时）与 Antigravity 模型家族等效费率表计算 **API 等效花费**，便于直观衡量不同项目与日期的模型算力消耗。

### 致谢

架构设计、刘海交互体验与界面打磨参考自 [CCCostMonitor](https://github.com/kuen54/CCCostMonitor)。

---

## License

[Apache 2.0](LICENSE)
