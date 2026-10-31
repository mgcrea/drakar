# Parity with the VS Code extension

One row per request the extension's webview sends its host, which is close to one row per
feature of its UI, and one per control request `claude` accepts (the last section).
`scripts/extension-surface.sh` (`make extension-diff`) lists them from the installed
extension and fails while a request has no row here, or a row names a request the
extension stopped sending.

Triaged against extension 2.1.311 on 2026-10-27, from Drakar's sources, not its docs. Evidence re-anchored and the requests checked against 2.1.312 on 2026-10-28. Line numbers drift as the code moves: each cites the declaration that shows the feature, so search for it if a line has moved.

**Status** is a fact about Drakar, checked in code:

- `has`: Drakar does the equivalent (evidence is one place that shows it).
- `partial`: some of it; the note says what differs.
- `no`: nothing like it in Drakar.
- `n/a`: plumbing between a VS Code webview and its host, with no product meaning here.
- `gone`: the extension no longer sends it (kept, with the version it went in).
- `sends`: in the CLI section only, Drakar sends this control request.

**Decision** is yours, blank until made: `adopt`, `differ` (Drakar does it its own way on
purpose) or `skip`, with the reason in a few words. A `skip` with its reason is what saves
looking at the same feature again in three weeks. PLAN.md's promises set the bar: nothing
lost against the extension (thinking, tools, subagents, permissions, plan mode, todos), the
`claude` you installed unchanged.

## Reviewing a release

1. `make extension-diff`: new and dropped requests, UI copy, `package.json` contributions
   and settings keys since `docs/extension-surface/VERSION`. A launchd agent
   (`~/Library/LaunchAgents/io.mgcrea.drakar.extension-diff.plist`) runs it on Monday
   mornings and posts a notification when there is something to review. It is launchd
   because the check must read `~/.vscode/extensions`: Claude Code's cron jobs die with
   their session, and its cloud routines cannot see this Mac.
2. Add a row for each new request; mark dropped ones `gone`. New strings with no new
   request are usually a changed behaviour of an existing feature: note it on that row.
3. `make extension-accept`, and commit the ledger. The snapshot stays on this Mac:
   `docs/extension-surface/` is git-ignored because it is the extension's own text, so a
   worktree has none, and `make extension-diff` there says "no snapshot yet (run with
   --accept)". Don't: accepting there marks the extension's current version as reviewed. Run it
   from the main checkout, or link that folder into the worktree for the run.

Protocol changes are the other half and have their own procedure (raising
`ClaudeVersion.tested`, end of `docs/claude-stream-json.md`); do both in one pass.

