import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file or an image sent with a prompt, as the extension sends one (webview 2.1.289): an
/// `image` block, or a `document` holding a PDF or a text file's text, ahead of the
/// prompt's own text (docs/claude-stream-json.md, "Attachments").
public struct Attachment: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: Codable, Sendable, Equatable, Hashable { case image, pdf, text }

  public let id = UUID()
  public var kind: Kind { preview.kind }
  /// What goes on stdin.
  public let block: JSONValue
  /// What the composer and the transcript show of it.
  public let preview: AttachmentPreview

  /// Without `id`: a decoded attachment is a new one in the composer's eyes.
  private enum CodingKeys: CodingKey { case block, preview }

  /// The API's own limits, with room to spare: 2000 pixels on the long edge keeps a request
  /// of several images valid, and its 5 MB a base64 image takes leaves this much raw.
  static let maxImageEdge = 2000
  static let maxImageBytes = 3_500_000
  static let maxTextBytes = 1_000_000
  /// Base64 grows a file by a third, and a request stops at 32 MB.
  static let maxPDFBytes = 22_000_000
  /// The image formats the API takes; anything else is converted to PNG.
  static let sendableImageTypes: Set<String> = [
    UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier,
  ]

  init(block: JSONValue, preview: AttachmentPreview) {
    self.block = block
    self.preview = preview
  }

  /// An image's bytes in any format ImageIO reads (a pasted screenshot is TIFF), sent as it
  /// is when the API takes it as it is, else scaled down and re-encoded.
  public static func image(_ data: Data, name: String?) throws(AttachmentError) -> Attachment {
    let label = name ?? String(localized: "Image")
    guard !data.isEmpty else { throw .empty(label) }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?,
      CGImageSourceGetCount(source) > 0
    else { throw .unsupported(label) }
    let (width, height) = pixelSize(source)
    // As it is only when its size reads and its colours are RGB or grey: a print-ready
    // CMYK JPEG is converted.
    let fits =
      sendableImageTypes.contains(type) && width > 0 && height > 0
      && max(width, height) <= maxImageEdge && data.count <= maxImageBytes
      && [kCGImagePropertyColorModelRGB, kCGImagePropertyColorModelGray].contains(
        colorModel(source))
    let (bytes, mediaType): (Data, String)
    if fits, let mime = UTType(type)?.preferredMIMEType {
      (bytes, mediaType) = (data, mime)
    } else {
      guard let scaled = scaledDown(source) else { throw .unsupported(label) }
      (bytes, mediaType) = scaled
    }
    let block: JSONValue = .object([
      "type": .string("image"),
      "source": .object([
        "type": .string("base64"), "media_type": .string(mediaType),
        "data": .string(bytes.base64EncodedString()),
      ]),
    ])
    return Attachment(
      block: block,
      preview: AttachmentPreview(kind: .image, name: name, thumbnail: thumbnail(source)))
  }

  /// A file: an image, a PDF, or text (by its type, or by reading as UTF-8 without a NUL,
  /// which covers a `Makefile` or a `README`).
  public static func file(at url: URL) throws(AttachmentError) -> Attachment {
    let name = url.lastPathComponent
    guard let data = try? Data(contentsOf: url) else { throw .unreadable(name) }
    guard !data.isEmpty else { throw .empty(name) }
    let type = UTType(filenameExtension: url.pathExtension)
    if type?.conforms(to: .image) == true { return try image(data, name: name) }
    if type?.conforms(to: .pdf) == true {
      guard data.count <= maxPDFBytes else { throw .tooLarge(name) }
      return Attachment(
        block: .object([
          "type": .string("document"), "title": .string(name),
          "source": .object([
            "type": .string("base64"), "media_type": .string("application/pdf"),
            "data": .string(data.base64EncodedString()),
          ]),
        ]),
        preview: AttachmentPreview(kind: .pdf, name: name, thumbnail: nil))
    }
    guard type?.conforms(to: .text) == true || isText(data) else { throw .unsupported(name) }
    guard data.count <= maxTextBytes else { throw .tooLarge(name) }
    guard let text = String(data: data, encoding: .utf8) else { throw .unsupported(name) }
    return Attachment(
      block: .object([
        "type": .string("document"), "title": .string(name),
        "source": .object([
          "type": .string("text"), "media_type": .string("text/plain"), "data": .string(text),
        ]),
      ]),
      preview: AttachmentPreview(kind: .text, name: name, thumbnail: nil))
  }

  private static func isText(_ data: Data) -> Bool {
    !data.prefix(8192).contains(0) && String(data: data, encoding: .utf8) != nil
  }

  private static func colorModel(_ source: CGImageSource) -> CFString? {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return properties?[kCGImagePropertyColorModel] as? String as CFString?
  }

  private static func pixelSize(_ source: CGImageSource) -> (Int, Int) {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (
      properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
      properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    )
  }

  /// At most `maxImageEdge` on the long edge, upright: PNG, or JPEG when the PNG is too big.
  private static func scaledDown(_ source: CGImageSource) -> (Data, String)? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let image = inSRGB(thumbnail)
    else { return nil }
    if let png = encode(image, as: .png), png.count <= maxImageBytes { return (png, "image/png") }
    guard let jpeg = encode(image, as: .jpeg, quality: 0.85) else { return nil }
    return (jpeg, "image/jpeg")
  }

  /// Redrawn in sRGB unless it is RGB already, which a CMYK image is not.
  private static func inSRGB(_ image: CGImage) -> CGImage? {
    guard image.colorSpace?.model != .rgb else { return image }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  static func thumbnail(_ source: CGImageSource) -> Data? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 256,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap {
      encode($0, as: .png)
    }
  }

  private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, type.identifier as CFString, 1, nil)
    else { return nil }
    let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

/// What is shown of an attachment, in the composer and on its prompt: a small PNG of an
/// image, a document's name.
public struct AttachmentPreview: Codable, Sendable, Equatable, Hashable {
  public var kind: Attachment.Kind
  public var name: String?
  /// At most 256 pixels on the long edge; nil for a document.
  public var thumbnail: Data?

  public init(kind: Attachment.Kind, name: String?, thumbnail: Data?) {
    self.kind = kind
    self.name = name
    self.thumbnail = thumbnail
  }

  /// A prompt's `image` or `document` block, as a transcript file keeps it.
  init?(block: JSONValue) {
    let source = block["source"]
    switch block["type"]?.stringValue {
    case "image":
      let data = source?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
      let image = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
      self.init(kind: .image, name: nil, thumbnail: image.flatMap(Attachment.thumbnail))
    case "document":
      let isPDF = source?["media_type"]?.stringValue == "application/pdf"
      self.init(
        kind: isPDF ? .pdf : .text, name: block["title"]?.stringValue, thumbnail: nil)
    default: return nil
    }
  }
}

/// Why a file was not attached, in the extension's words where it has them.
public enum AttachmentError: Error, Equatable, Sendable {
  case unsupported(String)
  case empty(String)
  case tooLarge(String)
  case unreadable(String)

  public var message: String {
    switch self {
    case .unsupported(let name): String(localized: "Unsupported file: \(name)")
    case .empty(let name): String(localized: "Empty file skipped: \(name)")
    case .tooLarge(let name): String(localized: "Too large to attach: \(name)")
    case .unreadable(let name): String(localized: "Could not read \(name)")
    }
  }
}
