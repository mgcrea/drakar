import CoreServices
import Foundation

/// Every change under a folder, file by file, through FSEvents: the agent's edits, a git
/// checkout, another editor. Delivered on the main queue, coalesced over 0.3 s.
///
/// Paths arrive as the kernel names them, symbolic links resolved: a folder under `/tmp`
/// reports as `/private/tmp/...`. `Workspace` maps them back to the path it opened.
final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let handler: Handler

  private final class Handler {
    let onChange: ([String]) -> Void
    init(_ onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
  }

  init?(folder: URL, onChange: @escaping ([String]) -> Void) {
    handler = Handler(onChange)
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      // The stream is scheduled on the main queue.
      MainActor.assumeIsolated {
        Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange(changed)
      }
    }
    let flags =
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
      | kFSEventStreamCreateFlagNoDefer
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [folder.path(percentEncoded: false)] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(flags))
    else { return nil }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  isolated deinit {
    stop()
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
