import AppKit
import CoreText
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ImageIO

public enum ReplyExportFormat: String, CaseIterable, Sendable {
    case pdf
    case png
    case text

    public var fileExtension: String { self == .text ? "txt" : rawValue }
    public var contentType: UTType {
        switch self { case .pdf: return .pdf; case .png: return .png; case .text: return .plainText }
    }
}

public enum ReplyExportError: LocalizedError, Equatable, Sendable {
    case emptyText
    case unsupportedFormat
    case outputTooLarge
    case renderingFailed

    public var errorDescription: String? {
        switch self {
        case .emptyText: return "没有可导出的回复内容。"
        case .unsupportedFormat: return "当前导出格式不受支持。"
        case .outputTooLarge: return "回复内容过大，导出已停止。"
        case .renderingFailed: return "回复渲染失败。"
        }
    }
}

/// Renders the visible reply locally. It never calls a model or uploads the
/// content. Call `export` with a user-selected destination, or use
/// `presentSavePanel` for an explicit macOS Save dialog.
public enum ReplyExporter {
    private static let maximumCharacters = 200_000
    private static let pageSize = CGSize(width: 612, height: 792) // US Letter points
    private static let margins: CGFloat = 54
    private static let maximumPNGHeight: CGFloat = 20_000

    public static func export(text: String, title: String, format: ReplyExportFormat, to url: URL) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ReplyExportError.emptyText }
        guard value.count <= maximumCharacters else { throw ReplyExportError.outputTooLarge }
        switch format {
        case .text:
            guard let data = value.data(using: .utf8) else { throw ReplyExportError.renderingFailed }
            try data.write(to: url, options: .atomic)
        case .pdf:
            try writePDF(value, title: title, to: url)
        case .png:
            try writePNG(value, title: title, to: url)
        }
    }

    /// Returns nil when the user cancels; export errors are thrown so the
    /// caller can show them in its own (themed) dialog.
    @MainActor
    public static func presentSavePanel(text: String, title: String, format: ReplyExportFormat, window: NSWindow? = nil) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出回复"
        panel.nameFieldStringValue = safeFilename(title) + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        let response = window.map { _ in panel.runModal() } ?? panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        try export(text: text, title: title, format: format, to: url)
        return url
    }

    private static func writePDF(_ text: String, title: String, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ReplyExportError.renderingFailed
        }
        let attributed = attributedText(text: text, title: title)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        let available = CGSize(width: pageSize.width - margins * 2, height: pageSize.height - margins * 2)
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: margins, y: margins, width: available.width, height: available.height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            context.saveGState()
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw ReplyExportError.renderingFailed }
            location += visible.length
        } while location < CFAttributedStringGetLength(attributed)
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    private static func writePNG(_ text: String, title: String, to url: URL) throws {
        let width: CGFloat = 1200
        let body = attributedText(text: text, title: title, scale: 2)
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        let constraint = CGSize(width: width - margins * 2, height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let height = max(180, ceil(suggested.height + margins * 2))
        guard height <= maximumPNGHeight else { throw ReplyExportError.outputTooLarge }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReplyExportError.renderingFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(rect: CGRect(x: margins, y: margins, width: width - margins * 2, height: height - margins * 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        guard CTFrameGetVisibleStringRange(frame).length >= CFAttributedStringGetLength(body) else { throw ReplyExportError.outputTooLarge }
        CTFrameDraw(frame, context)
        let data = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ReplyExportError.renderingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReplyExportError.renderingFailed }
        try data.write(to: url, options: .atomic)
    }

    private static func attributedText(text: String, title: String, scale: CGFloat = 1) -> CFAttributedString {
        let font = NSFont.systemFont(ofSize: 13 * scale)
        let titleFont = NSFont.boldSystemFont(ofSize: 20 * scale)
        let value = "\(title)\n\n\(text)"
        let result = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.black])
        result.addAttributes([.font: titleFont], range: NSRange(location: 0, length: (title as NSString).length))
        return result
    }

    private static func safeFilename(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = value.replacingOccurrences(of: "[^A-Za-z0-9一-龥._ -]", with: "_", options: .regularExpression)
        return String((sanitized.isEmpty ? "AgentDesk-回复" : sanitized).prefix(70))
    }
}
