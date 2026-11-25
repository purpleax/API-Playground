import AppKit
import SwiftUI

/// The app's look: colours, shapes and the custom controls built from them.
/// Every colour has a dark and a light value and follows the window's appearance.
enum Theme {
    // MARK: Colours

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    private static func color(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: dynamic(dark, light))
    }

    /// The window behind everything.
    static let canvas = color(0x090C13, 0xF3F5FA)
    /// The sidebar and top bar.
    static let chrome = color(0x0D111A, 0xE9EDF5)
    /// Panels and cards.
    static let surface = color(0x121826, 0xFFFFFF)
    /// Fields, chips and hovered rows.
    static let raised = color(0x1A2233, 0xEEF1F7)
    static let stroke = color(0x263047, 0xD8DFEA)

    static let text = color(0xE9EDF5, 0x101828)
    static let textSecondary = color(0x93A0B8, 0x5B667A)
    static let textTertiary = color(0x5E6B84, 0x98A2B3)

    /// The two ends of the signature gradient.
    static let accent = color(0x1FE0B5, 0x00A884)
    static let accentAlt = color(0x21B4FF, 0x0A84E0)

    static let success = color(0x34D399, 0x059669)
    static let info = color(0x60A5FA, 0x2563EB)
    static let warning = color(0xFBBF24, 0xC27803)
    static let danger = color(0xFB7185, 0xE11D48)
    static let violet = color(0xC084FC, 0x9333EA)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accentAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func method(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return success
        case "POST": return warning
        case "PUT": return info
        case "PATCH": return violet
        case "DELETE": return danger
        default: return textSecondary
        }
    }

    static func status(_ status: Int) -> Color {
        switch status {
        case 200..<300: return success
        case 300..<400: return info
        case 400..<500: return warning
        default: return danger
        }
    }

    // MARK: Syntax colours (AppKit, for the code views)

    enum Syntax {
        static let plain = Theme.dynamic(0xD7DDEA, 0x1F2937)
        static let key = Theme.dynamic(0x7DD3FC, 0x0369A1)
        static let string = Theme.dynamic(0x86EFAC, 0x047857)
        static let number = Theme.dynamic(0xFDBA74, 0xC2410C)
        static let keyword = Theme.dynamic(0xF0ABFC, 0xA21CAF)
        static let punctuation = Theme.dynamic(0x6B7A96, 0x8A94A6)
        static let variable = Theme.dynamic(0xFDE047, 0xB45309)
        static let comment = Theme.dynamic(0x5E6B84, 0x98A2B3)
        static let sent = Theme.dynamic(0x7DD3FC, 0x0369A1)
        static let received = Theme.dynamic(0x86EFAC, 0x047857)
    }

    // MARK: Shapes

    static let radius: CGFloat = 10
    static let smallRadius: CGFloat = 7
}

extension NSColor {
    /// The same colour for SwiftUI.
    var color: Color { Color(nsColor: self) }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Dark, light, or whatever the Mac is set to.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match System"
        }
    }

    func apply() {
        switch self {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }
}

// MARK: - Buttons

/// The main action on a screen: filled with the signature gradient.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, large ? 18 : 13)
            .padding(.vertical, large ? 9 : 6)
            .background(Theme.gradient, in: Capsule())
            .shadow(color: Theme.accent.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(Capsule())
    }
}

/// Everyday buttons: a quiet filled capsule.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, large: large, isEnabled: isEnabled)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let large: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 12.5, weight: .medium))
                .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
                .padding(.horizontal, large ? 16 : 12)
                .padding(.vertical, large ? 9 : 6)
                .background(hovering ? Theme.stroke : Theme.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

/// A text-and-icon button with no background: "Add", "Remove" and similar.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(configuration.role == .destructive ? Theme.danger : (hovering ? Theme.accent : Theme.textSecondary))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// An on/off pill: tinted with the accent when on.
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(configuration.isOn ? Theme.accent.opacity(0.14) : Theme.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(configuration.isOn ? Theme.accent.opacity(0.5) : Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small icon in the top bar or a panel header, with a hover highlight.
struct IconButton: View {
    let systemImage: String
    var active = false
    var tint: Color = Theme.textSecondary
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : tint))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius)
                        .fill(active ? Theme.accent.opacity(0.14) : (hovering ? Theme.raised : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Fields

/// A filled, rounded text field that glows in the accent colour when focused.
struct ThemedTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        ThemedFieldBody { configuration.textFieldStyle(.plain) }
    }
}

private struct ThemedFieldBody<Content: View>: View {
    @ViewBuilder let content: Content
    @FocusState private var focused: Bool

    var body: some View {
        content
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .strokeBorder(focused ? Theme.accent.opacity(0.8) : Theme.stroke, lineWidth: 1)
            )
            .shadow(color: Theme.accent.opacity(focused ? 0.18 : 0), radius: 6)
    }
}

