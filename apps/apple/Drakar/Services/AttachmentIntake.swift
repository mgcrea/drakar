import AppKit
import DrakarKit
import OSLog
import UniformTypeIdentifiers

/// What can become an attachment: a file, or an image's bytes (a screenshot on the
/// clipboard, a drag from the screenshot thumbnail or Photos).
enum AttachmentSource: Sendable, Equatable {
  case file(URL)
  case image(Data, name: String?)
}

/// Reads the clipboard and drops into attachments, off the main thread: scaling a 5K
/// screenshot takes a moment.
enum AttachmentIntake {
  private static let log = Logger(subsystem: "io.mgcrea.Drakar", category: "attachments")

  /// What a paste would attach, or nil to let the text field paste as usual: files copied in
  /// the Finder, or an image with no text beside it (a screenshot copied with ⌃⇧⌘4). Rich
  /// text that carries images pastes as text.
  static func sources(in pasteboard: NSPasteboard) -> [AttachmentSource]? {
    let files =
      (pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    let regular = files.filter { !$0.hasDirectoryPath }
    if !regular.isEmpty { return regular.map(AttachmentSource.file) }
    guard pasteboard.string(forType: .string) == nil else { return nil }
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      if let data = pasteboard.data(forType: type) { return [.image(data, name: nil)] }
    }
    return nil
  }

  /// The attachments, and a note for each that could not be read.
  static func load(_ sources: [AttachmentSource]) async -> (
    attachments: [Attachment], notes: [String]
  ) {
    await Task.detached(priority: .userInitiated) {
      var attachments: [Attachment] = []
      var notes: [String] = []
      for source in sources {
        do throws(AttachmentError) {
          switch source {
          case .file(let url): attachments.append(try Attachment.file(at: url))
          case .image(let data, let name):
            attachments.append(try Attachment.image(data, name: name))
          }
        } catch {
          notes.append(error.message)
        }
      }
      return (attachments, notes)
    }.value
  }

  /// The types a drop on the session pane takes. An image dragged from the screenshot
  /// thumbnail or Photos is a file promise, which an item provider fulfils on asking for
  /// the image's file.
  static let dropTypes: [UTType] = [.fileURL, .image]

  /// What the dropped items hold: a file's URL, else an image's file read whole (its
  /// temporary copy is gone once the callback returns).
  static func sources(from providers: [NSItemProvider]) async -> [AttachmentSource] {
    var sources: [AttachmentSource] = []
    for provider in providers {
      log.debug(
        "drop item types: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)"
      )
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
        let url = await fileURL(from: provider)
      {
        sources.append(.file(url))
      } else if let type = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      }), let source = await image(from: provider, type: type) {
        sources.append(source)
      }
    }
    return sources
  }

  private static func fileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url?.isFileURL == true ? url : nil)
      }
    }
  }

  private static func image(from provider: NSItemProvider, type: String) async -> AttachmentSource?
  {
    await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        if let error { log.error("drop not read: \(error.localizedDescription, privacy: .public)") }
        guard let url, let data = try? Data(contentsOf: url) else {
          return continuation.resume(returning: nil)
        }
        continuation.resume(
          returning: .image(data, name: provider.suggestedName ?? url.lastPathComponent))
      }
    }
  }

  /// The Open panel behind the composer's paperclip.
  @MainActor static func choose() -> [AttachmentSource] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .xml]
    panel.prompt = String(localized: "Attach")
    guard panel.runModal() == .OK else { return [] }
    return panel.urls.map(AttachmentSource.file)
  }
}
