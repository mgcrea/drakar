/// What ⌘W closes in a project window (session tabs spec, "⌘W and keys"): the editor's file
/// while the editor has the keys and a file is open; else the session tab shown; else, with
/// no tab left, the window.
enum CloseTarget: Equatable {
  case document, tab, window

  static func resolve(
    focusedPane: FocusedPane?, hasActiveDocument: Bool, hasSelectedTab: Bool
  ) -> CloseTarget {
    if focusedPane == .editor, hasActiveDocument { return .document }
    return hasSelectedTab ? .tab : .window
  }
}
