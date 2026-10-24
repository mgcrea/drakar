# Drakar: competitive brief, refresh

- **Research date:** 2026-10-21. A delta on [competitive-brief-2026-10-09.md](competitive-brief-2026-10-09.md): same competitor set, same evidence grades, same positioning map. Only what changed in twelve days, what was *unverified* then and is settled now, and what the last run skipped for lack of search budget.
- **Evidence grades:** (P) primary: vendor page, docs, changelog, registry, GitHub API. (T) trade press. (S) secondary. *unverified*.
- **No SEO or traffic tools** were connected again; GitHub stars, Marketplace installs, issue reactions and HN or Product Hunt points are the only numbers.

## Drakar since 2026-10-09

21 commits, all on `main`, which is 157 commits ahead of `origin/main` (nothing public yet). New: **Run in Each Subfolder** (a skill sent to a session per subfolder, a few at a time, with a banner per batch), the editor moved to the right of the session with a setting, Esc as interrupt, file links into the editor. `ClaudeVersion.tested` raised to 2.1.284...2.1.296 and Codex checked with 0.162.1, both on 2026-10-12, and the procedure for checking a release is now written down (`docs/claude-stream-json.md`, `docs/codex-app-server.md`).

Status of the 2026-10-09 recommendations:

| # | Recommendation | Status |
| --- | --- | --- |
| 1 | Re-capture and widen the tested range | Done 10-12 (2.1.296, 0.162.1). **Behind again**, see §2.1 |
| 2 | claude.ai synced skills in the Skills window | Not done: no `synced` anywhere in the sources |
| 3 | Positioning line and three proof points | Not done (no site) |
| 4 | Comparison with the Claude Desktop Code tab; update PLAN.md §1 | Not done: §1 still compares VS Code, terminal and Zed, and still says "Claude-first" |
| 5 | Decide price against a free field | Open; new anchors below (§3) |

## 1. Executive summary

Nothing moved into Drakar's quadrant (native, your installed `claude` and `codex`, close steering). Anthropic shipped eleven Claude Code releases and a Desktop layout refresh, but did not touch the two wedges: multiple accounts (#18435, now 1,159 reactions, no staff reply) and `.agents/skills` (#31005, 566, reopened, no staff reply). Its terms still explicitly allow what Drakar does.

- **Biggest opportunity:** the field has made Drakar's contrast sharper. OpenAI now documents, on its own page, a Codex import that *copies* your Claude Code setup (skills, plugins, hooks, subagents, chats) into its own format and keeps it in sync. Conductor is a Tauri app that *bundles* Claude Code 2.1.300. Cursor now bills Claude at API list price behind a Grok-first plan. Each is a different way of taking your Claude Code away from you; Drakar is the one that leaves it where it is.
- **Biggest threat:** protocol drift, again, and this time with a change that applies to Drakar's own launch mode. Claude Code is at 2.1.306 (`latest`) and 2.1.304 (`stable`) against a tested ceiling of 2.1.296, and 2.1.302 turned fork subagents on by default in headless and SDK sessions, which is how Drakar runs `claude`. Codex stable is 0.163.0 with 0.164.0 in its ninth alpha, against 0.162.1 checked.

## 2. What changed, by competitor

### 2.1 Claude Code CLI and VS Code extension (Anthropic)

- **Releases 2.1.296 to 2.1.306** (10-09 to 10-21; 2.1.297 and 2.1.298 were never published) (P, npm registry and CHANGELOG.md). Items that touch Drakar:
  - **2.1.299 (10-14):** queued content-block prompts sent over `--input-format stream-json` no longer run together. A stream-json behaviour change, in Drakar's favour, but outside the tested range.
  - **2.1.300 (10-14):** local transcripts now record each request's system prompt, tools and parameters. The session files Drakar lists and resumes from get larger.
  - **2.1.302 (10-16):** fork subagents (`subagent_type: "fork"`) on by default in `claude -p` and the SDK (`CLAUDE_CODE_FORK_SUBAGENT=0` turns them off); Desktop and VS Code always run subagents in the background. Drakar spawns `claude` with the SDK's stream-json arguments, so this default reaches Drakar sessions. How a fork subagent arrives in the stream and in history, and whether `ToolKind.subagent` and the transcript translator render it, is *unverified*.
  - **2.1.304 (10-19):** mods get `decider: "person"`, so only the permission dialog or "a host's callback" may approve. Drakar's permission sheet is such a host callback; worth a capture.
  - **2.1.296 (10-09):** fixed claude.ai synced skills re-downloading when several sessions share a config directory. Confirms synced skills are live and common (recommendation 2 above).
  - Nothing mentions `--permission-prompt-tool`, `--ide`, lock files, `CLAUDE_CONFIG_DIR` or `.agents/skills`.
