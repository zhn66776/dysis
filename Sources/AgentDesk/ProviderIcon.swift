import SwiftUI
import AppKit
import AgentDeskCore

/// Displays the provider's original SVG mark from the app bundle.
///
/// The app deliberately does not recolor, redraw, or substitute a provider
/// mark with an SF Symbol.  `NSImage` on macOS 14+ decodes the bundled SVG
/// directly and SwiftUI keeps its vector sharpness while scaling the icon.
struct ProviderIcon: View {
    let provider: AgentDeskCore.ProviderID
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var resourceName: String {
        switch provider {
        case .codex, .grok:
            return colorScheme == .dark ? "\(provider.rawValue)-dark" : provider.rawValue
        case .claude, .gemini:
            return provider.rawValue
        }
    }

    private var assetURL: URL? {
        // The release packager places these files in Contents/Resources/
        // ProviderIcons.  Bundle.main is the correct lookup for the app,
        // while the executable-bundle fallback keeps previews and tests
        // useful when SwiftUI is hosted outside the finished .app.
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "svg", subdirectory: "ProviderIcons") {
            return bundled
        }
        if let executableBundle = Bundle(for: BundleMarker.self).url(forResource: resourceName, withExtension: "svg", subdirectory: "ProviderIcons") {
            return executableBundle
        }
#if DEBUG
        // `swift run` and SwiftUI previews do not use the ad-hoc app bundle.
        // Keep that development path useful without allowing a release build
        // to hide a packaging mistake by reading the source checkout.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceAsset = sourceRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ProviderIcons", isDirectory: true)
            .appendingPathComponent("\(resourceName).svg")
        if FileManager.default.fileExists(atPath: sourceAsset.path) { return sourceAsset }
#endif
        return nil
    }

    private var nsImage: NSImage? {
        guard let assetURL else { return nil }
        if let cached = ProviderIconCache.images.object(forKey: assetURL as NSURL) { return cached }
        guard let image = NSImage(contentsOf: assetURL), image.isValid else { return nil }
        image.isTemplate = false
        ProviderIconCache.images.setObject(image, forKey: assetURL as NSURL)
        return image
    }

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel(provider.name)
            } else {
                // A missing asset is a packaging error. Keep it visible in
                // release builds instead of quietly showing the old generic
                // SF Symbol, which could misidentify a provider.
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
                    .foregroundStyle(.orange)
                    .frame(width: size, height: size)
                    .accessibilityLabel("缺少 \(provider.name) 图标（\(resourceName).svg）")
                    .help("缺少 ProviderIcons/\(resourceName).svg")
            }
        }
        .frame(width: size, height: size)
    }
}

private final class BundleMarker {}
private enum ProviderIconCache { static let images = NSCache<NSURL, NSImage>() }
