//
//  Components.swift
//  Packmule
//
//  The Tinbox component kit: sheets (radius 34), cards (18), toggles
//  (51×31, knob 27, 180 ms), segmented pills, chips, rows. Plus the pieces a
//  file app needs: labelled fields, a thin progress bar, file-type glyphs.
//

import SwiftUI

// MARK: - Button styles

/// Opacity press feedback.
struct FadePressStyle: ButtonStyle {
    var opacity: Double = 0.7
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? opacity : 1)
    }
}

/// Scale press feedback.
struct ScalePressStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1)
    }
}

/// Brightness press feedback.
struct DimPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? -0.15 : 0)
    }
}

/// Row highlight.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.white.opacity(0.05) : Color.clear)
    }
}

// MARK: - Pills

struct AccentPill: View {
    @Environment(\.theme) private var theme
    let title: String
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(compact ? .system(size: 13, weight: .bold) : Typography.button)
                .foregroundColor(.white)
                .padding(.horizontal, compact ? 16 : 18)
                .padding(.vertical, compact ? 7 : 8)
                .background(theme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(DimPressStyle())
    }
}

struct TintPill: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.button)
                .foregroundColor(theme.accentText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.tint)
                .overlay(Capsule().stroke(theme.tintBorder, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(DimPressStyle())
    }
}

struct SecondaryPill: View {
    @Environment(\.theme) private var theme
    let title: String
    var bold = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(bold ? Typography.button : Typography.buttonSemibold)
                .foregroundColor(Palette.text85)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(theme.secondaryButton)
                .clipShape(Capsule())
        }
        .buttonStyle(FadePressStyle())
    }
}

struct DestructivePill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.button)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Palette.destructive.opacity(0.85))
                .clipShape(Capsule())
        }
        .buttonStyle(DimPressStyle())
    }
}

struct BackCircleButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(theme.card).frame(width: 34, height: 34)
                ChevronShape(direction: .left)
                    .stroke(Palette.text80, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 14)
            }
        }
        .buttonStyle(FadePressStyle())
    }
}

struct ChevronShape: Shape {
    enum Direction { case left, right, up, down }
    var direction: Direction
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch direction {
        case .right:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .left:
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .up:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .down:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return p
    }
}

struct RowChevron: View {
    var body: some View {
        ChevronShape(direction: .right)
            .stroke(Palette.textQuaternary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 8, height: 14)
    }
}

// MARK: - Toggle (51×31, knob 27, accent track)

struct MuleToggle: View {
    @Environment(\.theme) private var theme
    @Binding var isOn: Bool
    var haptic = true

    var body: some View {
        Button {
            if haptic { ButtonHaptics.shared.tap() }
            withAnimation(.easeInOut(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: .leading) {
                Capsule().fill(isOn ? theme.accent : theme.trackOff)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                    .frame(width: 27, height: 27)
                    .offset(x: isOn ? 22 : 2)
            }
            .frame(width: 51, height: 31)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Segmented pill

struct SegmentedPill<T: Hashable>: View {
    @Environment(\.theme) private var theme
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    var fontSize: CGFloat = 13
    var horizontalPadding: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    ButtonHaptics.shared.tap()
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundColor(selected ? .white : Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 5)
                        .background(selected ? theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Cards & rows

struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var bottomSpacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.bottom, bottomSpacing)
    }
}

struct RowSeparator: View {
    var body: some View {
        Rectangle().fill(Palette.separator).frame(height: 0.5)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(Typography.sectionHeader)
            .tracking(0.8)
            .foregroundColor(Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }
}

/// Title (+ optional subtitle) on the left, custom trailing content on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = .white
    var showsSeparator = true
    var gap: CGFloat = 12
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: gap) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Typography.row).foregroundColor(titleColor)
                    if let subtitle {
                        Text(subtitle).font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            if showsSeparator { RowSeparator() }
        }
    }
}

/// Tappable row with optional detail text and a chevron.
struct NavRow: View {
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var titleColor: Color = .white
    var showsSeparator = true
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                action()
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Typography.row).foregroundColor(titleColor)
                        if let subtitle {
                            Text(subtitle).font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail {
                        Text(detail).font(Typography.detail).foregroundColor(Palette.text40).lineLimit(1)
                    }
                    if showsChevron { RowChevron() }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            if showsSeparator { RowSeparator() }
        }
    }
}

// MARK: - Fields

/// Chip-style text field with a small uppercase label above it.
struct LabeledField: View {
    @Environment(\.theme) private var theme
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var autocapitalize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Typography.sectionHeader)
                .tracking(0.8)
                .foregroundColor(Palette.textTertiary)
            Group {
                if secure {
                    SecureField("", text: $text,
                                prompt: Text(placeholder).foregroundColor(Palette.textQuaternary))
                } else {
                    TextField("", text: $text,
                              prompt: Text(placeholder).foregroundColor(Palette.textQuaternary))
                }
            }
            .font(.system(size: 15))
            .foregroundColor(.white)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalize ? .sentences : .never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(theme.well)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Thin accent progress bar for transfer rows.
struct ThinProgressBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                Capsule().fill(theme.accent)
                    .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Glyphs