- **VS Code Marketplace:** 28,304,644 installs (+885k in twelve days), 3.73 stars from 833 ratings (was about 3.5 from 822), version 2.1.306 (P).
- **Terms:** `code.claude.com/docs/en/legal-and-compliance` is identical to its 10-08 snapshot. It still allows "an end user… signing in to the unmodified Claude Code binary with their own Claude subscription" (P). That sentence describes Drakar exactly and can be quoted.

### 2.2 Claude desktop app, Code tab (Anthropic)

- All four structural statements Drakar's contrast rests on are **unchanged** (P, docs compared with the 10-09 Wayback snapshot): its own copy of Claude Code, its own session list, Customize synced through claude.ai rather than `~/.claude`, no awareness of terminal or VS Code sessions.
- New in the docs since 10-09: a new layout (v2.37337.0+) with an environment selector and saved environments, a session details panel, adding folders to a running session, SSH tasks that survive disconnection, Windows remotes over SSH, auto-save in the file pane, group and sort in the session list (P; ship dates *unverified*, there is no dated Desktop changelog).
- **Issue #18435** (multiple accounts): open, 1,159 reactions (+93), 213 comments, updated 10-21, no staff reply (P). Users report the mobile app gained switching between up to three accounts on 09-13 and that Desktop already holds multi-account code behind a flag (*unverified*). If true, the wedge has a visible expiry.
- **Issue #31005** (`.agents/skills`): reopened but still labelled duplicate, 566 reactions, updated 10-20, no staff reply (P).
- Other Anthropic news (Code Review GA, Scion, agent observability, Claude Security, Claude Duet on mobile) does not touch Drakar's lane (P).

### 2.3 Codex CLI and the ChatGPT desktop app (OpenAI)

- **Codex CLI:** 0.162.1 (10-09) and **0.163.0 (10-15)** stable; 0.164.0-alpha.1 to alpha.9 (10-16 to 10-21) (P). 0.163.0's `app-server` changes: connection-bound reply handles, global config independent of launch directory, experimental durable thread read state and updates, experimental item lookup by id. Plugins: a default activation policy, plugin mentions that no longer suppress same-name skills. `skills/list` and `skills/config/write` unchanged; a `SkillsChangedNotification` asks clients to re-list (P, protocol source). The app-server is not labelled experimental as a whole; individual features sit behind `experimentalApi` (P, README). This corrects the 10-09 brief.
- **The Claude Code import is now verified (P, learn.chatgpt.com/codex/import).** The ChatGPT desktop app imports from Claude Code, Claude Cowork or Cursor: instruction files into AGENTS.md, `settings.json` into `config.toml`, skills, plugins and slash commands into Skills, subagents, hooks, project folders, project memories, chats from the last 30 days and MCP config. "Turn on automatic updates to keep imported work in sync with the original agent." "Importing doesn't change or delete your existing agent setup." The 08-11 date stays *unverified*.
- **App:** composer predictions beta (10-09), GPT-5.5 retired from Codex for ChatGPT sign-ins in favour of GPT-6.1 Sol (10-14) (P). The new ChatGPT Mac app is described as "a svelte 1.5 GB Electron bundle" that replaced the AppKit app, now "ChatGPT Classic" (T, Daring Fireball, 07-09). Not stated by OpenAI.

### 2.4 Zed

Stable 1.23.3, 1.24.2, 1.24.3, 1.24.4 (10-12 to 10-20), ACP fixes only (P). **No change** to Claude Agent over ACP (no mention of plan mode or slash commands) or to Skills (still `~/.agents/skills` only, still Zed Agent only) (P).

### 2.5 Cursor

