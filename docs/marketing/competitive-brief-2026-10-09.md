# Drakar: competitive brief

- **Research date:** 2026-10-09
- **Refreshed in [competitive-brief-2026-10-21.md](competitive-brief-2026-10-21.md),** which settles several items marked *unverified* here (the Codex app's Claude Code import is now confirmed by OpenAI; Conductor is Tauri; Cursor's acquisition by SpaceX is confirmed) and corrects one: `codex app-server` is not labelled experimental as a whole, only features behind `experimentalApi` are.
- **Scope:** native and desktop front ends for Claude Code and Codex (first-party and third-party), editors with agent panels, parallel-agent orchestrators, and, for the Skills window, skill managers and skill marketplaces. This is desk research: "they have" means "they say they have". Nothing was used hands-on.
- **Baseline (what Drakar is today):** pre-launch. `MARKETING_VERSION` 1.0.0, no tag, no release, no website (`apps/website` and `apps/api` do not exist yet), Sparkle not vendored (only placeholder keys in `Info.plist`), no licence code in the app, price and trial undecided (PLAN.md §7.5). Distribution will be Developer ID plus Sparkle, never the Mac App Store. 295 commits since the repo was created on 2026-10-03. Built and on `main`: Claude Code over stream-json, permission sheets with "always allow" suggestions, diffs, project windows with sessions from every account (`~/.claude`, `~/.claude-*`), the IDE bridge for a terminal `claude --ide`, a plain-text editor, plans/todos/subagents, attachments, mode and model pills, the skills and MCP inspector. **Codex is no longer "soon"**: live Codex sessions over `codex app-server` merged on 2026-10-08, and Codex skills the same day. **The Skills window** (spec `docs/superpowers/specs/2026-10-09-skills-manager-design.md`) merged to `main` as `70ee531` on 2026-10-09 and is not pushed; the `drakar-skills-manager` worktree named in the brief request no longer exists, so this brief read the spec, the plan and the merged commits on `main` instead.
- **First brief for this app.** There is no earlier competitive brief and no market-intel ledger for Drakar, so there are no standing decisions to respect beyond PLAN.md's own (stream-json not ACP, no webview, out of the Mac App Store, your installed `claude`).
- **No SEO or traffic tools are connected** (Ahrefs and Similarweb are not authorized). This brief gives no traffic, keyword volume or ranking numbers. GitHub stars, VS Code Marketplace installs and GitHub issue reactions are the only quantitative signals, and they are labelled as such.
- **Search budget:** the session's web-search allowance ran out near the end of research. Items marked *unverified* could not be checked against a primary source.

**Evidence grades:** (P) primary: vendor page, docs, changelog, store or marketplace listing, GitHub repo or issue. (T) trade press. (S) secondary: aggregator, directory, third-party blog. *unverified*: could not be confirmed.

---

## 1. Executive summary

Drakar enters a crowded market, and the default is Anthropic's own: the Claude desktop app's Code tab now has parallel sessions, worktrees, a terminal, a file editor, diff review, a plugin browser and SSH, and is included in every Claude subscription. Most third-party rivals (Conductor, Nimbalyst, the Codex app, Cursor) are racing toward *parallel orchestration of many agents*. Few products aim at the corner Drakar was built for: steering one project's sessions closely, in a native window, with **your installed `claude` and `codex`, your accounts and your config left exactly as they are**. Only two small open-source SwiftUI clients (Clarc, RxCode) sit there, and neither has Drakar's IDE bridge or multi-account session list.

