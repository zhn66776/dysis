import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

public final class AttachmentStore: @unchecked Sendable {
    public let root: URL
    public let limits: AttachmentImportLimits
    private let fileManager = FileManager.default

    public init(root: URL, limits: AttachmentImportLimits = .default) throws {
        self.root = root
        self.limits = limits
        try fileManager.createDirectory(at: root.appendingPathComponent("Attachments", isDirectory: true), withIntermediateDirectories: true)
    }

    public func importFiles(from urls: [URL]) async throws -> [ChatAttachment] {
        guard urls.count <= limits.maxFilesPerImport else { throw AttachmentError.tooManyFiles(maximum: limits.maxFilesPerImport) }
        var imported: [ChatAttachment] = []
        do {
            for url in urls {
                let attachment = try await importFile(from: url)
                imported.append(attachment)
                if imported.filter(\.isImage).count > limits.maxImageFilesPerImport {
                    throw AttachmentError.tooManyImages(maximum: limits.maxImageFilesPerImport)
                }
            }
            return imported
        } catch {
            for item in imported { try? remove(item) }
            throw error
        }
    }

    public func importFile(from sourceURL: URL) async throws -> ChatAttachment {
        try Task.checkCancellation()
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL else { throw AttachmentError.inaccessible(source.lastPathComponent) }
        let values: URLResourceValues
        do { values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw AttachmentError.inaccessible(source.lastPathComponent) }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw AttachmentError.notRegularFile(source.lastPathComponent)
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0 else { throw AttachmentError.invalidFile(source.lastPathComponent) }
        guard byteCount <= limits.maxFileBytes else { throw AttachmentError.tooLarge(name: source.lastPathComponent, maximumBytes: limits.maxFileBytes) }
        guard fileManager.isReadableFile(atPath: source.path) else { throw AttachmentError.inaccessible(source.lastPathComponent) }
        let data: Data
        do { data = try Data(contentsOf: source, options: [.mappedIfSafe]) }
        catch { throw AttachmentError.inaccessible(source.lastPathComponent) }
        guard Int64(data.count) <= limits.maxFileBytes else { throw AttachmentError.tooLarge(name: source.lastPathComponent, maximumBytes: limits.maxFileBytes) }
        let detected = try detect(source: source, data: data)
        let id = UUID()
        let directory = root.appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw AttachmentError.storageFailed(error.localizedDescription) }
        let extensionName = source.pathExtension.lowercased()
        let storedName = "content" + (extensionName.isEmpty ? "" : ".\(extensionName)")
        let destination = directory.appendingPathComponent(storedName, isDirectory: false)
        do { try data.write(to: destination, options: [.atomic]) }
        catch { throw AttachmentError.storageFailed(error.localizedDescription) }
        let relative = "Attachments/\(id.uuidString)/\(storedName)"
        var modelRelativePath: String?
        var modelMediaType: String?
        if detected.kind == .image {
            let normalized = try normalizeImage(originalData: data, directory: directory, id: id)
            modelRelativePath = normalized.relativePath
            modelMediaType = normalized.mediaType
        }
        do {
            let extracted = try await extractText(kind: detected.kind, source: destination, data: data)
            return ChatAttachment(id: id, displayName: source.lastPathComponent, storedRelativePath: relative,
                                  kind: detected.kind, mediaType: detected.mediaType, byteCount: byteCount,
                                  modelRelativePath: modelRelativePath, modelMediaType: modelMediaType,
                                  extractedText: extracted.text, extractionNote: extracted.note)
        } catch let error as AttachmentError {
            throw error
        } catch {
            throw AttachmentError.extractionFailed(error.localizedDescription)
        }
    }

    public func remove(_ attachment: ChatAttachment) throws {
        let rawFileURL = attachment.storedURL(root: root)
        let resolvedFileURL = rawFileURL.resolvingSymlinksInPath().standardizedFileURL
        let base = root.appendingPathComponent("Attachments", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let attachmentURL = resolvedFileURL.deletingLastPathComponent()
        guard attachmentURL.path.hasPrefix(base.path + "/"),
              resolvedFileURL.path.hasPrefix(base.path + "/") else {
            throw AttachmentError.storageFailed("附件路径不在 AgentDesk Attachments 目录内。")
        }
        try fileManager.removeItem(at: attachmentURL)
    }

    public static func validateForTextPrompt(_ attachments: [ChatAttachment]) throws {
        for attachment in attachments where [.pdf, .document, .text].contains(attachment.kind) && attachment.extractedText?.isEmpty != false {
            let reason = attachment.kind == .pdf ? "没有可提取的文字；这是扫描 PDF，请先进行 OCR。" : "没有可提取的文字，请检查文件内容或转为可编辑文本。"
            throw AttachmentError.extractionFailed("\(attachment.displayName) \(reason)")
        }
    }

    private struct Detection { let kind: ChatAttachmentKind; let mediaType: String }
    private struct Extraction { let text: String?; let note: String? }

    private func detect(source: URL, data: Data) throws -> Detection {
        let ext = source.pathExtension.lowercased()
        if data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) {
            guard ext == "pdf" else { throw AttachmentError.invalidFile(source.lastPathComponent) }
            return Detection(kind: .pdf, mediaType: "application/pdf")
        }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) && ["docx", "docm"].contains(ext) {
            return Detection(kind: .document, mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) && ext == "doc" {
            return Detection(kind: .document, mediaType: "application/msword")
        }
        if let imageType = imageType(data: data, extensionName: ext) {
            return Detection(kind: .image, mediaType: imageType)
        }
        let textExtensions = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml", "swift", "py", "js", "ts", "html", "css", "log"]
        guard textExtensions.contains(ext), String(data: data, encoding: .utf8) != nil else {
            throw AttachmentError.unsupportedType(source.lastPathComponent)
        }
        return Detection(kind: .text, mediaType: mimeForText(ext))
    }

    private func imageType(data: Data, extensionName: String) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else { return nil }
        let identifier = type as String
        let allowed: [String: String] = [
            "public.jpeg": "image/jpeg", "public.png": "image/png", "com.compuserve.gif": "image/gif",
            "org.webmproject.webp": "image/webp", "public.heic": "image/heic", "public.heif": "image/heif"
        ]
        guard let media = allowed[identifier] else { return nil }
        let expected = Set(["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"])
        return expected.contains(media) ? media : nil
    }

    private func extractText(kind: ChatAttachmentKind, source: URL, data: Data) async throws -> Extraction {
        switch kind {
        case .image: return imageDimensions(source: source)
        case .text:
            let value = String(data: data, encoding: .utf8) ?? ""
            return bounded(value, note: nil)
        case .pdf: return try extractPDF(source)
        case .document: return try await extractDocument(source)
        }
    }

    private func extractPDF(_ url: URL) throws -> Extraction {
        guard let document = PDFDocument(url: url) else { throw AttachmentError.invalidFile(url.lastPathComponent) }
        let count = document.pageCount
        guard count > 0 else { return Extraction(text: nil, note: "PDF 没有页面。") }
        var output = ""
        var visited = 0
        var textPages = 0
        let pageLimit = min(count, limits.maxPDFPages)
        for index in 0..<pageLimit {
            try Task.checkCancellation()
            visited += 1
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textPages += 1
                output += "\n[第 \(index + 1) 页]\n\(text)"
                if output.count >= limits.maxExtractedCharacters { break }
            }
        }
        var notes: [String] = []
        if visited < count { notes.append("仅提取前 \(visited) 页，共 \(count) 页。") }
        if textPages < visited { notes.append("其中 \(visited - textPages) 页未提取到文字；扫描页需先进行 OCR。") }
        if output.isEmpty { notes.append("PDF 没有可提取的文本。") }
        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        let bounded = bounded(output, note: note)
        return bounded
    }

    private func extractDocument(_ url: URL) async throws -> Extraction {
        var attrs: NSDictionary?
        do {
            let docType: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
            let attributed = try NSAttributedString(url: url, options: [.documentType: docType], documentAttributes: &attrs)
            let text = attributed.string
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return bounded(text, note: nil) }
        } catch {
            // Try macOS's local converter with bounded, cancellable pipes.
        }
        if ["doc", "docx", "docm"].contains(url.pathExtension.lowercased()) {
            let text = try await extractWithTextUtil(url)
            return bounded(text, note: text.isEmpty ? "Word 文件没有可提取的文字。" : nil)
        }
        return Extraction(text: nil, note: "此 Word 文件的本地文字提取不可用。")
    }

    private func extractWithTextUtil(_ url: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return "" }
        let result = try await CommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/textutil"),
            arguments: ["-convert", "txt", "-stdout", url.path], directory: url.deletingLastPathComponent(), timeout: 20)
        guard result.code == 0 else { throw AttachmentError.extractionFailed("无法读取此 Word 文件。") }
        return result.stdout
    }

    private func imageDimensions(source: URL) -> Extraction {
        guard let source = CGImageSourceCreateWithURL(source as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return Extraction(text: nil, note: "图片已保存，但无法读取像素尺寸。")
        }
        if Int64(width) * Int64(height) > Int64(limits.maxImagePixels) { return Extraction(text: nil, note: "图片像素数量超过安全上限。") }
        return Extraction(text: nil, note: "图片作为视觉附件保留；文字识别由支持视觉输入的模型处理。")
    }

    private func normalizeImage(originalData: Data, directory: URL, id: UUID) throws -> (relativePath: String, mediaType: String) {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil) else { throw AttachmentError.invalidFile("图片") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, Int64(width) * Int64(height) <= Int64(limits.maxImagePixels) else { throw AttachmentError.invalidFile("图片像素数量超过上限") }
        let maxEdge = 3072
        let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxEdge, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw AttachmentError.invalidFile("图片无法解码") }
        let destination = directory.appendingPathComponent("model.jpg")
        var written = false
        for quality in [0.82, 0.65, 0.45] {
            let data = NSMutableData()
            guard let imageDestination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(imageDestination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(imageDestination), data.length <= 4 * 1024 * 1024 else { continue }
            try data.write(to: destination, options: [.atomic]); written = true; break
        }
        guard written else { throw AttachmentError.invalidFile("图片压缩后仍超过 4 MB") }
        return ("Attachments/\(id.uuidString)/model.jpg", "image/jpeg")
    }

    private func bounded(_ text: String, note: String?) -> Extraction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limits.maxExtractedCharacters else { return Extraction(text: trimmed.isEmpty ? nil : trimmed, note: note) }
        return Extraction(text: String(trimmed.prefix(limits.maxExtractedCharacters)), note: [note, "文字内容已截断。"].compactMap { $0 }.joined(separator: " "))
    }

    private func mimeForText(_ ext: String) -> String {
        switch ext { case "json": return "application/json"; case "csv": return "text/csv"; case "html": return "text/html"; default: return "text/plain" }
    }
}
