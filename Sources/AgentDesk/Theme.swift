import SwiftUI
import AppKit
import AgentDeskCore

// Native counterpart of the canvas tokens (canvas-web/src/styles.css,
// design/CANVAS.md §3.2). Light is "warm paper", dark is "graphite"; the
// colours follow the system appearance.

enum Theme {
    static let bg = dynamic(0xF5F4EE, 0x141414)
    static let side = dynamic(0xEFEDE4, 0x1A1A1A)
    static let card = dynamic(0xFFFFFF, 0x1F1F1F)
    static let panel = dynamic(0xFBFAF6, 0x181818)
    static let border = dynamic(0xE3E0D4, 0x2A2A2A)
    static let border2 = dynamic(0xDDD9CB, 0x333333)
    static let text = dynamic(0x2B2A26, 0xE6E6E6)
    static let muted = dynamic(0x7A776C, 0x8A8A8A)
    static let muted2 = dynamic(0xA9A598, 0x5A5A5A)
    static let selection = dynamic(0xE4E1D5, 0x2A2D33)
    static let chip = dynamic(0xEFEDE4, 0x262626)
    static let bubble = dynamic(0xECE9DF, 0x2A2A2A)
    static let primary = dynamic(0xC96442, 0xE6E6E6)
    static let onPrimary = dynamic(0xFFFFFF, 0x141414)
    static let ok = dynamic(0x3B6D11, 0x3FB950)
    static let run = dynamic(0x0F6E56, 0x3DBE98)
    static let bad = dynamic(0xA32D2D, 0xF09595)
    static let badBackground = dynamic(0xFCEBEB, 0x3A1A1A)
    static let warn = dynamic(0xBA7517, 0xEF9F27)

    static func provider(_ p: ProviderID) -> Color {
        switch p {
        case .claude: return dynamic(0xC96442, 0xE08A68)
        case .codex: return dynamic(0x10A37F, 0x3DBE98)
        case .grok: return dynamic(0x3B3B3B, 0xC8C8C8)
        case .gemini: return dynamic(0x4B6BEA, 0x7D96FF)
        }
    }

    static func providerTint(_ p: ProviderID) -> Color {
        switch p {
        case .claude: return dynamic(0xF6E6DE, 0x3A241B)
        case .codex: return dynamic(0xDDF2EB, 0x13332A)
        case .grok: return dynamic(0xE7E7E4, 0x2C2C2C)
        case .gemini: return dynamic(0xE3E8FC, 0x1E2541)
        }
    }

    static func providerInk(_ p: ProviderID) -> Color {
        switch p {
        case .claude: return dynamic(0x8A3E22, 0xF0B49A)
        case .codex: return dynamic(0x085041, 0x9FE1CB)
        case .grok: return dynamic(0x2C2C2A, 0xD3D1C7)
        case .gemini: return dynamic(0x26338A, 0xB5C3FF)
        }
    }

    // MARK: Fonts

    /// Chrome: the system sans (PingFang for Chinese).
    static func sans(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// Model replies: Iowan Old Style with Songti SC for Chinese, as on the canvas.
    static func serif(_ size: CGFloat = 14) -> Font { Font(serifNSFont(size)) }

    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }

    static func serifNSFont(_ size: CGFloat) -> NSFont {
        // PostScript names: the family names alone can resolve to a bold face.
        let fallback = NSFontDescriptor(name: "STSongti-SC-Regular", size: size)
        let descriptor = NSFontDescriptor(name: "IowanOldStyle-Roman", size: size).addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }

    static func radius(_ scheme: ColorScheme) -> CGFloat { scheme == .dark ? 8 : 12 }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Text roles

/// Metadata: sans in light, monospace in dark (the canvas `--meta`).
struct MetaText: ViewModifier {
    var size: CGFloat = 11
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.font(scheme == .dark ? Theme.mono(size) : Theme.sans(size)).foregroundStyle(Theme.muted)
    }
}

/// Titles: serif in light, small muted monospace in dark (the canvas brand and board title).
struct TitleText: ViewModifier {
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content.font(Theme.mono(size * 0.8)).tracking(0.6).foregroundStyle(Theme.text)
        } else {
            content.font(Theme.serif(size)).foregroundStyle(Theme.text)
        }
    }
}

extension View {
    func metaText(_ size: CGFloat = 11) -> some View { modifier(MetaText(size: size)) }
    func titleText(_ size: CGFloat = 16) -> some View { modifier(TitleText(size: size)) }

    /// A small muted heading, like the canvas `.side-label`.
    func sectionLabel() -> some View { font(Theme.sans(11, weight: .medium)).foregroundStyle(Theme.muted) }

    /// White (or graphite) card with a hairline border.
    func themedCard(padding: CGFloat = 14) -> some View { modifier(CardModifier(padding: padding)) }

    /// Text field look: card fill, hairline border, 7pt corners. Use with `.textFieldStyle(.plain)`.
    func themedField(mono: Bool = false) -> some View { modifier(FieldModifier(mono: mono)) }

    /// TextEditor look matching `themedField`.
    func themedEditor(mono: Bool = false) -> some View { modifier(EditorModifier(mono: mono)) }

    /// Window or sheet background plus text colour.
    func themedSurface(_ color: Color = Theme.bg) -> some View {
        foregroundStyle(Theme.text).font(Theme.sans()).background(color.ignoresSafeArea())
    }
}

private struct CardModifier: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius(scheme)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius(scheme)).strokeBorder(Theme.border2, lineWidth: 0.5))
    }
}

private struct FieldModifier: ViewModifier {
    let mono: Bool
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(mono ? Theme.mono(12) : Theme.sans(13))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.muted : Theme.border2, lineWidth: focused ? 1 : 0.5))
    }
}