/// A small rounded checkbox in the accent colour.
struct ThemedCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.raised))
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(configuration.isOn ? Color.clear : Theme.stroke)
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.8))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

// MARK: - Chips and tabs

/// A small coloured label: a method, a status, a count.
struct Chip: View {
    let text: String
    var color: Color = Theme.textSecondary
    var filled = true
    var mono = true

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: mono ? .monospaced : .default))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(filled ? color.opacity(0.14) : Theme.raised, in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// The method as a compact coloured tag, as shown in the sidebar.
struct MethodBadge: View {
    let method: String

    static func color(_ method: String) -> Color {
        Theme.method(method)
    }

    var body: some View {
        Text(method.uppercased().prefix(6))
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(Theme.method(method))
            .frame(width: 42, height: 17)
            .background(Theme.method(method).opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct TabItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var badge: String?
    /// The colour of the badge, when it means more than a count.
    var badgeColor: Color?
}

/// A row of text tabs with a sliding gradient underline.
struct ThemedTabBar<ID: Hashable>: View {
    let tabs: [TabItem<ID>]
    @Binding var selection: ID
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isSelected: tab.id == selection, namespace: underline) {
                    selection = tab.id
                }
            }
            Spacer(minLength: 0)
        }
        // Animate only the bar itself, so the underline slides but the content below switches at once.
        .animation(.snappy(duration: 0.22), value: selection)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private struct TabButton: View {
        let tab: TabItem<ID>
        let isSelected: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.text : (hovering ? Theme.text : Theme.textSecondary))
                    if let badge = tab.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(tab.badgeColor ?? (isSelected ? Theme.accent : Theme.textSecondary))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background((tab.badgeColor ?? (isSelected ? Theme.accent : Theme.textSecondary)).opacity(0.14), in: Capsule())
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Theme.gradient)
                            .frame(height: 2.5)
                            .padding(.horizontal, 6)
                            .matchedGeometryEffect(id: "underline", in: namespace)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

// MARK: - Containers

extension View {
    /// A rounded panel on the canvas.
    func card(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    /// The look shared by every sheet: themed background, buttons and tint.
    func themedSheet() -> some View {
        self
            .buttonStyle(SecondaryButtonStyle())
            .toggleStyle(ThemedCheckboxStyle())
            .tint(Theme.accent)
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
    }

    /// A section heading inside a panel.
    func sectionTitle() -> some View {
        self
            .font(.system(size: 11, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// The empty states: a glowing icon, a line of explanation and actions.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 84, height: 84)
                    .blur(radius: 6)
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.gradient)
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, detail: String) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}

/// The app's mark: braces on the signature gradient.
struct LogoMark: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3)
            .fill(Theme.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text("{ }")
                    .font(.system(size: size * 0.46, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.8))
            )
            .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 1)
    }
}

/// A drop-down in the app's style, in place of the system pop-up button.
/// Put the same rows inside it as a Picker would have: `Text("Title").tag(value)`.
struct MenuPicker<Value: Hashable, Content: View>: View {
    /// The title of the current choice, shown on the control.
    let title: String
    @Binding var selection: Value
    var tint: Color = Theme.text
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            Picker("", selection: $selection) { content }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A row in a list that can be selected, with the accent highlight instead of the system one.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius)
                        .fill(isSelected ? Theme.accent.opacity(0.14) : (hovering ? Theme.raised : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A message to the user, in the app's style instead of a system alert.
struct NoticeView: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }
            ScrollView {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("OK", action: dismiss)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
