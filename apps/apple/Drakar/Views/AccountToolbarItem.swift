import DrakarKit
import SwiftUI

extension AccountStore {
  /// The account new Claude Code sessions in `folder` start under, as the toolbar names it.
  func windowAccount(for folder: URL) -> ClaudeAccount {
    ClaudeChoice.account(forNewSessionIn: folder) ?? shellAccount
  }

  /// `account` as `folder`'s pick, unless the window already runs on it: clicking the checked
  /// row must not tie a folder that follows Settings to today's Settings.
  func pick(_ account: ClaudeAccount, for folder: URL) {
    guard account.key != windowAccount(for: folder).key else { return }
    ClaudeChoice.pick(account, for: folder)
  }

  /// `agent` as `folder`'s pick, unless the folder already runs on it.
  func pick(_ agent: AgentKind, for folder: URL) {
    guard agent != ClaudeChoice.agent(forNewSessionIn: folder) else { return }
    ClaudeChoice.pick(agent, for: folder)
  }
}

/// The window's active agent, account, and plan usage, on the right of the toolbar. A click
/// switches between Claude Code accounts, Codex, and Antigravity for this folder's new
/// sessions.
struct AccountToolbarItem: View {
  let folder: URL
  /// Called after picking an agent, so a fresh unstarted tab in this window can switch in place.
  var onPickAgent: ((AgentKind) -> Void)? = nil
  @State private var isShown = false
  /// Read only to redraw when a pick or a Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""
  @AppStorage(PreferenceKey.agentForFolder) private var agentPicks = ""
  @AppStorage(PreferenceKey.defaultAgent) private var defaultAgentRaw = AgentKind.claude.rawValue

  private var store: AccountStore { .shared }

  var body: some View {
    let _ = (picks, settingsAccount, agentPicks, defaultAgentRaw)
    let activeAgent = ClaudeChoice.agent(forNewSessionIn: folder)
    let account = store.windowAccount(for: folder)
    Button {
      Task { await store.reloadChanged() }
      store.probeAgyIfNeeded()
      store.probeGrokIfNeeded()
      isShown.toggle()
    } label: {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        switch activeAgent {
        case .claude:
          HStack(spacing: 6) {
            AgentIcon(agent: .claude)
            Text(store.profile(for: account).name)
            UsageMeters(usage: store.usage(for: account), now: context.date, compact: true)
          }
        case .codex:
          HStack(spacing: 6) {
            AgentIcon(agent: .codex)
            Text(AgentKind.codex.name)
            UsageMeters(usage: store.codexUsage?.usage, now: context.date, compact: true)
          }
        case .grok:
          HStack(spacing: 6) {
            AgentIcon(agent: .grok)
            Text(AgentKind.grok.name)
            GrokUsageMeters(usage: store.grokUsage, now: context.date, compact: true)
          }
        case .agy:
          HStack(spacing: 6) {
            AgentIcon(agent: .agy)
            Text(AgentKind.agy.name)
            UsageMeters(
              usage: store.agyUsage?.summary(at: context.date), now: context.date, compact: true)
          }
        }
      }
    }
    .help(help(for: activeAgent, account: account))
    .accessibilityIdentifier("window.account")
    .popover(isPresented: $isShown, arrowEdge: .bottom) {
      AccountPicker(
        folder: folder, activeAgent: activeAgent, current: account,
        onPickAgent: onPickAgent
      ) { isShown = false }
    }
  }

  private func help(for agent: AgentKind, account: ClaudeAccount) -> String {
    let now = Date.now
    switch agent {
    case .claude:
      let profile = store.profile(for: account)
      var parts = [
        [profile.name, profile.plan].compactMap { $0 }.joined(separator: " · ") + " — "
          + ContentView.abbreviated(account.directory)
      ]
      if let usage = store.usage(for: account) {
        for (label, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
          guard let window = window?.current(at: now) else { continue }
          parts.append(UsageMeters.helpText(label, window))
        }
        parts.append(
          String(localized: "updated \(usage.readAt.formatted(.relative(presentation: .named)))"))
      }
      return parts.joined(separator: " · ")

    case .codex:
      guard let codex = store.codexUsage else {
        return String(localized: "New sessions in this folder run \(agent.name)")
      }
      var parts = [
        [agent.name, codex.plan].compactMap { $0 }.joined(separator: " · ") + " — "
          + ContentView.abbreviated(store.codexHome)
      ]
      for (label, window) in [("5h", codex.usage.fiveHour), ("7d", codex.usage.sevenDay)] {
        guard let window = window?.current(at: now) else { continue }
        parts.append(UsageMeters.helpText(label, window))
      }
      let relative = codex.usage.readAt.formatted(.relative(presentation: .named))
      parts.append(
        codex.usage.source == .sessionLog
          ? String(localized: "last turn \(relative)")
          : String(localized: "updated \(relative)"))
      return parts.joined(separator: " · ")

    case .grok:
      guard let grok = store.grokUsage else {
        return String(localized: "New sessions in this folder run \(agent.name)")
      }
      var parts = [
        [agent.name, grok.plan].compactMap { $0 }.joined(separator: " · ") + " — "
          + ContentView.abbreviated(store.grokHome)
      ]
      let window = grok.window.current(at: now)
      let label = grok.shortLabel ?? String(localized: "plan")
      parts.append(UsageMeters.helpText(label, window))
      parts.append(
        String(localized: "updated \(grok.readAt.formatted(.relative(presentation: .named)))"))
      return parts.joined(separator: " · ")
    case .agy:
      guard let agy = store.agyUsage else {
        return String(localized: "New sessions in this folder run \(agent.name)")
      }
      let home = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".gemini/antigravity-cli", directoryHint: .isDirectory)
      var parts = [
        [agent.name, agy.plan].compactMap { $0 }.joined(separator: " · ") + " — "
          + ContentView.abbreviated(home)
      ]
      let groups = agy.groups
      for group in groups {
        for (short, raw) in [("5h", group.fiveHour), ("7d", group.sevenDay)] {
          guard let window = raw?.current(at: now) else { continue }
          let label = groups.count > 1 ? "\(group.name) \(short)" : short
          parts.append(UsageMeters.helpText(label, window))
        }
      }
      parts.append(
        String(localized: "updated \(agy.readAt.formatted(.relative(presentation: .named)))"))
      return parts.joined(separator: " · ")
    }
  }
}