- **SpaceX acquisition confirmed:** a $60B all-stock deal reported 2026-06-16 (T, CNBC, Forbes), closed 2026-08-14 into a SpaceXAI unit (T, Techzine, from search summaries; the page itself was rate-limited).
- **Pricing rebuilt around Grok, around 10-12 to 10-13** (P page, undated; S pricingsaas diff): Free, Plus $8 (Grok only), Premium $30, Super $100, Ultra $200, Teams $30+/user; one weekly pool shared with Grok, **third-party models such as Claude billed at API list price**. Changelog: Origin App Marketplace (10-13), shareable cloud agent canvases and an Environments API beta (10-16) (P).
- Relevance: Claude-loyal Cursor users now pay more for Claude there. That is a population looking for another home for Claude Code, and Drakar runs it on their own subscription.

### 2.6 Warp

No change to "Open infrastructure for cloud software factories" (P). Pricing today: Free, Build $20, Max $200, Business $50/user, plus Factories tiers (P; not compared with 10-09).

### 2.7 Third-party clients and orchestrators

| Product | 10-09 | 10-21 | What changed (P unless noted) |
| --- | --- | --- | --- |
| Conductor | v0.90.0 | v0.91.0 (10-15), 0.91.2 | Haiku 5.5, voice on macOS 26, stacked PRs, iOS remote control. **Bundles Claude Code 2.1.300 and Codex 0.162.1.** **Tauri 2.0**, per its co-creator on HN (S, vendor statement): settles the 10-09 *unverified* stack. A "loadout" is a shareable default-model setup, not skills. Pricing unchanged |
| Nimbalyst | 1,856★, v0.80.6 | 1,955★, v0.81.7 (10-16) | Next-prompt suggestions, auto-resume after usage-limit resets, folder-watching of external Claude Code and Codex sessions, a Wiki plugin. Electron. App still free; **Wiki Teams $20/user/mo** in beta |
| RxCode | 6★, v1.20.2 | 6★, v1.22.0 (10-20) | Four releases: MCP OAuth, IDE task tools, models per thread action. Still no audience |
| Clarc | 368★, v1.4.1 | 369★, v1.4.1 | No change; quiet since August |
| opcode | 22,415★ | 22,417★ | No change; no release since 2025-08-31 |
| Kooky | 654★ | 654★, v0.51.12 (10-12) | Split shortcuts, workspace stepping |

**New entrants** (the search skipped on 10-09; GitHub since 09-01, Show HN and Product Hunt since 07-21). No new full native chat client for both Claude Code and Codex. The ones that matter:

| Product | Date | Traction | Pitch | Why it matters |
| --- | --- | --- | --- | --- |
| AgentDock | Product Hunt 10-10 | 62 pts | Answer Claude Code and Codex from one inbox | **$19 one-time** for a Mac agent tool: a price anchor |
| Offrun | Show HN 10-03 | 78 pts | Claude Code, Codex, AGY and Grok Build side by side, worktrees, `/` for skills; free | Orchestration quadrant, Mac only |
| kuvo-code | created 10-13, v0.6.6 | 69★ | "Native macOS harness for coding agents" on the opencode engine | SwiftUI and native, but not your `claude` |
| Pinrail | Show HN 10-07 | 27 pts, 47★ | Desktop inbox where agents wait for review | Rust; review-queue angle |
| QuillCode | Show HN 08-10 | 15 pts | "100% native Swift harness (NOT Electron)" | Its own agent; uses "native" as the headline and got little traction |
| Tellurion, flockbook, Television, Termic, skeezo | 07 to 10 | small | Terminals, readers, wrappers | Watch only |

Most new Swift repos are notch, menu-bar and usage companions (coucou 5,778★, codenotch 2,880★), Armada's landscape rather than Drakar's.

### 2.8 Skill managers

- **xingkongliang/skills-manager:** 6,640★ (+811), five releases to v1.43.0 (10-21). Still path-based; its own 1.43.0 notes admit skills deployed to one agent "never loaded" because of a wrong path (P). That is the failure Drakar's "Not loaded by Claude Code" row exists to show.
- **vercel-labs/skills:** 35,962★ (+2.4k). `skills sync` promoted to stable in v1.7.3 and walked back to `experimental_sync` in v1.7.4 the same day (10-19); v1.7.2 moved Codex global skills to `~/.agents/skills` (P).
- **yibie/skills-manager:** no change.
- **New:** flaviocopes/skill-cabinet (Swift, 71★, v1.5.0 on 10-08) reads transcripts for the moment an agent opens a skill's `SKILL.md` to count uses. It is the nearest to an "actually loaded" claim, but after the fact rather than by asking the live agent. Its author has a large developer audience. skills-hub (Tauri, 1,821★, Show HN 10-12) and Cheatcode_ (SwiftUI installer, 81★) are also new (P).
- Still nobody claims to ask the running agent what it loaded. Drakar's differentiator in this category holds.

