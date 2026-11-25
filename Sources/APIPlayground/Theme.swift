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

    /// The colour theme in use. Changing it takes effect when the views are next rebuilt,
    /// which the window does as soon as the choice changes.
    static var palette: Palette = .aurora

    /// The window behind everything.
    static var canvas: Color { color(palette.canvas, 0xF3F5FA) }
    /// The sidebar and top bar.
    static var chrome: Color { color(palette.chrome, 0xE9EDF5) }
    /// Panels and cards.
    static var surface: Color { color(palette.surface, 0xFFFFFF) }
    /// Fields, chips and hovered rows.
    static var raised: Color { color(palette.raised, 0xEEF1F7) }
    static var stroke: Color { color(palette.stroke, 0xD8DFEA) }

    static let text = color(0xE9EDF5, 0x101828)
    static let textSecondary = color(0x93A0B8, 0x5B667A)
    static let textTertiary = color(0x5E6B84, 0x98A2B3)

    /// The two ends of the signature gradient.
    static var accent: Color { color(palette.accent, palette.accentLight) }
    static var accentAlt: Color { color(palette.accentAlt, palette.accentAltLight) }
    /// Text and icons drawn on top of the gradient.
    static var onAccent: Color { color(0x0B0F16, palette.lightOnAccentIsWhite ? 0xFFFFFF : 0x0B0F16) }

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
        case "WS": return accentAlt
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