## Conversation

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `interrupt_claude` | has | Stop the running turn | `apps/apple/Drakar/Services/AgentSession.swift:1094` | |
| `set_model` | has | Change the session's model | `apps/apple/Drakar/Services/AgentSession.swift:634` | |
| `set_permission_mode` | has | Change the permission mode (Auto only for a model that takes it, and not while settings set `disableAutoMode: "disable"`, as the extension decides) | `apps/apple/Drakar/Services/AgentSession.swift:614` | |
| `persist_session_permission_mode` | has | Remember a session's permission mode | `apps/apple/Drakar/Services/SessionMeta.swift:11` | |
| `set_thinking_level` | partial | Turn extended thinking on or off (Drakar: an effort level picker) | `apps/apple/Drakar/Views/SessionPills.swift:98` | differ: the effort picker |
| `get_context_usage` | has | Context window usage breakdown (/context) | `apps/apple/Drakar/Services/ClaudeBackend.swift:153` | |
| `side_question` | no | Ask a side question without derailing the session | | adopt: one CLI request each |
| `run_in_background` | has | Move a running tool call to the background (Drakar: a line on the call's card) | `apps/apple/Drakar/Views/TaskControlViews.swift:114` | adopt: `background_tasks` |
| `stop_subagent` | has | Stop a running subagent or background task (Drakar: on the task's card, not an agent map) | `apps/apple/Drakar/Views/TaskControlViews.swift:80` | adopt: subagents promise |
| `get_subagent_transcript` | has | Read a subagent's own transcript (Drakar: reads the file itself, inside the card) | `apps/apple/Drakar/Services/SubagentFeed.swift:18` | adopt: subagents promise, after a reload too |
| `get_task_output` | has | Read a background task's output (Drakar: background Bash tasks only; reads the tail of the task's output file, `get_task_output` as the fallback when the file is not known) | `apps/apple/Drakar/Services/TaskControls.swift:88` | adopt: subagents promise |
| `rewind_code` | has | Revert file edits back to a chosen message (Drakar: a prompt's undo arrow, a dry-run sheet before any file is written) | `apps/apple/Drakar/Views/RewindViews.swift:174` | adopt: `rewind_files`, dry run first |
| `fork_conversation` | has | Fork a session, optionally from a chosen message (Drakar: from a prompt's undo arrow, or the whole session) | `apps/apple/Drakar/Services/Project.swift:1201` | adopt: from a chosen message, with rewind |
| `export_conversation` | no | Export the conversation as text (/export) | | adopt: one CLI request each |
| `open_export_document` | no | Open an export in the editor to save it | | adopt: one CLI request each |
| `message_rated` | no | Thumbs up or down on a response | | skip: Anthropic's feedback channel for its own UI |
| `update_session_bookmark` | no | Bookmark or unbookmark a message | | skip for now: VS Code-private state; project windows cover it |
| `get_session_bookmarks` | no | List the bookmarked messages in a session | | skip for now: VS Code-private state; project windows cover it |
| `get_bookmarked_responses` | no | Fetch the text of bookmarked responses | | skip for now: VS Code-private state; project windows cover it |
| `set_focus_view` | no | Focus view: hide tool activity, show only the dialogue | | skip: tool cards collapse |
| `start_speech_to_text` | no | Start voice dictation | | skip: macOS Dictation works in any text view |
| `stop_speech_to_text` | no | Stop voice dictation | | skip: macOS Dictation works in any text view |
| `list_files_request` | partial | File search for @-mentions (Drakar: Quick Open for the editor, no @-mention) | `apps/apple/Packages/DrakarKit/Sources/DrakarKit/QuickOpen.swift:52` | adopt: @-mentions in the composer |
| `get_terminal_contents` | no | Attach a terminal's output to the prompt | | skip: no terminal panel |
| `open_claude_in_terminal` | no | Run `claude` (a slash command or --resume) in a terminal | | skip: no terminal panel |

## Edits, files and plans

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `accept_diff` | has | Accept an edit Claude proposes, shown as a diff | `apps/apple/Drakar/Views/PermissionSheet.swift:56` | |
| `open_diff` | has | Show a proposed edit as a diff (Drakar: inline in the permission sheet) | `apps/apple/Drakar/Views/PermissionSheet.swift:30` | |
| `open_file_diffs` | no | Review all of a session's file changes as diffs | | adopt: review a session's changes |
| `open_file` | has | Open a file, at a location, in the editor | `apps/apple/Drakar/Views/TranscriptView.swift:482` | |
| `open_content` | partial | Open tool input or content as a document (Drakar: inline in the card) | `apps/apple/Drakar/Views/TranscriptView.swift:432` | differ: inline in the card |
| `open_url` | has | Open a link | `apps/apple/Drakar/Views/LinkText.swift:97` | |
| `open_folder` | has | Pick and open a folder | `apps/apple/Drakar/DrakarApp.swift:75` | |
| `open_folder_in_new_window` | has | Open a folder or worktree in a new window | `apps/apple/Drakar/Views/HomeView.swift:204` | |
| `create_worktree` | no | Create a git worktree to work in | | adopt: parallel sessions in one project |
| `open_plan` | has | Open the session's plan file (/plan open; Drakar: Session › Open Plan, or the plan panel's Open Plan File, in the side editor) | `apps/apple/Drakar/Services/Project.swift:1278` | adopt: plan mode promise |
| `open_markdown_preview` | partial | Plan preview with comments (Drakar: inline panel, no comments) | `apps/apple/Drakar/Views/PlanPanel.swift:42` | adopt: plan comments, plan mode promise |
| `close_plan_preview` | partial | Close the plan preview once answered (Drakar: the inline panel goes away) | `apps/apple/Drakar/Views/SessionView.swift:76` | differ: the inline plan panel |
| `remove_plan_comment` | no | Delete a comment left on the plan | | adopt: plan comments, plan mode promise |

## Sessions

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `launch_claude` | has | Start or resume a session's CLI process | `apps/apple/Drakar/Services/ClaudeLaunch.swift:22` | |
| `close_channel` | has | End a session's CLI process | `apps/apple/Drakar/Services/Project.swift:1622` | |
| `list_sessions_request` | has | List past sessions | `apps/apple/Packages/DrakarKit/Sources/DrakarKit/SessionIndex.swift:125` | |
| `get_session_request` | has | Load a session's transcript to show or resume | `apps/apple/Packages/DrakarKit/Sources/DrakarKit/History.swift:117` | |
| `resolve_session_request` | partial | Find which worktree a session's transcript lives in (Drakar: worktree sessions folded into the project) | `apps/apple/Drakar/Services/SessionMonitor.swift:91` | differ: worktrees folded into the project |
| `open_held_session` | has | Open a session another process holds (Drakar: Move Here, or Fork a Copy) | `apps/apple/Drakar/Views/SessionView.swift:66` | |
| `rename_session` | has | Rename a session | `apps/apple/Drakar/Views/RenameSessionPrompt.swift:24` | |
| `generate_session_title` | partial | Have the CLI generate a title (Drakar: shows the CLI's ai-title, never asks for one) | `apps/apple/Packages/DrakarKit/Sources/DrakarKit/Transcript.swift:134` | differ: the CLI's own title |
| `archive_session` | no | Archive a session out of the list | | skip for now: VS Code-private state; project windows cover it |
| `unarchive_session` | no | Unarchive a session | | skip for now: VS Code-private state; project windows cover it |
| `unarchive_sessions` | no | Unarchive several sessions | | skip for now: VS Code-private state; project windows cover it |
| `set_session_unread` | no | Mark a session read or unread | | skip for now: VS Code-private state; project windows cover it |
| `get_session_groups` | no | User-defined groups of sessions | | skip for now: VS Code-private state; project windows cover it |
| `update_session_groups` | no | Edit user-defined session groups | | skip for now: VS Code-private state; project windows cover it |
| `get_session_list_filter` | partial | Saved session-list filter, active and status (Drakar: search and sort, no status filter) | `apps/apple/Drakar/Views/HomeView.swift:44` | differ: search and sort |
| `update_session_list_filter` | partial | Save the session-list filter (Drakar: search and sort only) | `apps/apple/Drakar/Views/HomeView.swift:44` | differ: search and sort |
| `update_session_section_collapse_state` | partial | Collapse sections of the session list (Drakar: only the Ended section) | `apps/apple/Drakar/Views/ProjectSidebar.swift:158` | differ: search and sort |
| `get_collapsed_panel_sections` | has | Remember which panel sections are collapsed (Drakar: inspector sections) | `apps/apple/Drakar/Views/InspectorView.swift:59` | |
| `update_collapsed_panel_sections` | has | Save which panel sections are collapsed (Drakar: inspector sections) | `apps/apple/Drakar/Views/InspectorView.swift:59` | |

## Settings and permissions

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `get_applied_settings` | has | Read the settings the session actually applies | `apps/apple/Drakar/Services/ClaudeBackend.swift:240` | |
| `apply_settings` | partial | Write settings at the user, local or flag layer (Drakar: only effort, as flag settings) | `apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift:108` | differ: the effort picker |
| `refresh_claude_settings` | partial | Re-read the session's settings (Drakar: only after start and model or effort changes) | `apps/apple/Drakar/Services/ClaudeBackend.swift:239` | differ: refreshed without asking |
| `open_config` | has | Open the extension's settings (Drakar: its own Settings window) | `apps/apple/Drakar/Views/SettingsView.swift:292` | |
| `open_config_file` | no | Open a Claude config file (settings.json) in the editor | | adopt: in an editor tab |
| `get_status` | partial | Status dialog, /status (Drakar: the inspector shows id, model, context) | `apps/apple/Drakar/Views/SessionInspector.swift:144` | differ: the inspector |
| `add_permission_rules` | has | Add allow or deny rules (Drakar: Add Rule… in the inspector's Permissions tab, and a prompt's "always allow" suggestions) | `apps/apple/Drakar/Views/PermissionsInspector.swift:333` | adopt: permissions promise |
| `list_permission_rules` | has | List permission rules (Drakar: the inspector's Permissions tab) | `apps/apple/Drakar/Views/PermissionsInspector.swift:12` | adopt: permissions promise |
| `remove_permission_rule` | has | Remove a permission rule (Drakar: on a settings-file rule's row) | `apps/apple/Drakar/Views/PermissionsInspector.swift:265` | adopt: permissions promise |
| `get_sandbox_dialog` | no | Load the Bash sandbox settings dialog | | skip: editors for files you own; Drakar opens the files |
| `set_sandbox_setting` | no | Change a Bash sandbox setting | | skip: editors for files you own; Drakar opens the files |
| `get_hooks_listing` | no | List the configured hooks | | adopt: read-only, in the inspector |
| `edit_hook` | no | Add, edit or remove a hook | | skip: editors for files you own; Drakar opens the files |
| `get_output_style` | no | Read the current output style | | skip: editors for files you own; Drakar opens the files |
| `get_output_style_locations` | no | Where output styles live | | skip: editors for files you own; Drakar opens the files |
| `create_output_style` | no | Create a custom output style | | skip: editors for files you own; Drakar opens the files |
| `set_level` | no | Unclear: 2.1.311 only answers "Levels are not available in this build" | | |

## Memory

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `get_memory_dialog` | partial | Memory dialog, files and auto-memory toggles (Drakar: lists memory files with token counts) | `apps/apple/Drakar/Views/SessionInspector.swift:60` | differ: memory files open as files |
| `open_memory_file` | has | Open a memory file (Drakar: in the default app) | `apps/apple/Drakar/Views/SessionInspector.swift:323` | |
| `open_memory_folder` | partial | Open the memory folder (Drakar: reveals the file in Finder) | `apps/apple/Drakar/Views/SessionInspector.swift:324` | differ: memory files open as files |
| `read_memory_file` | no | Read a memory file into the memory editor | | differ: memory files open as files |
| `write_memory_file` | no | Save an edited memory file | | differ: memory files open as files |
| `delete_memory_file` | no | Delete a memory file | | differ: memory files open as files |
| `save_opened_memory_files` | no | Remember which memory files are open in editors | | differ: memory files open as files |
| `set_memory_setting` | no | Toggle auto-memory and auto-dream | | skip: editors for files you own; Drakar opens the files |

## MCP servers, plugins and skills

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `get_mcp_servers` | has | List MCP servers and their status (Drakar: from a per-project probe, not the live session) | `apps/apple/Drakar/Views/InspectorView.swift:260` | |
| `add_mcp_server` | no | Add an MCP server to the config | | skip: editors for files you own; Drakar opens the files |
| `remove_mcp_server` | no | Remove an MCP server | | skip: editors for files you own; Drakar opens the files |
| `set_mcp_server_enabled` | no | Enable or disable an MCP server | | adopt: a failed server is unfixable without it |
| `reconnect_mcp_server` | no | Reconnect a failed MCP server | | adopt: a failed server is unfixable without it |
| `authenticate_mcp_server` | no | Run OAuth sign-in for an MCP server | | adopt: MCP sign-in |
| `clear_mcp_server_auth` | no | Forget an MCP server's stored auth | | adopt: MCP sign-in |
| `submit_mcp_oauth_callback_url` | no | Paste an MCP OAuth callback URL by hand | | adopt: MCP sign-in |
| `get_skills_dialog` | has | Skills dialog listing available skills | `apps/apple/Drakar/Views/SkillsWindow.swift:79` | |
| `set_skill_state` | no | Set a skill on, off or name-only | | adopt later: after the Skills manager |
| `list_plugins` | no | List installed and available plugins | | adopt later: after the Skills manager |
| `install_plugin` | no | Install a plugin | | adopt later: after the Skills manager |
| `uninstall_plugin` | no | Uninstall a plugin | | adopt later: after the Skills manager |
| `update_plugin` | no | Update a plugin | | adopt later: after the Skills manager |
| `set_plugin_enabled` | no | Enable or disable a plugin | | adopt later: after the Skills manager |
| `reload_plugins` | no | Reload plugins into the running session | | adopt later: after the Skills manager |
| `get_plugin_options` | no | Read a plugin's configurable options | | adopt later: after the Skills manager |
| `save_plugin_options` | no | Save a plugin's options | | adopt later: after the Skills manager |
| `list_marketplaces` | no | List plugin marketplaces | | adopt later: after the Skills manager |
| `add_marketplace` | no | Add a plugin marketplace | | adopt later: after the Skills manager |
| `remove_marketplace` | no | Remove a plugin marketplace | | adopt later: after the Skills manager |
| `refresh_marketplace` | no | Refresh a marketplace's plugin list | | adopt later: after the Skills manager |
| `find_link_marketplace` | no | Resolve a pasted source link to a marketplace | | adopt later: after the Skills manager |
| `engine_ui_panes` | no | List the plugin UI panes the CLI renders (mods) | | skip for now: mods |
| `engine_ui_attach` | no | Attach to the plugin UI surfaces the CLI renders | | skip for now: mods |
| `engine_ui_detach` | no | Detach from the plugin UI surfaces the CLI renders | | skip for now: mods |
| `engine_ui_render` | no | Render a plugin UI component through the CLI | | skip for now: mods |
| `engine_ui_input` | no | Send text input to a CLI-rendered plugin component | | skip for now: mods |
| `engine_ui_press` | no | Press a control in a CLI-rendered plugin UI | | skip for now: mods |
| `engine_ui_select` | no | Pick a value in a CLI-rendered plugin UI | | skip for now: mods |
| `engine_ui_pane_action` | no | Act on a plugin UI pane, such as closing it | | skip for now: mods |
| `engine_ui_state` | no | Plugin UI state sync (payload not traced) | | skip for now: mods |

## Account and usage

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `get_usage` | has | Plan usage limits, 5-hour and 7-day windows | `apps/apple/Drakar/Views/AccountToolbarItem.swift:40` | |
| `open_account_usage` | has | Show detailed account usage (Drakar: toolbar popover) | `apps/apple/Drakar/Views/AccountToolbarItem.swift:120` | |
| `request_usage_update` | partial | Refresh the usage figures (Drakar: updated passively from rate-limit events) | `apps/apple/Drakar/Services/AgentSession.swift:1428` | differ: refreshed without asking |
| `request_admin_limit_increase` | no | Ask an org admin to raise the usage limit | | skip: accounts are `CLAUDE_CONFIG_DIR` and `/login` |
| `sign_out` | no | Sign out of Claude | | skip: accounts are `CLAUDE_CONFIG_DIR` and `/login` |
| `submit_oauth_code` | no | Paste the Claude login code | | skip: accounts are `CLAUDE_CONFIG_DIR` and `/login` |
| `submit_feedback` | no | Send feedback or a bug report | | skip: Anthropic's feedback channel for its own UI |
| `reveal_feedback_report` | no | Reveal a saved feedback report file | | skip: Anthropic's feedback channel for its own UI |
| `open_help` | no | Open the extension's docs page | | skip: the extension's own chrome |
| `dismiss_onboarding` | no | Hide the onboarding tips | | skip: the extension's own chrome |
| `dismiss_review_upsell_banner` | no | Hide the code-review upsell banner | | skip: the extension's own chrome |

## Cloud sessions and integrations

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `list_remote_sessions` | no | List cloud (claude.ai) sessions | | skip: Drakar stays local |
| `teleport_session` | no | Pull a cloud session into the local workspace | | skip: Drakar stays local |
| `check_git_status` | no | Check the working tree is clean before a teleport checkout | | skip: Drakar stays local |
| `checkout_branch` | no | Check out a teleported session's branch | | skip: Drakar stays local |
| `update_skipped_branch` | no | Record a branch skipped during teleport | | skip: Drakar stays local |
| `toggle_remote_control` | no | Let the session be driven remotely from claude.ai | | adopt: Remote Control only, no teleport |
| `refresh_remote_control_lock` | no | Read the policy lock on remote control | | adopt: Remote Control only, no teleport |
| `open_terminal` | no | Open a collaborator's tmux session in a terminal | | skip: no terminal panel |
| `get_chrome_dialog` | no | Load the Claude in Chrome settings dialog | | skip: tied to VS Code or Chrome |
| `get_chrome_browsers` | no | List Chrome browsers for the integration | | skip: tied to VS Code or Chrome |
| `select_chrome_browser` | no | Choose the Chrome browser for the integration | | skip: tied to VS Code or Chrome |
| `set_chrome_setting` | no | Change a Claude in Chrome setting | | skip: tied to VS Code or Chrome |
| `ensure_chrome_mcp_enabled` | no | Turn on the Chrome integration before a browser task | | skip: tied to VS Code or Chrome |
| `disable_chrome_mcp` | no | Turn off the Claude in Chrome integration | | skip: tied to VS Code or Chrome |
| `create_new_browser_tab` | no | Open a new Chrome tab for browser tasks | | skip: tied to VS Code or Chrome |
| `enable_jupyter_mcp` | no | Turn on the Jupyter notebook MCP integration | | skip: tied to VS Code or Chrome |
| `disable_jupyter_mcp` | no | Turn off the Jupyter notebook MCP integration | | skip: tied to VS Code or Chrome |
| `get_design_login_dialog` | no | Load the Claude Design sign-in dialog | | skip: tied to VS Code or Chrome |
| `design_login_start` | no | Start the Claude Design sign-in in the browser | | skip: tied to VS Code or Chrome |
| `design_login_code` | no | Submit the Claude Design sign-in code | | skip: tied to VS Code or Chrome |
| `design_login_wait` | no | Wait for the Claude Design sign-in to finish | | skip: tied to VS Code or Chrome |
| `design_login_cancel` | no | Cancel the Claude Design sign-in | | skip: tied to VS Code or Chrome |

## Webview plumbing

| request | status | what | evidence | decision |
| --- | --- | --- | --- | --- |
| `io_message` | n/a | Stream-json transport between the webview and the CLI | | |
| `get_claude_state` | n/a | Bootstrap host state for the webview (auth, config) | | |
| `await_config_home_request` | n/a | Wait for the CLI's auth and config probe to settle | | |
| `cancel_request` | n/a | Cancel an outstanding webview request | | |
| `get_asset_uris` | n/a | Webview asset URIs | | |
| `webview_focused` | n/a | Webview focus notice | | |
| `log_event` | n/a | Telemetry | | |
| `open_output_panel` | n/a | VS Code's output panel | | |
| `update_session_state` | n/a | Report a session's state and title to the host (a no-op in VS Code) | | |
| `update_panel_host_session` | n/a | Tell the panel host a teleport resolved (a no-op in VS Code) | | |
| `dismiss_terminal_banner` | n/a | Hide the banner about VS Code's "use the terminal" setting | | |
| `show_claude_terminal_setting` | n/a | Open VS Code's "use the terminal" setting | | |

## CLI control requests

What `claude` accepts on stdin as a `control_request`, read from the Agent SDK bundled in
`extension.js` (2.1.311). **Used by** names the webview requests whose handler sends it,
traced through `….query.<method>(` calls; "unused" means the extension never calls the SDK
method, so the CLI can do it but the extension does not expose it. Status here is `sends`
(Drakar sends it, in `ClientMessage.swift`) or `no`. Drakar also sends `initialize`, which
the SDK sends outside this path.

| request | status | used by | notes | decision |
| --- | --- | --- | --- | --- |
| `apply_flag_settings` | sends | `launch_claude` | Focus view at launch; Drakar sends the effort level with it | |
| `background_tasks` | sends | `run_in_background` | | |
| `cancel_async_message` | sends | unused | Drakar cancels a queued prompt with it | |
| `channel_enable` | no | unused | SDK `enableChannel` | |
| `claim_session` | no | unused | SDK `claimSession` | |
| `claude_authenticate` | no | sign-in | Starts the Claude login, returns its URLs | |
| `claude_oauth_callback` | no | `submit_oauth_code` | | |
| `claude_oauth_wait_for_completion` | no | sign-in | | |
| `export_conversation` | no | `export_conversation`, `open_export_document` | | |
| `generate_session_title` | no | `generate_session_title` | | |
| `get_chrome_browsers` | no | `get_chrome_browsers` | | |
| `get_chrome_dialog` | no | `get_chrome_dialog`, `set_chrome_setting` | | |
| `get_context_usage` | sends | `get_context_usage` | | |
| `get_hooks_listing` | no | `get_hooks_listing`, `edit_hook` | | |
| `get_memory_dialog` | no | `get_memory_dialog`, `set_memory_setting` | | |
| `get_plan` | sends | `open_plan` | | |
| `get_sandbox_dialog` | no | `get_sandbox_dialog`, `set_sandbox_setting` | | |
| `get_settings` | sends | `get_applied_settings`, `get_output_style`, `refresh_claude_settings`, `refresh_remote_control_lock` | | |
| `get_skills_dialog` | no | `get_skills_dialog`, `set_skill_state` | | |
| `get_status` | no | `get_status` | | |
| `get_task_output` | sends | `get_task_output` | fallback only: Drakar reads the task's output file when its path is known | |
| `get_usage` | no | `get_usage` | The SDK names its method `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` | |
| `interrupt` | sends | `interrupt_claude` | | |
| `list_permission_rules` | sends | `list_permission_rules`, `add_permission_rules`, `remove_permission_rule` | Rules are added and removed through `claude edit-permission-rules`, as the extension does | |
| `mcp_authenticate` | no | `authenticate_mcp_server` | | |
| `mcp_clear_auth` | no | `clear_mcp_server_auth` | | |
| `mcp_oauth_callback_url` | no | `submit_mcp_oauth_callback_url` | | |
| `mcp_read_resource` | no | unused | | |
| `mcp_reconnect` | no | `reconnect_mcp_server` | | |
| `mcp_set_servers` | no | host `setChannelMcpServers` | Replaces the session's SDK MCP servers; which requests reach it was not traced | |
| `mcp_status` | sends | `get_mcp_servers`, `authenticate_mcp_server`, `clear_mcp_server_auth` | | |
| `mcp_toggle` | no | `set_mcp_server_enabled` | | |
| `message_rated` | no | `message_rated` | | |
| `read_file` | no | unused | | |
| `reload_output_styles` | no | `create_output_style` | | |
| `reload_plugins` | no | `reload_plugins` | | |
| `reload_skills` | no | unused | | |
| `remote_control` | no | `toggle_remote_control` | | |
| `rename_session` | sends | `rename_session` | | |
| `rewind_files` | sends | `rewind_code` | Takes a `user_message_id` and `dry_run`; `ClientMessage.rewindFiles` (`apps/apple/Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift:56`) | |
| `seed_read_state` | no | unused | | |
| `select_chrome_browser` | no | `select_chrome_browser` | | |
| `set_chrome_browser_hints` | no | unused | | |
| `set_cwd` | no | unused | | |
| `set_max_thinking_tokens` | no | `set_thinking_level` | | |
| `set_mcp_permission_mode_override` | no | `ensure_chrome_mcp_enabled` | | |
| `set_model` | sends | `set_model` | | |
| `set_permission_mode` | sends | `set_permission_mode` | | |
| `set_prompt_suggestions_paused` | no | unused | | |
| `side_question` | no | `side_question` | | |
| `stop_task` | sends | `stop_subagent` | Takes a `task_id` | |
| `submit_feedback` | no | `submit_feedback` | | |
| `submit_survey_feedback` | no | `submit_feedback` | | |
| `ultrareview_launch` | no | unused | | |
| `update_settings` | no | effort | Saves the effort level to user settings (host `saveEffortLevelThroughCli`) | |