## 3. Messaging matrix: rows that changed

| | Drakar | Claude Desktop | Codex in ChatGPT app | Conductor | Cursor |
| --- | --- | --- | --- | --- | --- |
| Agent runtime | Your installed `claude` and `codex` | Its own copy of Claude Code | Codex; **imports** your Claude Code setup and syncs it | **Bundles** Claude Code 2.1.300 and Codex 0.162.1 | Its own agent; Claude at API list price |
| Shell | SwiftUI and AppKit | Electron (S) | Electron (T) | Tauri 2 (S, vendor) | Electron fork |
| Price | Undecided | In Claude plans | In ChatGPT plans | Free local; Pro $50/mo | Plus $8 (Grok) to Ultra $200 |

Price anchors for PLAN.md §7.5: AgentDock $19 one-time (Product Hunt, 10-10), Armada $14.99 one-time (fleet), everything else free or subscription.

## 4. Opportunities (new or strengthened)

1. **"Nothing to import, nothing to sync."** OpenAI's own page lists what it copies out of Claude Code to run it in Codex. Drakar runs Claude Code and Codex on the same folders, each with its own config, and the Skills window shows one real folder seen by both. That is a stronger line than "your Claude Code, not ours" alone, because the contrast is now a primary source.
2. **The terms sentence.** Anthropic's compliance page allows an end user signing in to "the unmodified Claude Code binary with their own Claude subscription". Quote it on the site; it answers the trust question before it is asked.
3. **Claude users leaving Cursor.** Cursor's Grok-first repricing makes Claude dearer there. "Claude Code on your own subscription, without an editor" is a natural landing page for that search.
4. **#18435 is growing and unanswered** (+93 reactions in twelve days). Multi-account remains Drakar's clearest built feature that no GUI competitor claims.
5. **"Never loaded" is now a documented failure in the leading skill manager.** Drakar's check against what each agent reports is a concrete demo: the same skill, on disk, shown as not loaded and why.

## 5. Threats (new or changed)