/// A runner window's place for the account (remote sessions spec §4): the runner, and the
/// limits of the account the shown session runs under there, as its own process reported
/// them, from the session and never from this Mac's `AccountStore`. No picker: a runner
/// session runs under the runner shell's own account (Ruling 11).
struct RunnerToolbarItem: View {
  let name: String
  let session: AgentSession?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      HStack(spacing: 6) {
        Image(systemName: "desktopcomputer.and.macbook")
        Text(name)
        UsageMeters(usage: session?.usage, now: context.date, compact: true)
      }
    }
    .help(help)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("window.runner")
  }

  private var help: String {
    var parts = [String(localized: "Sessions here run on \(name), under the account of its shell")]
    if let account = session?.account {
      parts.append(account.directory.path(percentEncoded: false))
    }
    let now = Date.now
    if let usage = session?.usage {
      for (label, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
        guard let window = window?.current(at: now) else { continue }
        parts.append(UsageMeters.helpText(label, window))
      }
      parts.append(
        String(
          localized:
            "as this session reported \(usage.readAt.formatted(.relative(presentation: .named)))"))
    }
    return parts.joined(separator: " · ")
  }
}

/// Every Claude Code account with its limits, plus Codex and Antigravity with theirs; a click
/// picks the agent (and account) for this folder.
private struct AccountPicker: View {
  let folder: URL
  let activeAgent: AgentKind
  let current: ClaudeAccount
  let onPickAgent: ((AgentKind) -> Void)?
  let dismiss: () -> Void
  @State private var codexPath: String?
  @State private var grokPath: String?
  @State private var agyPath: String?

  private var store: AccountStore { .shared }

  var body: some View {
    let accounts = store.accounts.isEmpty ? [store.shellAccount] : store.accounts
    VStack(alignment: .leading, spacing: 0) {
      ForEach(accounts, id: \.key) { account in
        Button {
          let previousAccount = store.windowAccount(for: folder)
          let wasClaude = activeAgent == .claude
          store.pick(.claude, for: folder)
          store.pick(account, for: folder)
          onPickAgent?(.claude)
          dismiss()
          if wasClaude, account.key != previousAccount.key {
            // After the popover is gone: a modal over an open popover is lost behind it.
            DispatchQueue.main.async {
              SessionMoves.offer(folder: folder, from: previousAccount, to: account)
            }
          }
        } label: {
          accountRow(account)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.row.\(account.directory.lastPathComponent)")
        Divider()
      }
      agentButton(.codex, plan: store.codexUsage?.plan, path: codexPath) {
        if let codex = store.codexUsage {
          UsageMeters(usage: codex.usage, now: .now, compact: false)
            .padding(.leading, 22)
        }
      }
      Divider()
      agentButton(.grok, plan: store.grokUsage?.plan, path: grokPath) {
        if let grok = store.grokUsage {
          GrokUsageMeters(usage: grok, now: .now, compact: false)
            .padding(.leading, 22)
        }
      }
      Divider()
      agentButton(.agy, plan: store.agyUsage?.plan, path: agyPath) {
        if let agy = store.agyUsage {
          AgyUsageMeters(usage: agy, now: .now)
            .padding(.leading, 22)
        }
      }
      Divider()
      Text(
        "New sessions in this folder use the checked agent and account. Existing sessions keep theirs."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
    }
    .frame(width: 340)
    .task {
      let environment = await AgentSession.environment.value
      codexPath = CodexLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
      grokPath = AgyLaunch.locate(path: environment["PATH"], binary: "grok")?.path(
        percentEncoded: false)
      agyPath = AgyLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
    }
  }

  private func accountRow(_ account: ClaudeAccount) -> some View {
    let profile = store.profile(for: account)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "checkmark")
          .opacity(activeAgent == .claude && account.key == current.key ? 1 : 0)
        AgentIcon(agent: .claude).foregroundStyle(.secondary)
        Text([profile.name, profile.plan].compactMap { $0 }.joined(separator: " · "))
          .fontWeight(.medium)
        Spacer()
        Text(ContentView.abbreviated(account.directory))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      UsageMeters(usage: store.usage(for: account), now: .now, compact: false)
        .padding(.leading, 22)
    }
    .padding(10)
    .contentShape(Rectangle())
  }

