import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AgentDeskCore

@MainActor
final class AttachmentDrafts: ObservableObject {
    @Published var files: [UUID: [ChatAttachment]] = [:]
    @Published var importing: Set<UUID> = []
    @Published var errorMessage: String?
    let root: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(root: URL) { self.root = root }

    func choose(for id: UUID) {
        guard !importing.contains(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "添加图片或文档"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .plainText] + ["doc", "docx", "md", "csv", "json"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls, to: id)
    }

    func add(_ urls: [URL], to id: UUID) {
        guard !importing.contains(id) else { return }
        guard files[id, default: []].count + urls.count <= 6 else { errorMessage = "每条消息最多添加 6 个文件。"; return }
        importing.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try AttachmentStore(root: root)
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                let imported = try await store.importFiles(from: urls)
                try Task.checkCancellation()
                guard files[id, default: []].filter(\.isImage).count + imported.filter(\.isImage).count <= 4 else {
                    for file in imported { try? store.remove(file) }
                    throw AttachmentError.tooManyImages(maximum: 4)
                }
                files[id, default: []] += imported
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            importing.remove(id); tasks.removeValue(forKey: id)
        }
    }

    func drop(_ providers: [NSItemProvider], into id: UUID) -> Bool {
        guard !importing.contains(id) else { return false }
        guard files[id, default: []].count + providers.count <= 6 else { errorMessage = "每条消息最多添加 6 个文件。"; return false }
        importing.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if Task.isCancelled { importing.remove(id); tasks.removeValue(forKey: id); return }
                if let url, url.isFileURL { urls.append(url) }
            }
            importing.remove(id); tasks.removeValue(forKey: id)
            guard !urls.isEmpty else { return }
            add(urls, to: id)
        }
        return true
    }

    func remove(_ fileID: UUID, from id: UUID) { files[id]?.removeAll { $0.id == fileID } }
    func clear(_ id: UUID) { files.removeValue(forKey: id) }
    func shutdown() { tasks.values.forEach { $0.cancel() } }
}

struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    let root: URL
    var onRemove: ((UUID) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { file in
                    HStack(spacing: 8) {
                        if file.isImage, let image = AttachmentThumbnail.load(file, root: root) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 42, height: 42).clipped().cornerRadius(6)
                        } else {
                            Image(systemName: file.kind == .pdf ? "doc.richtext" : "doc.text")
                                .font(.title3).foregroundStyle(.secondary).frame(width: 32)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.displayName).font(.caption.weight(.medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: 180, alignment: .leading)
                        if let onRemove {
                            Button { onRemove(file.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help("移除附件")
                        }
                    }
                    .padding(8).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    .help(file.extractionNote ?? file.displayName)
                    .contextMenu {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.storedURL(root: root)]) }
                    }
                }
            }
        }.frame(maxHeight: 70)
    }
}

private enum AttachmentThumbnail {
    static let cache = NSCache<NSString, NSImage>()
    static func load(_ file: ChatAttachment, root: URL) -> NSImage? {
        let key = (root.path + file.id.uuidString) as NSString
        if let image = cache.object(forKey: key) { return image }
        let url = file.modelURL(root: root) ?? file.storedURL(root: root)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AttachmentNotice: View {
    let attachments: [ChatAttachment]
    let supportsImages: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if attachments.contains(where: { !$0.isImage }) {
                Text("文档以提取文字发送；内嵌图片、版式及扫描页不会自动作为视觉输入。长文档可能截取部分内容。")
            }
            if !supportsImages && attachments.contains(where: \.isImage) {
                Text("当前 Cursor 连接暂不支持图片输入，请选择 Claude 或 ChatGPT。")
                    .foregroundStyle(.orange)
            }
            ForEach(attachments.filter { !$0.isImage && $0.extractionNote != nil }) { file in
                Text("\(file.displayName)：\(file.extractionNote ?? "")")
            }
        }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ReplyExportMenu: View {
    let text: String
    let title: String
    var body: some View {
        Menu {
            Button("导出为 PDF") { _ = ReplyExporter.presentSavePanel(text: text, title: title, format: .pdf) }
            Button("导出为图片 PNG") { _ = ReplyExporter.presentSavePanel(text: text, title: title, format: .png) }
            Button("导出为文本") { _ = ReplyExporter.presentSavePanel(text: text, title: title, format: .text) }
        } label: { Label("导出", systemImage: "square.and.arrow.up") }
        .menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(text.isEmpty)
        .help("把这条回复保存为文件")
    }
}