1. **Drift that reaches Drakar's launch mode:** fork subagents by default in SDK and headless sessions (2.1.302), larger transcripts (2.1.300), a stream-json queueing fix (2.1.299), a new approval rule for mods (2.1.304). Ten releases past the tested ceiling. Codex 0.163.0 changed `app-server` (reply handles, config resolution) and 0.164.0 is close. Note: the `codex` on this Mac's PATH is still 0.160.1.
2. **Multi-account may already be in Claude Desktop behind a flag** (*unverified*, user reports in #18435). If it ships, Drakar's clearest wedge narrows to "every account *and* your own `claude`".
3. **Codex's import is free, OpenAI-backed and live**, and aims at the same two-agent user as the Skills window.
4. **More native look-alikes.** kuvo-code and QuillCode both lead with "native Swift" and stay small; the word alone does not sell (consistent with the 10-09 finding).
5. **Run in Each Subfolder** pulls Drakar slightly toward the orchestration quadrant, which now also holds Offrun. Keep it framed as a skill feature (one chore across a monorepo), not as parallel agents.

## 6. Recommended actions

**Quick wins (this week)**

1. **Run the new release check on Claude Code 2.1.304 (`stable`) and 2.1.306**, with two scenarios added: a turn that spawns a subagent (to see how a default fork subagent arrives in the stream and in history), and a session list over transcripts written after 2.1.300 (to measure the larger files). Raise `ClaudeVersion.tested` only after. Same for Codex: `generate-ts` diff of 0.162.1 against 0.163.0, and update this Mac's `codex` from 0.160.1.
2. **Handle claude.ai synced skills** (carried over). 2.1.296's fix shows they are in active use; a row reading origin "Unknown" in the Skills window will look like a bug in a demo.
3. **Write the line and proof points into PLAN.md §1**, replacing the VS Code, terminal and Zed table and the "Claude-first" wording. Suggested line, unchanged from 10-09: *"Claude Code and Codex, as you installed them, in a native Mac window."* Add as proof: the Anthropic terms sentence (§4.2) and "nothing to import" (§4.1).

**Strategic moves**

4. **Make the comparison page a three-column one**: Claude Desktop (its own copy), Codex app (imports a copy), Drakar (yours, as installed). All three columns now have primary sources.
5. **Price:** AgentDock at $19 one-time and Armada at $14.99 make a one-time licence in that range defensible for a tool that does more. The free field is unchanged, so the one-line reason a buyer would pay still has to be multi-account plus fidelity plus the IDE bridge, not skills.
6. **Name:** drakar.com and drakar.io are for sale, drakar.app was registered on 2026-02-15 by an unknown owner, drakar.dev is dead. PLAN.md plans `drakar.mgcrea.io`, so none is required. No software product named Drakar was found (*unverified* on GitHub and the App Store, rate-limited).

## 7. Sources

All accessed 2026-10-21.

Primary (P)
- Claude Code: https://registry.npmjs.org/@anthropic-ai/claude-code, https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md, https://code.claude.com/docs/en/desktop, https://code.claude.com/docs/en/legal-and-compliance
- Issues: https://github.com/anthropics/claude-code/issues/18435, /31005, /69046
- VS Code Marketplace: https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code
- Anthropic: https://claude.com/blog
- Codex: https://github.com/openai/codex/releases/tag/rust-v0.163.0, https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md, https://learn.chatgpt.com/docs/changelog, https://learn.chatgpt.com/codex/import
- Zed: https://zed.dev/releases/stable, https://zed.dev/docs/ai/external-agents, https://zed.dev/docs/ai/skills
- Cursor: https://cursor.com/changelog, https://cursor.com/pricing
- Warp: https://www.warp.dev, https://www.warp.dev/pricing
- Conductor: https://conductor.build/changelog/0.91.0-a-mostly-boring-update, https://conductor.build/changelog/0.86.0-share-your-loadouts, https://conductor.build/pricing
- Nimbalyst: https://github.com/nimbalyst/nimbalyst/releases/tag/v0.81.7, https://nimbalyst.com/pricing
- RxCode, Clarc, opcode, Kooky: their GitHub repositories and releases
- New entrants: https://news.ycombinator.com/item?id=49942434 (Offrun), https://www.producthunt.com/products/agentdock, https://github.com/serhatandic/kuvo-code, https://github.com/forgeplane/pinrail, https://github.com/Lore-Hex/QuillCode, https://github.com/steventsvik/Tellurion, https://github.com/minchenlee/flockbook, https://television.run/
- Skill managers: https://github.com/xingkongliang/skills-manager/releases, https://github.com/vercel-labs/skills/releases, https://github.com/yibie/skills-manager, https://github.com/flaviocopes/skill-cabinet, https://github.com/qufei1993/skills-hub, https://github.com/ChenxingJi-Innovate/Cheatcode_

Trade press (T) and secondary (S)
- Cursor acquisition: https://www.cnbc.com/2026/06/16/spacex-spcx-cursor-acquisition-ipo.html, https://www.techzine.eu/news/devops/143619/spacex-completes-acquisition-of-cursor/
- Cursor pricing diff: https://pricingsaas.com/companies/cursor/diffs/2026D286
- ChatGPT app as Electron: https://daringfireball.net/linked/2026/07/09/todays-the-day-openai-fucked-up-the-chatgpt-mac-app
- Conductor on Tauri: https://news.ycombinator.com/item?id=46751354

Internal
- `git log` since 2026-10-09, `ClaudeVersion.swift`, `ClaudeCommand.swift`, `PLAN.md` §1 and §7, `docs/claude-stream-json.md`, `docs/codex-app-server.md`.

### Refreshing this brief

Primary sources that give dates and counts where the vendor pages do not: Claude Code
publish dates from the npm registry (`npm view @anthropic-ai/claude-code time --json`), not
the changelog; Claude Desktop doc changes by diffing `code.claude.com/docs/en/desktop`
against its Wayback snapshot, since Desktop has no dated changelog; issue reactions from the
GitHub API (`gh api repos/anthropics/claude-code/issues/18435 --jq .reactions.total_count`);
Marketplace installs and rating from the Marketplace API, not the rendered page.

### Gaps this run

Releasebot (Desktop app updates), Techzine and OpenAI's August changelog were rate-limited. Desktop ship dates have no primary source. The GitHub name search for "Drakar" and the App Store were not checked. X was not searched.
