import CoreGraphics
import DrakarKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Files and images sent with a prompt, as the extension sends them: an `image` block, a
/// `document` holding a PDF or a text file's text, ahead of the prompt's own text.
@Suite("Attachments")
struct AttachmentTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attach-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A plain image, encoded as `type`.
  private func image(width: Int, height: Int, type: UTType = .png) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func pixelSize(_ base64: String) throws -> (Int, Int) {
    let data = try #require(Data(base64Encoded: base64))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (
      properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
      properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    )
  }

  private func write(_ data: Data, _ name: String) throws -> URL {
    let url = folder.appending(path: name)
    try data.write(to: url)
    return url
  }

  @Test func aSmallPNGGoesAsItIs() throws {
    let png = try image(width: 64, height: 64)
    let attachment = try Attachment.image(png, name: "red.png")
    #expect(attachment.kind == .image)
    #expect(attachment.preview.thumbnail != nil)
    #expect(
      attachment.block
        == .object([
          "type": .string("image"),
          "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"),
            "data": .string(png.base64EncodedString()),
          ]),
        ]))
  }

  /// A Retina screenshot is cut down to 2000 pixels on its long edge.
  @Test func aLargeImageIsScaledDown() throws {
    let attachment = try Attachment.image(try image(width: 4000, height: 3000), name: nil)
    guard case .string(let data)? = attachment.block["source"]?["data"] else {
      Issue.record("no data")
      return
    }
    let (width, height) = try pixelSize(data)
    #expect(width == 2000)
    #expect(height == 1500)
  }

  /// What a screenshot copied to the clipboard holds: TIFF, which the API does not take.
  @Test func aTIFFBecomesAPNG() throws {
    let attachment = try Attachment.image(try image(width: 32, height: 32, type: .tiff), name: nil)
    #expect(attachment.block["source"]?["media_type"] == .string("image/png"))
  }

  /// A small screenshot from the clipboard is converted, never blown up to the limit.
  @Test func aSmallImageIsNotScaledUp() throws {
    let attachment = try Attachment.image(
      try image(width: 300, height: 200, type: .tiff), name: nil)
    guard case .string(let data)? = attachment.block["source"]?["data"] else {
      Issue.record("no data")
      return
    }
    let (width, height) = try pixelSize(data)
    #expect(width == 300)
    #expect(height == 200)
    let thumbnail = try #require(attachment.preview.thumbnail)
    let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 256)
    let tiny = try Attachment.image(try image(width: 16, height: 16), name: nil)
    let tinyThumbnail = try #require(tiny.preview.thumbnail)
    let tinySource = try #require(CGImageSourceCreateWithData(tinyThumbnail as CFData, nil))
    let tinyProperties = try #require(
      CGImageSourceCopyPropertiesAtIndex(tinySource, 0, nil) as? [CFString: Any])
    #expect(tinyProperties[kCGImagePropertyPixelWidth] as? Int == 16)
  }

  /// A print-ready CMYK JPEG is made RGB before it goes.
  @Test func aCMYKImageIsReencoded() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(CGColor(genericCMYKCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    let cmyk = try #require(context.makeImage())
    CGImageDestinationAddImage(destination, cmyk, nil)
    #expect(CGImageDestinationFinalize(destination))
    let attachment = try Attachment.image(data as Data, name: "print.jpg")
    #expect(attachment.block["source"]?["media_type"] == .string("image/png"))
  }

  @Test func aTextFileGoesAsItsText() throws {
    let url = try write(Data("The secret word is ptarmigan.".utf8), "notes.txt")
    let attachment = try Attachment.file(at: url)
    #expect(attachment.kind == .text)
    #expect(attachment.preview.name == "notes.txt")
    #expect(
      attachment.block
        == .object([
          "type": .string("document"), "title": .string("notes.txt"),
          "source": .object([
            "type": .string("text"), "media_type": .string("text/plain"),
            "data": .string("The secret word is ptarmigan."),
          ]),
        ]))
  }

  /// No extension, but text all the same.
  @Test func aMakefileIsText() throws {
    let url = try write(Data("build:\n\tswift build\n".utf8), "Makefile")
    #expect(try Attachment.file(at: url).kind == .text)
  }

  @Test func aPDFGoesAsADocument() throws {
    let pdf = Data("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8)
    let attachment = try Attachment.file(at: try write(pdf, "spec.pdf"))
    #expect(attachment.kind == .pdf)
    #expect(
      attachment.block
        == .object([
          "type": .string("document"), "title": .string("spec.pdf"),
          "source": .object([
            "type": .string("base64"), "media_type": .string("application/pdf"),
            "data": .string(pdf.base64EncodedString()),
          ]),
        ]))
  }

  @Test func refusesWhatItCannotSend() throws {
    #expect(throws: AttachmentError.unsupported("blob.bin")) {
      try Attachment.file(at: try write(Data([0, 1, 2, 0, 255]), "blob.bin"))
    }
    #expect(throws: AttachmentError.empty("empty.txt")) {
      try Attachment.file(at: try write(Data(), "empty.txt"))
    }
    #expect(throws: AttachmentError.tooLarge("big.txt")) {
      try Attachment.file(at: try write(Data(repeating: 65, count: 1_100_000), "big.txt"))
    }
    #expect(AttachmentError.empty("empty.txt").message == "Empty file skipped: empty.txt")
  }

  /// Context, then attachments, then the text; a prompt of attachments alone has no text.
  @Test func goesAheadOfThePromptsText() throws {
    let image = try Attachment.image(try image(width: 8, height: 8), name: nil)
    let message = ClientMessage.prompt(
      "What is this?", context: ["<ide_selection>x</ide_selection>"], attachments: [image.block])
    let content = try #require(message.json["message"]?["content"]?.arrayValue)
    #expect(content.map { $0["type"]?.stringValue } == ["text", "image", "text"])
    #expect(content.last?["text"] == .string("What is this?"))
    let bare = ClientMessage.prompt("", attachments: [image.block])
    #expect(
      bare.json["message"]?["content"]?.arrayValue?.map { $0["type"]?.stringValue } == ["image"])
  }

  /// The captured transcript line: an image, a text document, then the prompt.
  @Test func historyShowsAPromptsAttachments() throws {
    let transcript = Transcript.history(lines: try Fixture.historyWithAttachments.lines)
    let prompt = try #require(transcript.entries.first { $0.isPromptEntry })
    #expect(prompt.attachments.map(\.kind) == [.image, .text])
    #expect(prompt.attachments.first?.thumbnail != nil)
    #expect(prompt.attachments.last?.name == "notes.txt")
  }

  @Test func aLivePromptKeepsItsPreviews() throws {
    let image = try Attachment.image(try image(width: 8, height: 8), name: "dot.png")
    var transcript = Transcript()
    transcript.addPrompt("Look", attachments: [image.preview])
    #expect(transcript.entries.last?.attachments == [image.preview])
  }
}

extension Transcript.Entry {
  fileprivate var isPromptEntry: Bool {
    if case .prompt = kind { return true }
    return false
  }
}