- **Biggest opportunity:** "Your Claude Code, not ours." Claude Desktop runs *its own copy* of Claude Code, keeps its own session list and has no account switching. The open request for multiple accounts in Claude Desktop has 1,066 reactions (P, issue #18435, open 2026-10-09). Drakar already reads every account and resumes sessions from any surface. Add the Skills window, which fixes in a GUI the gap behind the open "Support `.agents/skills/`" request (546 reactions, P, issue #31005): Claude Code still does not read `~/.agents/skills`, so sharing skills with Codex means symlinks by hand.
- **Biggest threat:** Anthropic closing those gaps itself, combined with protocol drift. Claude Code shipped eight versions between 2 and 8 October (2.1.288 to 2.1.295, P), while Drakar's tested range is 2.1.284 to 2.1.288 (`ClaudeVersion.tested`). Codex CLI is at 0.162.0 (P, 2026-10-08) against Drakar's 0.160.1 captures. A free first-party app that adds account switching would remove Drakar's clearest wedge, and every undocumented protocol change is maintenance Drakar pays for and Anthropic does not.

## 2. Competitor profiles

### 2.1 Claude desktop app, Code tab (Anthropic): the first-party default

- **Overview.** The Claude desktop app has three tabs: Chat, Cowork and Code. The Code tab is "Claude Code with a graphical interface built for running multiple sessions side by side" (P, code.claude.com/docs/en/desktop). macOS universal, Windows x64 and ARM64, Linux beta via apt (P). Requires a Claude subscription or API sign-in. Built on Electron (S: the stale, closed feature request #69046 "Native macOS App (SwiftUI): replace Electron wrapper", 5 reactions; Clarc's README contrasts itself with it). A redesign shipped on 2026-04-14 (S).
- **Messaging.** "Get more out of Claude Code Desktop: parallel sessions with Git isolation, drag-and-drop pane layout, integrated terminal and file editor, side chats, computer use, Dispatch sessions from your phone, visual diff review, app previews, PR monitoring, connectors, and enterprise configuration" (P). Themes: parallelism, everything in one window, work from anywhere (cloud, SSH, phone), enterprise control. Tone: documentation, feature-dense. Problem framing: "manage parallel sessions in one window, arrange panes side by side, or review changes visually" (P, its own "Desktop vs CLI" tip).
- **Product.** Sessions with optional worktrees (`.claude/worktrees/`), split view, panes for chat, diff, browser, terminal, file, plan, tasks, subagents and the iOS Simulator; permission modes including Auto; side chats; PR monitoring via `gh`; scheduled tasks; Remote Control; computer use (research preview, Pro and Max only); a **Customize** panel for connectors, skills and plugins; a plugin browser with Manage plugins (enable, disable, uninstall) scoped to user, project or local (all P).
- **Key structural facts for Drakar** (all P, same page): "the Code tab runs its own copy of Claude Code, which has its own version number. The desktop app downloads and updates that copy, so it can differ from the `claude` command in your terminal." CLI and Desktop "each keep[s] its own session list"; a CLI session moves in with `/desktop`, `claude --desktop --resume <id>` (2.1.285 or later) or `/resume`. Customize "syncs through your claude.ai account, not from the CLI's `~/.claude` directory." Cross-session awareness does not see "sessions you started from the terminal CLI or the VS Code extension".
- **Content.** Extensive docs at code.claude.com, a weekly-plus changelog, claude.com product pages. Huge distribution through the Claude apps themselves.
- **Strengths.** Free with the subscription, ships constantly, owns the model and the protocol, broadest feature set, enterprise controls.
- **Weaknesses.** A separate bundled Claude Code and a separate session list; no switching between Claude accounts (P, issue #18435, 1,066 reactions, 202 comments, open, updated 2026-10-05); no terminal `claude` acting through it as an editor; web stack weight; Customize is account-synced rather than your `~/.claude`.

### 2.2 Claude Code for VS Code (Anthropic): the incumbent GUI

- **Overview.** Version 2.1.295, **27,419,947 installs**, about 3.5 stars from 822 ratings (P, VS Code Marketplace, 2026-10-09). Launched in beta 2025-09-29 (S). Bundles its own `claude`.
- **Messaging.** "Claude Code for VS Code": Claude in your IDE, aware of the current file and selection, proposing changes in the editor; subagents, slash commands and MCP, "some of these can only be configured through the command-line interface" (P).
- **Product.** Sidebar chat with real-time diffs, permission prompts, plan mode, checkpoints, background tasks (2.1.287), file chips (2.1.295) (P, changelog). Drakar's PLAN.md takes this extension's layout as its design reference and drives `claude` with the same stream-json arguments.
- **Content.** Ships inside the Claude Code release train; no separate marketing.
- **Strengths.** Default for anyone who already lives in VS Code; full protocol fidelity; free.
- **Weaknesses.** Requires VS Code (Electron plus webview); a middling rating for the volume; configuration often falls back to the CLI (P). Drakar's PLAN.md wedge, "people who live in Claude Code open VS Code to get its UI, not to edit", still targets exactly this.

### 2.3 Codex app, now inside the ChatGPT desktop app (OpenAI)

- **Overview.** The Codex Mac app launched in early 2026 (S, AlternativeTo, Feb 2026). On 2026-07-09, "Codex joins the ChatGPT desktop app" (S, gradually.ai changelog mirror); OpenAI's own app page is now titled "ChatGPT desktop app" (P, learn.chatgpt.com/docs/app). macOS, Windows, Linux preview (S, 2026-08-11). Codex CLI 0.162.0 on 2026-10-08 added managed worktree tools and pinned tasks (P, learn.chatgpt.com changelog).
- **Messaging.** "Run projects in parallel, work with files, use your computer, and keep long-running work moving from one desktop workspace" (P). Themes: parallel threads, automations, computer use, one workspace for everything.
- **Product.** Parallel threads with worktrees, automations, plugins (management moved into Settings, 2026-07-09, S), PR Chat, inline editing, computer use, Apple Messages plugin. **On 2026-08-11 the app added importing "setup, settings, skills, plugins, projects, and recent work from Claude Code, Claude Cowork, and Cursor, with automatic sync"** (S, gradually.ai mirror; *unverified* against OpenAI's primary changelog).
- **Strengths.** Free with ChatGPT plans, OpenAI distribution, actively courting Claude Code users (the import).
- **Weaknesses.** It drives Codex only, not Claude Code; it is becoming a general ChatGPT super-app rather than a coding tool; web stack (*unverified*).

### 2.4 Zed agent panel and ACP (Zed Industries)

- **Overview.** Native (GPUI, Rust) editor; 1.0 on 2026-04-29 (S); stable 1.23.2 on 2026-10-07 (P, zed.dev/releases). Claude Code ("Claude Agent") and Codex install from the ACP Registry as External Agents (P, zed.dev/docs/ai/external-agents).
- **Messaging.** Zed's own positioning is the fast native editor with agents built in. For external agents its docs are candid: "Claude Agent owns its own authentication and billing"; native skills and tool permissions "depend on the agent" (P).
- **Product.** Agent Panel, threads sidebar, parallel agents (2026-04-22, S), subagents with per-subagent models (1.22.0, P), ACP plan updates (1.23.2, P). **A Skills Manager** (AI > Skills; view, open, copy a `zed://skill` share link, delete) that reads only `~/.agents/skills/` and `<worktree>/.agents/skills/`, and **"Zed Skills apply to the Zed Agent"**, not to External Agents (P, zed.dev/docs/ai/skills).
- **Strengths.** The speed benchmark Drakar names itself after ("as light as Zed"); multi-agent via one protocol; open source; weekly releases.
- **Weaknesses.** Claude Code arrives through ACP's common denominator: early reports said plan mode and some slash commands were missing over ACP (S, ithome.com.tw, 2026; *unverified* whether still true). You must want the editor.

### 2.5 Conductor (Melty Labs)

- **Overview.** Mac-only; v0.90.0 on 2026-10-02 brought Conductor to iOS (P, changelog). Recent: ChatGPT sign-in (0.89.0, 2026-09-29), OpenCode 2.0 and file-wide search (0.87.0), shareable "loadouts" (0.86.0, 2026-09-16; *unverified* what a loadout contains).
- **Messaging.** "Run parallel coding agents on your Mac." "Create parallel Claude Code, Codex, and Cursor agents in isolated workspaces," see what each is doing, review and merge (P, conductor.build).
- **Pricing (P, conductor.build/pricing).** Free: parallel local agents, bring your own subscriptions and keys. Pro $50/month: Conductor Cloud, multiplayer up to 5, API, mobile app. Teams $60/user/month. Enterprise custom.
- **Strengths.** Clear single idea, free locally, fast cadence, now on iOS.
- **Weaknesses.** Orchestration-first: the single conversation, permission prompts and skills are not what it sells; the homepage says nothing about them (P). Tech stack *unverified* (not described as native).

### 2.6 Nimbalyst (Stravu), successor to Crystal

- **Overview.** Crystal (3.1k stars, MIT) was deprecated with its last release 0.3.5 on 2026-02-26 and points to Nimbalyst (P, GitHub). Nimbalyst: MIT, 1,856 stars, releases almost daily (v0.80.6 on 2026-10-09) (P, GitHub). macOS, Windows, Linux, plus iOS and Android companions (P).
- **Messaging.** "The visual workspace for Codex and Claude Code"; "multiplayer for Claude Code and Codex" (P, nimbalyst.com). Themes: visual editors (Markdown, mockups, Excalidraw, Mermaid, data models), kanban of parallel sessions in worktrees, shared task tracking, an extension marketplace.
- **Pricing.** Free for individuals with no limits; Teams free during beta (P).
- **Strengths.** Very broad, very active, open source, cross-platform, mobile approvals.
- **Weaknesses.** Breadth over depth; TypeScript desktop stack (P: repo language), so not a native-weight competitor; the Codex-over-ACP and OpenCode paths are alpha (P).

### 2.7 opcode (formerly Claudia), winfunc

- **Overview.** Tauri 2 (Rust plus React), AGPL-3.0, **22,415 stars**, but the last release is v0.2.0 from 2025-08-31; last push 2026-09-18 (P, GitHub). "The Elegant Desktop Companion for Claude Code" (P, opcode.sh title).
- **Product.** Project and session browser, custom agents, usage analytics, MCP server management, checkpoints (S).
- **Assessment.** A large audience that starred it and a product that has not shipped in thirteen months. Its stars show demand for a Claude Code GUI, not a live rival. Keep short.

### 2.8 Cursor (Anysphere)

- **Overview.** Cursor 3 introduced an Agents Window for parallel cloud agents (S). Recent primary changelog: remote control of local agents from iOS (2026-10-06), Rollouts and Security Review (2026-09-23), Cursor Projects beta with a coordinator agent (2026-09-10), self-hosted machines (2026-09-02) (P, cursor.com/changelog). Reports of an acquisition by SpaceX on 2026-08-14 (S; *unverified*; the pricing page does mention "Grok Bot", P).
- **Pricing (P).** Individual $20/month with "MCPs, skills, and hooks"; Teams $40/user/month with "a team marketplace for internal rules, skills, and plugins".
- **Relevance.** Cursor is the editor-centric incumbent and runs its own agent, not your `claude`. Its team skills marketplace is a signal that skills distribution is becoming a paid team feature. Not a direct rival for someone who wants Claude Code without an editor.

### 2.9 Warp

- **Overview.** Warp has repositioned away from the terminal: its homepage headline is now "Open infrastructure for cloud software factories", with `factory.yaml`, agents, skills and approval gates defined as code, and Claude Code, Codex and Cursor usable as harnesses (P, warp.dev, 2026-10-09). Priced per agent run, closed early access with up to $10k free usage for qualified teams (P).
- **Relevance.** Moved out of Drakar's lane (cloud, team, SDLC automation). Keep under watch only.

### 2.10 Native third-party clients (the closest look-alikes)

- **Clarc** (ttnear): "Native macOS client for Claude Code", SwiftUI, 368 stars, v1.4.1 on 2026-08-20, quiet since (P, GitHub). Pitch: "The terminal was for the few. Clarc is for everyone", built for non-developer coworkers. It "spawns the real `claude` CLI underneath, so your `CLAUDE.md`, skills, MCP servers, and slash commands keep working as-is" (P). Features: approval modals with diffs, per-project windows, forking, model, mode and effort per session, rate-limit status line, embedded SwiftTerm terminal, GitHub OAuth and SSH key setup, a "Skill Marketplace" browsing official Anthropic plugins, six languages (P, README). Free; licence badge says Apache 2.0 (GitHub reports none). **This is the nearest pitch to Drakar's**, aimed at a less technical buyer.
- **RxCode** (rxtech-lab): "A native macOS command center for AI coding agents": Claude Code, Codex and any ACP client in one SwiftUI workspace, worktrees, run profiles, semantic search over history, Foundation Model summaries, encrypted mobile sync; macOS 26+; v1.20.2 on 2026-10-04; only 6 stars (P, GitHub). Feature-for-feature the closest to Drakar's two-agent direction, with almost no audience yet.
- **Others, new since June 2026** (P, GitHub search): Kooky (an agent-oriented terminal on libghostty, 654 stars), vigil (multi-agent terminal orchestrator), detach (background Codex and Claude runs on tmux), flight-mac (parallel agents across worktrees), MacCL. Session monitors and limit trackers (syrtis, modeldeck, Lunavect, notchling and many more) belong to Armada's landscape, not Drakar's.

### 2.11 Skill managers and marketplaces (the Skills window's competition)

| Product | Kind | Agents | Model | Signal (P unless noted) |
| --- | --- | --- | --- | --- |
| Claude Code `/skills`, `/plugin` | Built-in TUI | Claude only | Free | `/skills` lists and hides (writes `skillOverrides`); delete "the skill's directory" by hand; plugins via `/plugin`; claude.ai skills sync into `~/.claude/skills/synced/` |
| Claude Desktop Customize | Built-in GUI | Claude only | Free with plan | Connectors, skills, plugins; synced through claude.ai, not `~/.claude` |
| Codex app import | Built-in | Codex | Free with plan | Imports skills and plugins from Claude Code "with automatic sync", 2026-08-11 (S, *unverified*) |
| Zed Skills Manager | Built-in GUI | Zed Agent only | Free | Reads `~/.agents/skills` only; open, share link, delete |
| Vercel `skills` CLI and skills.sh | CLI plus directory | 40+ via paths | Free, MIT | 33,551 stars; v1.7.2 on 2026-10-09; leaderboard by install telemetry |
| Skills Manager (xingkongliang) | Desktop app (Rust) | 50+ tools | Free, MIT | 5,829 stars; v1.40.3 on 2026-10-01; marketplace, global, agent and project workspaces |
| Skills Manager (jiweiyeah) | Tauri app plus `skm` | 32 tools | Free, MIT | 1,015 stars; v2.2.0 on 2026-08-25; central library linked by symlink |
| Skills Manager (yibie) | Native Swift app plus TUI | Claude, Codex, Cursor, Gemini and more | Free, MIT | 453 stars; v2.0.0 on 2026-08-04; Library, Collection, Mount; conflict and divergence states |
| SkillsManager (tddworks) | Native Swift app | Claude, Codex | Free | 170 stars; v0.1.4 on 2026-05-28; GitHub catalogs, tags, editor |
| kasetto, skills-supply, skman | Declarative CLIs | Many | Free | 208 and 35 stars; manifest files (`agents.toml`) |
| Clarc "Skill Marketplace" | In a Claude client | Claude | Free | Browses official Anthropic plugins |

What the market says: skill management is already a **free, open-source, crowded category**, with at least four GUI apps and a 33k-star CLI. Multi-agent symlinking (one real folder, a link per agent) is the consensus pattern, documented in many guides (S: kanaries, SSW, MindStudio, pjh.is, agensi, aq.dev). Demand is real: Claude Code still does not read `.agents/skills` (P, issue #31005, 546 reactions, open, labelled duplicate, updated 2026-10-05; the skills docs list no `.agents` path).

Where Drakar's Skills window is different, from the spec and the merged code:

1. **It asks the agents, not just the disk.** Codex's rows come from `skills/list` with scope, plugin, enabled and shadowed state; Claude's scan is cross-checked against the names Claude itself reports, so a skill on disk that Claude does not load reads "Not loaded by Claude Code". The file-system managers above infer from paths; none say they check what each agent actually loaded (P, their READMEs).
2. **One row per real folder**, resolved through links, with which agent sees it where. Delete never leaves a dangling link and never trashes a folder it does not own.
3. **Per project and per Claude account** (`CLAUDE_CONFIG_DIR`), in the same app where the skill then runs from the inspector or the `/` menu.
4. **Git installs into managed clones** (`~/.agents/skill-sources/...`) with Update, and refuses risky URL forms.

Where it is behind: no discovery or marketplace (skills.sh, the official plugin marketplace); plugins are read-only until part 2; Codex skills cannot be enabled or disabled; only two agents; and **claude.ai synced skills** (`~/.claude/skills/synced/<name>`) are one level below where the scanner looks, and nothing in the sources mentions `synced`, so they will likely appear with origin "Unknown" (repo grep; *unverified* in the running app).

## 3. Messaging comparison matrix

| | **Drakar** (pre-launch) | Claude Desktop, Code tab | Claude Code for VS Code | Codex in ChatGPT app | Zed | Conductor | Nimbalyst | Clarc |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Tagline | None public yet. PLAN.md: "the agent is the primary object, not a panel in something else" | "Get more out of Claude Code Desktop" (docs) | "Claude Code for VS Code" | "Run projects in parallel ... from one desktop workspace" | Fast native editor; agents built in | "Run parallel coding agents on your Mac" | "The visual workspace for Codex and Claude Code" | "The terminal was for the few. Clarc is for everyone." |
| Target buyer | Developers who live in Claude Code (and now Codex) and do not want an IDE to get its UI | Every Claude subscriber | VS Code users | ChatGPT subscribers | Editor-first developers | Developers running many agents | Teams and visual thinkers | Non-developers using Claude Code |
| Key differentiator | Your installed `claude` and `codex`, every account, native, IDE bridge for terminal `claude` | First-party, everything in one app | Inside the editor | OpenAI models, computer use, imports | Native speed, ACP | Parallel worktrees, simple | Visual editors, kanban, mobile | No terminal needed |
| Tone | Plain, exact, checkable (network claim) | Feature reference | Functional | Consumer-productive | Craft, performance | Terse, confident | Enthusiastic, broad | Friendly, inclusive |
| Core value prop | The extension's UI without the editor, as fast as the terminal, nothing changed in your setup | Parallel sessions and visual review | Claude where you already code | One workspace for all work | Agents in a fast editor | Many agents, review and merge | See and shape agent work visually | Same engine, no terminal |
| Price | Undecided (fleet precedent: one-time licence, Armada $14.99) | Included in Claude plans | Free (needs Claude plan or API) | Included in ChatGPT plans | Free editor, paid AI plans | Free locally; Pro $50/mo | Free for individuals | Free |
| Platforms | macOS only | macOS, Windows, Linux beta | Wherever VS Code runs | macOS, Windows, Linux preview | macOS, Linux, Windows | macOS, iOS | macOS, Windows, Linux, iOS, Android | macOS 15+ |

## 4. Value proposition and narrative comparison

| | Promise | Evidence offered | Mechanism | Uniqueness | Villain, hero, transformation |
| --- | --- | --- | --- | --- | --- |
| **Drakar** | Claude Code's full UI in a native window, nothing lost, nothing changed | (Planned) `make audit` network claim; protocol spike docs; tested-version footer | Spawns your `claude` with the extension's own stream-json arguments; `codex app-server`; IDE lock file | High on fidelity plus your setup plus terminal bridge | Villain: an editor you open only for a chat panel. Hero: your own agent. Transformation: open a folder, work, close; terminal sessions review in the same window |
| Claude Desktop | Everything about Claude Code in one app | First-party, docs | Bundled Claude Code, cloud, SSH | Breadth, distribution | Villain: the terminal's limits. Transformation: many sessions, visual |
| VS Code extension | Claude in your IDE | 27M installs | Bundled `claude`, webview | Editor context | Villain: context switching |
| Codex / ChatGPT | One workspace for all work | OpenAI scale | Codex runtime, plugins | Computer use, imports | Villain: scattered tools |
| Zed | Agents at editor speed | Benchmarks, open source | ACP | Multi-agent protocol | Villain: slow Electron editors |
| Conductor | A team of agents on your Mac | Customer logos *unverified* | Worktrees | Simplicity of parallel | Villain: one agent at a time |
| Nimbalyst | Agents you can see and edit visually | Open source, daily releases | Extensions, editors | Visual breadth | Villain: text-only agent output |
| Clarc | Claude Code for everyone | README, screenshots | Spawns real `claude` | Non-developer onboarding | Villain: the terminal wall |

## 5. Positioning map

Axes chosen because they separate the field most: **who owns the agent runtime and config** (your installed CLI, accounts and `~/.claude` unchanged, versus a bundled or synced runtime the product owns) and **what the product optimises for** (closely steering a few sessions, with permission prompts, diffs and review, versus orchestrating many agents in parallel or in the cloud).

```text
                     ORCHESTRATE MANY (parallel, worktrees, cloud)
                                      ^
        Nimbalyst  Conductor          |        Claude Desktop (Code tab)
        RxCode                        |        Codex / ChatGPT app
                                      |        Cursor     Warp factories
                                      |
  YOUR CLI, YOUR CONFIG <-------------+-------------> PRODUCT-OWNED RUNTIME
                                      |
        DRAKAR                        |        Claude Code for VS Code
        Clarc                         |        Zed (ACP adapters)
                                      |
                                      v
                     STEER A FEW CLOSELY (prompts, diffs, review)
```

The **bottom-left quadrant is underserved**: native, your own `claude` and accounts unchanged, built for close steering. The only occupants are Clarc (368 stars, aimed at non-developers, no release since August) and Drakar. Everything well funded is moving up and to the right. The quadrant is defensible only as long as Drakar keeps protocol fidelity and makes the "your setup, untouched" claim checkable.

## 6. Content gap analysis

No SEO tool was available, so "demand" below is inferred from GitHub issue reactions and the number of independent guides found, not from search volume.

**Topics**

| Topic | Evidence of demand | Who covers it | Drakar |
| --- | --- | --- | --- |
| Claude Code without VS Code / a native Claude Code GUI | Issue #69046 (small); opcode 22k stars; Clarc 368 | Clarc README, opcode, Claude Desktop docs | Nothing public (no site) |
| Several Claude accounts in one app | #18435, 1,066 reactions, open | Nobody in a GUI (Armada lists limit trackers, not clients) | Built: sessions from every account, account per window |
| Share skills between Claude Code and Codex | #31005, 546 reactions; at least six how-to guides (S) | Skill-manager READMEs, blog guides | Built (Skills window), unreleased |
| Use a non-VS Code editor for terminal `claude --ide` | No direct signal found | Nobody | Built (IDE bridge); documented only in `docs/claude-ide-bridge.md` |
| Claude Desktop vs CLI vs extension: which `claude` runs | Anthropic's own docs explain the separate copy | Anthropic docs | Built (Settings picks the install; footer warns on untested versions) |
| What a GUI sends over the network | None measured | Nobody | Built (`make audit`, `make audit-running`) |
| Parallel worktree agents | Heavy | Conductor, Nimbalyst, Claude Desktop, Codex, Cursor | Not a focus (sessions per project; no worktree creation) |

**Formats**

| Format | Drakar | Claude Desktop | Conductor | Nimbalyst | Zed | Clarc | Skill managers |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Marketing site | No | Yes | Yes | Yes | Yes | No (README) | Some (skillsmanager.dev) |
| Pricing page | No | Plan pages | Yes | Yes | Yes | n/a | n/a |
| Public changelog | No | Yes, near daily | Yes | GitHub releases | Yes, weekly | GitHub releases | GitHub releases |
| Docs | Internal only (`docs/`) | Extensive | Some | Yes | Extensive | README | READMEs |
| Comparison page | No | CLI comparison | No | No | No | "vs Claude Desktop" table | No |
| Demo video | No | Yes | *unverified* | Yes | Yes | Screenshots | YouTube (xingkongliang) |
| Mobile companion | No | Yes (Remote Control, Dispatch) | Yes (iOS, 0.90.0) | Yes | No | No | n/a |

## 7. Opportunities

1. **"Your Claude Code, not ours" against the first-party app.** Claude Desktop's own docs say it runs a separate copy of Claude Code with a separate session list and syncs customisation through claude.ai rather than `~/.claude` (P). Drakar runs the install you chose, reads every account, resumes sessions written by the terminal and the extension, and opens a session live elsewhere as a fork rather than as a second writer. This is the cleanest, most checkable contrast in the market.
2. **Multiple accounts.** 1,066 reactions and 202 comments on an open request to Anthropic (P). Drakar already lists sessions across `~/.claude` and `~/.claude-*` and picks an account per window. No GUI competitor found claims this.
3. **The terminal still wins for many; Drakar can be its review window.** The IDE bridge (a terminal `claude --ide` sending every edit to Drakar's Review Changes window) is unique among the products surveyed: Claude Desktop explicitly does not see terminal sessions, and Zed and VS Code are full editors. It lets Drakar sell to people who will never leave the terminal.
4. **Skills across Claude Code and Codex, verified against what each agent loads.** Claude Code does not read `.agents/skills` (P, #31005), Zed's manager serves only Zed's agent (P), and the free managers infer from paths. Drakar's "Not loaded by Claude Code", "Shadowed" and one-row-per-real-folder view is a genuine differentiator **inside** a two-agent client. It is a reason to choose Drakar, not a product on its own.
5. **Two agents, both full fidelity.** Codex sessions over `app-server` landed on 2026-10-08. Most Mac rivals support both through ACP or a wrapper; Drakar speaks each agent's native protocol. Worth saying once there is a public build.
6. **Native weight as proof, not as adjective.** Electron complaints exist but are thin (P, #69046 had 5 reactions). Lead with measurable facts (launch time, memory at a 1,000-turn transcript, the network audit) rather than "native" alone.

## 8. Threats

1. **Anthropic closes the gaps.** Account switching in Claude Desktop, or `.agents/skills` support in Claude Code, would each remove a wedge overnight. Both issues are open and active (updated 2026-10-05).
2. **Protocol drift.** stream-json is undocumented; Claude Code released 2.1.288 to 2.1.295 in six days (P) and Drakar tests 2.1.284 to 2.1.288. Codex's `app-server` is still labelled experimental by its own `--help` (`docs/codex-app-server.md`) and moved from 0.160.1 to 0.162.0. Each release is unpaid maintenance, and a broken release is a support burden on day one.
3. **Free everywhere.** Claude Desktop and the Codex app are included in subscriptions; Conductor local, Nimbalyst, Clarc, opcode and every skill manager are free. A paid one-time licence needs a reason a buyer can state in one line.
4. **Codex reaching into Claude Code's setup.** The Codex app's import of Claude Code skills and plugins "with automatic sync" (S, 2026-08-11) targets the same two-agent user Drakar's Skills window serves.
5. **Look-alikes.** Clarc and RxCode already use near-identical words ("native macOS client for Claude Code", "spawns the real `claude`"). Drakar's launch copy must not read as a third copy of the same README.
6. **Terms and trust.** Tools that ask users to sign in through them invite terms questions (Armada's `docs/limits-accounts-and-terms.md`). Drakar is on the safe side (your CLI, your login), which is an asset only if it is said plainly.
7. **Name** not yet checked (domain, GitHub `mgcrea/drakar`), per PLAN.md §7.7. *unverified* (no search budget left).

## 9. Recommended actions

**Quick wins (this week)**

1. **Re-capture and widen the tested range before anything is public.** Run the existing probes against Claude Code 2.1.295 and Codex 0.162.0, then raise `ClaudeVersion.tested` only after (PLAN.md §7.3 already calls for this habit). Evidence: §8.2. A pre-launch app showing an orange "untested version" footer on day one undoes the fidelity claim.
2. **Check claude.ai synced skills in the Skills window.** Look at how `~/.claude/skills/synced/<name>` rows appear in the running app (likely origin "Unknown") and decide whether the scan should read them as a read-only "claude.ai" origin, like plugins. Evidence: Claude Code's skills docs (P); no `synced` handling in the sources. Do this before the Skills window is shown to anyone.
3. **Write the positioning line and three proof points now, for the future site.** Suggested line: *"Claude Code and Codex, as you installed them, in a native Mac window."* Proof points, all built: (a) runs your `claude` and `codex`, every Claude account, sessions from the terminal and VS Code; (b) a terminal `claude --ide` sends its edits to Drakar for review; (c) Drakar opens one loopback socket and no connection of its own, checked by `make audit`. Keep the Skills window as a supporting feature, not the headline. Evidence: §5 and §7.

**Strategic moves**

4. **Make the first public page a comparison with Claude Desktop's Code tab**, not with VS Code. The first-party app is now the default GUI, and its own docs supply the contrast (separate Claude Code copy, separate session list, account-synced customisation, no view of terminal sessions). Cover multiple accounts explicitly (§7.2). Update PLAN.md §1, whose positioning table still compares only VS Code, the terminal and Zed, and still calls Drakar "Claude-first" although Codex has landed.
5. **Decide price against a free field (PLAN.md §7.5).** Options, without choosing: (a) free, to win the bottom-left quadrant before Anthropic moves; (b) the fleet's one-time licence (Armada sells at $14.99) justified by fidelity, accounts and the IDE bridge, with a trial; (c) free core plus a paid tier later. Whatever is chosen, do not charge for skill management alone: at least four free GUI managers exist (§2.11). Do not pivot toward parallel worktree orchestration as the headline either: that quadrant holds Anthropic, OpenAI, Cursor, Conductor and Nimbalyst.

## 10. Sources

All accessed 2026-10-09.

Primary (P)
- Claude Code Desktop docs: https://code.claude.com/docs/en/desktop
- Claude Code skills docs: https://code.claude.com/docs/en/skills
- Claude Code changelog: https://code.claude.com/docs/en/changelog
- Claude Code for VS Code, Marketplace: https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code
- anthropics/claude-code issues #18435, #31005, #69046: https://github.com/anthropics/claude-code/issues/18435, https://github.com/anthropics/claude-code/issues/31005, https://github.com/anthropics/claude-code/issues/69046
- ChatGPT desktop app (Codex): https://learn.chatgpt.com/docs/app
- ChatGPT and Codex changelog: https://learn.chatgpt.com/docs/changelog
- Zed stable releases: https://zed.dev/releases/stable
- Zed skills docs: https://zed.dev/docs/ai/skills
- Zed external agents docs: https://zed.dev/docs/ai/external-agents
- Conductor: https://www.conductor.build, https://www.conductor.build/pricing, https://www.conductor.build/changelog
- Nimbalyst: https://nimbalyst.com/ and https://github.com/nimbalyst/nimbalyst
- Crystal: https://github.com/stravu/crystal
- opcode: https://opcode.sh and https://github.com/winfunc/opcode
- Cursor: https://cursor.com/changelog, https://cursor.com/pricing
- Warp: https://www.warp.dev
- Clarc: https://github.com/ttnear/Clarc
- RxCode: https://github.com/rxtech-lab/rxcode
- Kooky: https://github.com/iAmCorey/kooky
- Vercel skills: https://github.com/vercel-labs/skills
- Skills Manager (xingkongliang): https://github.com/xingkongliang/skills-manager
- Skills Manager (jiweiyeah): https://github.com/jiweiyeah/Skills-Manager and https://skillsmanager.freeourdays.com/
- Skills Manager (yibie): https://github.com/yibie/skills-manager
- SkillsManager (tddworks): https://github.com/tddworks/SkillsManager
- skills-supply: https://github.com/803/skills-supply

Secondary (S)
- Codex App changelog mirror (gradually.ai): https://www.gradually.ai/en/changelogs/codex-app/
- AlternativeTo on the Codex Mac app: https://alternativeto.net/news/2026/2/openai-unveils-a-dedicated-codex-desktop-app-for-macos-and-anyone-can-try-it-for-free
- Zed 1.0 and parallel agents: https://codex.danielvaughan.com/2026/05/05/codex-cli-in-zed-parallel-agents-acp-integration-ide-workflows/
- Claude Code over ACP in Zed: https://www.ithome.com.tw/news/171007
- Skill-sharing guides: https://github.com/shin1ohno/setup/pull/1058, https://docs.kanaries.net/articles/codex-vs-claude-code-skills, https://www.ssw.com.au/rules/symlink-agents-to-claude, https://wow.pjh.is/journal/share-skills-between-coding-agents
- Vercel skills launch: https://vercel.com/changelog/introducing-skills-the-open-agent-skills-ecosystem
- Cursor 3 and the SpaceX report: https://developertoolkit.ai/en/appendices/update-tracker/ (*unverified*)

Internal
- `PLAN.md`, `README.md`, `docs/claude-stream-json.md`, `docs/codex-app-server.md`, `docs/claude-ide-bridge.md`, `docs/superpowers/specs/2026-10-09-skills-manager-design.md`, `ClaudeVersion.swift`, git history to `70ee531`.
- Armada's `docs/landscape.md` (session monitors, limit trackers, orchestrators) and `docs/market-intel.md` (fleet pricing precedent).

### Monitoring (re-check monthly)

- Claude Code changelog: account switching, `.agents/skills` support, any change to stream-json or the IDE lock-file contract; issues #18435 and #31005.
- Claude Desktop docs: whether it starts using the terminal's `claude` or `~/.claude` customisation directly.
- Codex CLI releases and `app-server` schema diffs (`codex app-server generate-json-schema`); the Codex app's Claude Code import.
- Clarc and RxCode releases and stars (the nearest look-alikes); any new native Claude Code client on GitHub.
- Conductor and Nimbalyst changelogs for single-session depth (permission UI, skills).
- Skill managers: xingkongliang and yibie releases, skills.sh, and whether any start reading what agents actually load.
- Re-run web searches skipped this time for lack of budget: Show HN and Product Hunt launches of Claude Code clients in the last three months, the Drakar name and domain, Warp and Cursor pricing.