/// A colour theme: an accent gradient, and the tinted dark surfaces that go with it.
/// The light appearance shares one set of neutral surfaces and uses deeper accents.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    /// A few words on the mood, shown in the theme picker.
    let blurb: String
    let accent: UInt32
    let accentAlt: UInt32
    let accentLight: UInt32
    let accentAltLight: UInt32
    let lightOnAccentIsWhite: Bool
    let canvas: UInt32
    let chrome: UInt32
    let surface: UInt32
    let raised: UInt32
    let stroke: UInt32

    static let aurora = Palette(
        id: "aurora", name: "Aurora", blurb: "Mint to azure",
        accent: 0x1FE0B5, accentAlt: 0x21B4FF, accentLight: 0x00A884, accentAltLight: 0x0A84E0, lightOnAccentIsWhite: false,
        canvas: 0x090C13, chrome: 0x0D111A, surface: 0x121826, raised: 0x1A2233, stroke: 0x263047
    )
    static let sunset = Palette(
        id: "sunset", name: "Sunset", blurb: "Coral to apricot",
        accent: 0xFF5F6D, accentAlt: 0xFFC371, accentLight: 0xE5484D, accentAltLight: 0xF08C00, lightOnAccentIsWhite: false,
        canvas: 0x110B0E, chrome: 0x170F13, surface: 0x1F151A, raised: 0x2A1C23, stroke: 0x3B2832
    )
    static let ultraviolet = Palette(
        id: "ultraviolet", name: "Ultraviolet", blurb: "Violet to pink",
        accent: 0xA78BFA, accentAlt: 0xF472B6, accentLight: 0x7C3AED, accentAltLight: 0xDB2777, lightOnAccentIsWhite: true,
        canvas: 0x0C0914, chrome: 0x110D1C, surface: 0x181228, raised: 0x221A37, stroke: 0x31264D
    )
    static let ocean = Palette(
        id: "ocean", name: "Ocean", blurb: "Cyan to indigo",
        accent: 0x22D3EE, accentAlt: 0x818CF8, accentLight: 0x0891B2, accentAltLight: 0x4F46E5, lightOnAccentIsWhite: true,
        canvas: 0x070D16, chrome: 0x0A121E, surface: 0x0F1A2A, raised: 0x16243A, stroke: 0x213350
    )
    static let forest = Palette(
        id: "forest", name: "Forest", blurb: "Lime to emerald",
        accent: 0xBEF264, accentAlt: 0x34D399, accentLight: 0x4D7C0F, accentAltLight: 0x059669, lightOnAccentIsWhite: true,
        canvas: 0x080E0A, chrome: 0x0C140F, surface: 0x111C15, raised: 0x18271D, stroke: 0x23382A
    )
    static let gold = Palette(
        id: "gold", name: "Gold", blurb: "Amber to yellow",
        accent: 0xFBBF24, accentAlt: 0xFDE047, accentLight: 0xB45309, accentAltLight: 0xCA8A04, lightOnAccentIsWhite: true,
        canvas: 0x0F0D08, chrome: 0x15120B, surface: 0x1D1910, raised: 0x282316, stroke: 0x393220
    )
    static let neon = Palette(
        id: "neon", name: "Neon", blurb: "Pink to cyan",
        accent: 0xFF4ECD, accentAlt: 0x22E5FF, accentLight: 0xD6249F, accentAltLight: 0x0891B2, lightOnAccentIsWhite: true,
        canvas: 0x0A0813, chrome: 0x0F0C1B, surface: 0x161226, raised: 0x201A36, stroke: 0x2F274C
    )
    static let graphite = Palette(
        id: "graphite", name: "Graphite", blurb: "Neutral and quiet",
        accent: 0xF4F4F5, accentAlt: 0xA1A1AA, accentLight: 0x27272A, accentAltLight: 0x52525B, lightOnAccentIsWhite: true,
        canvas: 0x0B0B0C, chrome: 0x101012, surface: 0x17171A, raised: 0x202024, stroke: 0x2E2E34
    )

    static let all: [Palette] = [.aurora, .sunset, .ultraviolet, .ocean, .forest, .gold, .neon, .graphite]

    static func named(_ id: String?) -> Palette {
        all.first { $0.id == id } ?? .aurora
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
            .foregroundStyle(Theme.onAccent)
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
                        .foregroundStyle(Theme.onAccent)
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
                    .foregroundStyle(Theme.onAccent)
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

/// The sheet for choosing a colour theme and the dark or light appearance.
struct AppearanceView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                Text("Theme")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Button(appearance.title) { model.appearance = appearance }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.appearance == appearance ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(model.appearance == appearance ? Theme.accent.opacity(0.14) : Color.clear, in: Capsule())
                            .accessibilityAddTraits(model.appearance == appearance ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Theme.raised, in: Capsule())
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Palette.all) { palette in
                    PaletteTile(palette: palette, isSelected: model.paletteID == palette.id) {
                        model.paletteID = palette.id
                    }
                }
            }

            HStack {
                Text("The theme changes the accent colours and tints the dark background.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Done") { model.showingAppearance = false }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
    }
}

/// A preview of one theme: its surfaces, its gradient and a sample of its accents.
private struct PaletteTile: View {
    let palette: Palette
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private func color(_ hex: UInt32) -> Color { NSColor(hex: hex).color }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // A miniature of the window in this theme's dark colours.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [color(palette.accent), color(palette.accentAlt)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 12, height: 12)
                        Capsule().fill(color(palette.stroke)).frame(width: 44, height: 5)
                        Spacer()
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4).fill(color(palette.raised)).frame(height: 14)
                        Capsule()
                            .fill(LinearGradient(colors: [color(palette.accent), color(palette.accentAlt)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 34, height: 14)
                    }
                    Capsule().fill(color(palette.accent)).frame(width: 30, height: 2.5)
                    Capsule().fill(color(palette.stroke)).frame(width: 80, height: 4)
                    Capsule().fill(color(palette.stroke)).frame(width: 56, height: 4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(palette.surface))
                .overlay(alignment: .bottom) { Rectangle().fill(color(palette.stroke)).frame(height: 1) }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(palette.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(palette.blurb)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(10)
                .background(Theme.raised)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(isSelected ? Theme.accent : (hovering ? Theme.textTertiary : Theme.stroke), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(palette.name) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