/// The "PACKMULE" eyebrow as a stamped brand lozenge, same family as the
/// Tinbox stamp: uppercase in a pill outline, tiny ®, slight skew.
struct MuleStamp: View {
    var body: some View {
        HStack(alignment: .top, spacing: 1.5) {
            Text("PACKMULE")
                .font(Typography.eyebrow)
                .tracking(2)
            Text("®")
                .font(.system(size: 6.5, weight: .semibold))
                .padding(.top, -0.5)
        }
        .foregroundColor(Palette.textTertiary)
        .shadow(color: .white.opacity(0.18), radius: 0, y: 0.7)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 3.5)
        .overlay(Capsule().stroke(Palette.textQuaternary, lineWidth: 1.5))
        .rotationEffect(.degrees(-3), anchor: .bottomLeading)
    }
}

/// The two-line "hamburger with accent dots" settings glyph.
struct SettingsGlyph: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Capsule().fill(Palette.text70).frame(width: 20, height: 2)
                Capsule().fill(Palette.text70).frame(width: 20, height: 2)
            }
            Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: -4, y: -5)
            Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: 4, y: 5)
        }
        .frame(width: 20, height: 16)
    }
}

/// SF Symbol + colour for a file, picked by extension.
enum FileGlyph {
    static func symbol(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "ts": return "film.fill"
        case "mp3", "flac", "m4a", "wav", "ogg", "aac", "m3u", "m3u8": return "music.note"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "raw", "tiff", "svg": return "photo.fill"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": return "archivebox.fill"
        case "pdf", "epub", "mobi": return "book.fill"
        case "txt", "md", "log", "json", "xml", "yml", "yaml", "ini", "cfg", "conf", "nfo", "srt": return "doc.text.fill"
        case "iso", "img", "bin", "dmg": return "opticaldisc.fill"
        case "gba", "gb", "gbc", "nes", "sfc", "smc", "n64", "z64", "nds", "3ds", "cia": return "gamecontroller.fill"
        case "exe", "msi", "apk", "ipa", "app", "deb", "rpm": return "shippingbox.fill"
        default: return "doc.fill"
        }
    }
}

extension View {
    /// Flexible-width block with the default 44pt minimum hit target.
    func minHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Palette.toast)
            .overlay(Capsule().stroke(Palette.hairline14, lineWidth: 0.5))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
    }
}

// MARK: - Bottom sheet

/// Dimmed backdrop + sheet sliding from the bottom (radius 34, padding 10/20/44).
struct BottomSheet<Content: View>: View {
    @Environment(\.theme) private var theme
    /// Fraction of the container height the sheet may use (nil == hug content).
    var maxHeightFraction: CGFloat? = nil
    let onDismiss: () -> Void
    @ViewBuilder let content: Content
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Palette.backdrop
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                VStack(spacing: 0) {
                    Capsule().fill(Palette.grabber).frame(width: 36, height: 5)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                    content
                }
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .padding(.bottom, max(44, geo.safeAreaInsets.bottom + 10))
                .frame(maxWidth: .infinity)
                .frame(maxHeight: maxHeightFraction.map { $0 * (geo.size.height + geo.safeAreaInsets.bottom) }, alignment: .top)
                // Size from the content so short sheets hug it and only reach
                // the cap (and scroll) when they must.
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.sheet)
                .clipShape(TopRoundedRectangle(radius: 34))
                .shadow(color: .black.opacity(0.5), radius: 20, y: -10)
                .offset(y: dragOffset)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom))
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in dragOffset = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 200 {
                    onDismiss()
                }
                withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
            }
    }
}

/// A ScrollView that is never taller than its content, so sheets hug short
/// content and only scroll when the max height clamps them.
struct HuggingScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            content()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Sheet title row: optional back button + title on the left, trailing content on the right.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var onBack: (() -> Void)? = nil
    var bottomSpacing: CGFloat = 12
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                if let onBack { BackCircleButton(action: onBack) }
                Text(title).font(Typography.sheetTitle).foregroundColor(.white)
            }
            Spacer()
            trailing
        }
        .padding(.bottom, bottomSpacing)
    }
}

/// Rounded top corners only.
struct TopRoundedRectangle: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Misc

struct CircleIconButton<Icon: View>: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 40
    let action: () -> Void
    @ViewBuilder let icon: Icon
    var body: some View {
        Button {
            ButtonHaptics.shared.tap()
            action()
        } label: {
            ZStack {
                Circle().fill(theme.chip)
                Circle().stroke(Palette.hairline08, lineWidth: 0.5)
                icon
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(ScalePressStyle())
    }
}

struct StripedPlaceholder: View {
    let stripe: Color
    var period: CGFloat = 26
    var width: CGFloat = 10
    var body: some View {
        Canvas { context, size in
            let diagonal = size.width + size.height
            var x: CGFloat = -size.height
            while x < diagonal {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + width, y: 0))
                path.addLine(to: CGPoint(x: x + width - size.height, y: size.height))
                path.addLine(to: CGPoint(x: x - size.height, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(stripe))
                x += period
            }
        }
    }
}
