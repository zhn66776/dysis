import Foundation
import ImageIO

/// Shared validation for user-selected image attachments. Providers receive
/// only regular local files, never arbitrary paths or data URLs.
enum MultimodalInputSupport {
    static let supportedMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    static let maxImages = 4
    static let maxBytesPerImage = 12 * 1024 * 1024
    static let maxBytesTotal = 24 * 1024 * 1024

    static func validate(_ images: [AgentImageInput]) throws -> [AgentImageInput] {
        guard images.count <= maxImages else {
            throw AgentError.unavailable("一次最多附加 \(maxImages) 张图片。")
        }
        var total = 0
        for image in images {
            let type = image.mediaType.lowercased()
            guard supportedMediaTypes.contains(type) else {
                throw AgentError.unavailable("暂不支持图片类型：\(image.mediaType)。请使用 PNG、JPEG、GIF 或 WebP。")
            }
            let url = image.localURL.standardizedFileURL
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                throw AgentError.unavailable("找不到图片附件：\(url.lastPathComponent)。")
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw AgentError.unavailable("图片附件不能是符号链接：\(url.lastPathComponent)。")
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                  let bytes = values.fileSize, bytes > 0 else {
                throw AgentError.unavailable("图片附件不是普通文件：\(url.lastPathComponent)。")
            }
            guard bytes <= maxBytesPerImage else {
                throw AgentError.unavailable("图片附件过大（单张上限 \(maxBytesPerImage / 1_048_576) MB）：\(url.lastPathComponent)。")
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw AgentError.unavailable("图片附件无法解码：\(url.lastPathComponent)。")
            }
            total += bytes
        }
        guard total <= maxBytesTotal else {
            throw AgentError.unavailable("图片附件总大小超过 \(maxBytesTotal / 1_048_576) MB。")
        }
        return images
    }

    static func claudeContent(prompt: String, images: [AgentImageInput]) throws -> [[String: Any]] {
        let checked = try validate(images)
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in checked {
            let data = try Data(contentsOf: image.localURL, options: [.mappedIfSafe])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType.lowercased(),
                    "data": data.base64EncodedString()
                ]
            ])
        }
        return content
    }

    static func codexInputs(prompt: String, images: [AgentImageInput]) throws -> [[String: Any]] {
        let checked = try validate(images)
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in checked {
            input.append(["type": "localImage", "path": image.localURL.standardizedFileURL.path])
        }
        return input
    }
}
