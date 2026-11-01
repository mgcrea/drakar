import Foundation

/// Folders handed to Drakar from outside: the `drakar` command, `open -a Drakar <folder>`,
/// a folder dropped on the Dock icon. Each goes on home and opens as a project. One that
/// arrives before any window can open a window (a launch by `drakar <folder>`) waits: the
/// first window home would show becomes it, and the rest open once a window is up.
@MainActor
final class FolderIntake {
  static let shared = FolderIntake()

  private let list: ProjectList
  private var pending: [URL] = []
  /// Set once the first window has taken what was waiting: before that, a folder waits too,
  /// even when a window could already open one, so that window becomes it rather than a
  /// tab opening beside an empty home.
  var isReady = false

  init(list: ProjectList = .shared) {
    self.list = list
  }

  /// The folders among `urls`, tracked and opened through `open`; kept for the first
  /// window when `open` is nil. A file or a missing path is left out.
  func receive(_ urls: [URL], open: ((URL) -> Void)?) {
    let folders = urls.filter { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    for folder in folders {
      list.track(folder)
      if let open { open(folder) } else { pending.append(folder) }
    }
  }

  /// The first waiting folder, for a home window appearing: it becomes that project.
  func takeFirst() -> URL? {
    pending.isEmpty ? nil : pending.removeFirst()
  }

  /// Every folder still waiting, once a window can open them.
  func flush(open: (URL) -> Void) {
    let waiting = pending
    pending = []
    waiting.forEach(open)
  }
}