  private func agentButton<Meters: View>(
    _ agent: AgentKind, plan: String?, path: String?,
    @ViewBuilder meters: () -> Meters
  ) -> some View {
    Button {
      store.pick(agent, for: folder)
      onPickAgent?(agent)
      dismiss()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: "checkmark").opacity(activeAgent == agent ? 1 : 0)
          AgentIcon(agent: agent).foregroundStyle(.secondary)
          Text([agent.name, plan].compactMap { $0 }.joined(separator: " · "))
            .fontWeight(.medium)
          Spacer()
          Text(
            path.map { ContentView.abbreviated(URL(filePath: $0)) }
              ?? String(localized: "Not found")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        meters()
      }
      .padding(10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("account.row.\(agent.rawValue)")
  }
}

/// The 5h and 7d bars: compact in the toolbar, with their reset times in the popover.
struct UsageMeters: View {
  let usage: AccountUsage?
  let now: Date
  let compact: Bool

  var body: some View {
    if let usage {
      let layout =
        compact
        ? AnyLayout(HStackLayout(spacing: 8))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
      layout {
        ForEach([("5h", usage.fiveHour), ("7d", usage.sevenDay)], id: \.0) { entry in
          if let window = entry.1?.current(at: now) {
            UsageWindowRow(label: entry.0, window: window, compact: compact)
          }
        }
      }
      .font(compact ? .caption : .callout)
      .opacity(usage.isStale(at: now) ? 0.5 : 1)
    }
  }

  /// `5h resets 12:30`, `Limit reached — resets 12:30`; a reset beyond today names its day.
  static func resetText(_ label: String?, _ window: UsageWindow) -> String {
    guard let resetsAt = window.resetsAt else { return label ?? "" }
    let time =
      Calendar.current.isDateInToday(resetsAt)
      ? resetsAt.formatted(date: .omitted, time: .shortened)
      : resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    if window.isRejected { return String(localized: "Limit reached — resets \(time)") }
    return [label, String(localized: "resets \(time)")].compactMap { $0 }.joined(separator: " ")
  }

  /// Tooltip segment for one window: `5h resets 12:30`, or `5h 0%` when the window has no
  /// reset time yet (e.g. an untouched Antigravity pool or a rolled-over window).
  static func helpText(_ label: String, _ window: UsageWindow) -> String {
    guard window.resetsAt != nil else {
      return window.isRejected ? "\(label) 100%" : "\(label) \(window.percent)%"
    }
    return resetText(label, window)
  }
}

/// Antigravity's model-pool quota buckets (`Gemini`, `Partner models`, …) in the popover.
private struct AgyUsageMeters: View {
  let usage: AgyUsage?
  let now: Date

  var body: some View {
    if let usage {
      let groups = usage.groups
      if !groups.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: 3) {
              if groups.count > 1 {
                Text(group.name)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              ForEach([("5h", group.fiveHour), ("7d", group.sevenDay)], id: \.0) { entry in
                if let window = entry.1?.current(at: now) {
                  UsageWindowRow(label: entry.0, window: window, compact: false)
                }
              }
            }
          }
        }
        .font(.callout)
        .opacity(usage.isStale(at: now) ? 0.5 : 1)
      }
    }
  }
}

/// Grok Build's single allowance bar: compact in the toolbar, with period label and reset time
/// in the popover.
private struct GrokUsageMeters: View {
  let usage: GrokUsage?
  let now: Date
  let compact: Bool

  var body: some View {
    if let usage {
      let window = usage.window.current(at: now)
      UsageWindowRow(label: usage.shortLabel ?? "", window: window, compact: compact)
        .font(compact ? .caption : .callout)
        .opacity(usage.isStale(at: now) ? 0.5 : 1)
    }
  }
}

/// One window line: label, bar, percentage, and reset time when expanded.
private struct UsageWindowRow: View {
  let label: String
  let window: UsageWindow
  let compact: Bool

  var body: some View {
    HStack(spacing: 4) {
      if !compact, !label.isEmpty {
        Text(label).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
      }
      UsageBar(window: window).frame(width: compact ? 22 : 120, height: compact ? 4 : 6)
      Text(window.isRejected ? "100%" : "\(window.percent)%").monospacedDigit()
      if !compact { Text(UsageMeters.resetText(nil, window)).foregroundStyle(.secondary) }
    }
  }
}

/// One window's share, tinted green, orange, red; full and red once rejected.
private struct UsageBar: View {
  let window: UsageWindow

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(tint)
          .frame(width: proxy.size.width * CGFloat(window.isRejected ? 100 : window.percent) / 100)
      }
    }
  }

  private var tint: Color {
    switch window.level {
    case .normal: .green
    case .high: .orange
    case .critical: .red
    }
  }
}
