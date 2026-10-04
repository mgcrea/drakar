import DrakarKit
import SwiftUI

extension AccountStore {
  /// The account new sessions in `folder` start under, as the toolbar names it.
  func windowAccount(for folder: URL) -> ClaudeAccount {
    ClaudeChoice.account(forNewSessionIn: folder) ?? shellAccount
  }

  /// `account` as `folder`'s pick, unless the window already runs on it: clicking the checked
  /// row must not tie a folder that follows Settings to today's Settings.
  func pick(_ account: ClaudeAccount, for folder: URL) {
    guard account.key != windowAccount(for: folder).key else { return }
    ClaudeChoice.pick(account, for: folder)
  }
}

/// The window's account and its plan usage, on the right of the toolbar. A click lists every
/// account and picks the one this folder's new sessions start under.
struct AccountToolbarItem: View {
  let folder: URL
  @State private var isShown = false
  /// Read only to redraw when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  private var store: AccountStore { .shared }

  var body: some View {
    let _ = (picks, settingsAccount)
    let account = store.windowAccount(for: folder)
    Button {
      store.reloadChanged()
      isShown.toggle()
    } label: {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle")
          Text(store.profile(for: account).name)
          UsageMeters(usage: store.usage(for: account), now: context.date, compact: true)
        }
      }
    }
    .help(help(for: account))
    .accessibilityIdentifier("window.account")
    .popover(isPresented: $isShown, arrowEdge: .bottom) {
      AccountPicker(folder: folder, current: account) { isShown = false }
    }
  }

  private func help(for account: ClaudeAccount) -> String {
    let profile = store.profile(for: account)
    var parts = [
      [profile.name, profile.plan].compactMap { $0 }.joined(separator: " · ") + " — "
        + ContentView.abbreviated(account.directory)
    ]
    let now = Date.now
    if let usage = store.usage(for: account) {
      for (label, window) in [("5h", usage.fiveHour), ("7d", usage.sevenDay)] {
        guard let window = window?.current(at: now) else { continue }
        parts.append(UsageMeters.resetText(label, window))
      }
      parts.append(
        String(localized: "updated \(usage.readAt.formatted(.relative(presentation: .named)))"))
    }
    return parts.joined(separator: " · ")
  }
}

/// Every account with its limits; a click picks it for the folder.
private struct AccountPicker: View {
  let folder: URL
  let current: ClaudeAccount
  let dismiss: () -> Void

  private var store: AccountStore { .shared }

  var body: some View {
    let accounts = store.accounts.isEmpty ? [store.shellAccount] : store.accounts
    VStack(alignment: .leading, spacing: 0) {
      ForEach(accounts, id: \.key) { account in
        Button {
          store.pick(account, for: folder)
          dismiss()
        } label: {
          row(account)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.row.\(account.directory.lastPathComponent)")
        Divider()
      }
      Text("New sessions in this folder use the checked account. Existing sessions keep theirs.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
    }
    .frame(width: 340)
  }

  private func row(_ account: ClaudeAccount) -> some View {
    let profile = store.profile(for: account)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "checkmark").opacity(account.key == current.key ? 1 : 0)
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
            HStack(spacing: 4) {
              if !compact {
                Text(entry.0).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
              }
              UsageBar(window: window).frame(width: compact ? 22 : 120, height: compact ? 4 : 6)
              Text(window.isRejected ? "100%" : "\(window.percent)%").monospacedDigit()
              if !compact { Text(Self.resetText(nil, window)).foregroundStyle(.secondary) }
            }
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