private struct EditorModifier: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        content.font(mono ? Theme.mono(12) : Theme.sans(13))
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4).padding(.vertical, 5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border2, lineWidth: 0.5))
    }
}

// MARK: Buttons

/// The one filled action per surface: clay in light, light grey on graphite in dark.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12, weight: .medium))
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Bordered card button, like the canvas `.btn`.
struct SecondaryButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { SecondaryBody(configuration: configuration, destructive: destructive) }

    private struct SecondaryBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.sans(12))
                .foregroundStyle(destructive ? Theme.bad : Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(configuration.isPressed ? Theme.selection : Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(destructive && hovering ? Theme.bad : (hovering && enabled ? Theme.muted2 : Theme.border2), lineWidth: 0.5))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

/// Borderless muted button that fills on hover, like the canvas `.icon-btn` / `.side-item`.
struct GhostButtonStyle: ButtonStyle {
    var selected = false
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View { GhostBody(configuration: configuration, selected: selected, fullWidth: fullWidth) }

    private struct GhostBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let fullWidth: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.sans(12))
                .foregroundStyle(selected || (hovering && enabled) ? Theme.text : Theme.muted)
                .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(selected || (hovering && enabled) || configuration.isPressed ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}

/// Small bordered action under a reply, like the canvas `.act`.
struct ActionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ActionBody(configuration: configuration) }

    private struct ActionBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.sans(11))
                .foregroundStyle(hovering && enabled ? Theme.text : Theme.muted)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering && enabled ? Theme.muted2 : Theme.border2, lineWidth: 0.5))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Toggle drawn as a chip; on is tinted and outlined. Used for "@member" picks.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }

    private struct ChipBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                configuration.label
                    .font(Theme.sans(11))
                    .foregroundStyle(configuration.isOn ? Theme.text : Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(configuration.isOn ? Theme.selection : Theme.chip, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(configuration.isOn ? Theme.muted2 : .clear, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// A small flat switch.
struct ThemedSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(Theme.sans(12)).foregroundStyle(Theme.muted)
            Capsule()
                .fill(configuration.isOn ? Theme.primary : Theme.border2)
                .frame(width: 28, height: 16)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Theme.onPrimary : Theme.card).frame(width: 12, height: 12).padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: Dropdowns and segments

/// A menu whose closed state looks like the canvas `.dd-button`: text plus a small caret.
struct ThemedMenu<Content: View>: View {
    let title: String
    var mono = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Text(title)
        }
        .menuStyle(.button)
        .buttonStyle(DropdownButtonStyle(mono: mono))
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct DropdownButtonStyle: ButtonStyle {
    var mono = false
    func makeBody(configuration: Configuration) -> some View { DropdownBody(configuration: configuration, mono: mono) }

    private struct DropdownBody: View {
        let configuration: ButtonStyleConfiguration
        let mono: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            HStack(spacing: 5) {
                configuration.label.lineLimit(1)
                Text("▾").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .font(mono ? Theme.mono(11) : Theme.sans(12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering && enabled ? Theme.muted2 : Theme.border2, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
        }
    }
}

/// A selection dropdown (replaces the default `Picker`).
struct ThemedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var mono = false

    var body: some View {
        ThemedMenu(title: options.first { $0.value == selection }?.label ?? "选择", mono: mono) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = options[i].value } label: {
                    if options[i].value == selection { Label(options[i].label, systemImage: "checkmark") } else { Text(options[i].label) }
                }
            }
        }
    }
}

/// Segmented choice drawn as a chip row (replaces `.pickerStyle(.segmented)`).
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].label)
                        .font(Theme.sans(12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Theme.border2 : .clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
        .opacity(enabled ? 1 : 0.55)
        .fixedSize()
    }
}

// MARK: Containers

/// A labelled row inside a settings card (replaces `LabeledContent`).
struct ThemedRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 120
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.sans(12)).foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small rounded tag, like the canvas `.chip`.
struct ThemedChip: View {
    let text: String
    var tint: Color? = nil
    var ink: Color? = nil
    var body: some View {
        Text(text)
            .font(Theme.sans(11))
            .foregroundStyle(ink ?? Theme.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint ?? Theme.chip, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hairline divider in the canvas border colour.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

/// Red notice strip, like the canvas `.error-banner`.
struct ThemedErrorBanner: View {
    let message: String
    var actionTitle = "关闭"
    let onAction: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Text(message).font(Theme.sans(12)).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(actionTitle, action: onAction).buttonStyle(GhostButtonStyle())
        }
        .foregroundStyle(Theme.bad)
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(Theme.badBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.bad, lineWidth: 0.5))
    }
}

/// Running indicator: a small dot in the run colour (the canvas uses text, not spinners).
struct RunningDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(Theme.run).frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true } }
    }
}

// MARK: Dialogs

/// Confirmation or notice card shown in a sheet; the native counterpart of the
/// canvas confirm modal. Cancel (and Esc) declines; the action runs only on click.
struct ThemedDialog: View {
    let title: String
    let detail: String
    var action: String? = nil
    var destructive = true
    var cancelTitle = "取消"
    let onAction: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.sans(15, weight: .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(action == nil ? "好" : cancelTitle, action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if let action {
                    if destructive {
                        Button(action, action: onAction).buttonStyle(DangerButtonStyle())
                    } else {
                        Button(action, action: onAction).buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(Theme.card.ignoresSafeArea())
        .presentationBackground(Theme.card)
    }
}

/// Filled red button for a confirmed destructive action.
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12, weight: .medium))
            .foregroundStyle(Theme.badBackground)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.bad, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
