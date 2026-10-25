import SwiftUI
import UIKit

struct FrameArt: View {
    var dim: Bool = false
    @Environment(\.evii) private var theme

    var body: some View {
        ZStack {
            theme.cardRaised
            Archway()
                .fill(dim ? Color(hex: 0x3A3B3E) : Color(hex: 0x4A4C50))
                .padding(.horizontal, 54)
                .padding(.vertical, 28)
        }
    }
}

struct Archway: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width * 0.72
        let height = rect.height * 0.78
        let x = rect.midX - width / 2
        let y = rect.maxY - height - rect.height * 0.04
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: x, y: y + height * 0.42, width: width, height: height * 0.58),
            cornerSize: CGSize(width: 18, height: 18)
        )
        path.addEllipse(in: CGRect(x: x, y: y, width: width, height: width * 0.92))
        return path
    }
}

struct PrimaryButton: View {
    var title: String
    var systemImage: String? = nil
    var action: () -> Void
    @Environment(\.evii) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(theme.lime, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title.hasPrefix("Старт") ? "start-button" : "primary-button")
    }
}

struct SectionLabel: View {
    var text: String
    @Environment(\.evii) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
            .accessibilityIdentifier("section-\(text)")
    }
}

struct EviiCard<Content: View>: View {
    var stroke: Bool = false
    @ViewBuilder var content: () -> Content
    @Environment(\.evii) private var theme

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(stroke ? theme.lime : theme.hairline, lineWidth: stroke ? 1.5 : 1)
            )
    }
}

struct PillChoice: View {
    var title: String
    var subtitle: String? = nil
    var selected: Bool
    var lime: Bool = false
    var action: () -> Void
    @Environment(\.evii) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(selected && lime ? theme.ink : theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: subtitle == nil ? 40 : 52)
            .background(
                selected ? (lime ? theme.lime : theme.cardRaised) : theme.card,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title)
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @Environment(\.evii) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(theme.lime)
                .accessibilityLabel(title)
                .accessibilityIdentifier("toggle-\(title)")
        }
    }
}

struct NavRow: View {
    var title: String
    var value: String
    var action: () -> Void
    @Environment(\.evii) private var theme

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nav-\(title)")
    }
}

struct StatTile: View {
    var title: String
    var value: String
    @Environment(\.evii) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ScreenBackButton: View {
    var action: () -> Void
    @Environment(\.evii) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                Text("Назад")
                    .font(.system(size: 17))
            }
            .foregroundStyle(theme.text)
        }
    }
}

struct ThemeButton: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        Button {
            model.isDark.toggle()
        } label: {
            Image(systemName: "sun.max")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.text)
        }
        .accessibilityIdentifier("theme-toggle")
        .accessibilityLabel("Тема")
    }
}

struct Chrome: ViewModifier {
    var title: String
    var trailing: AnyView?
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ScreenBackButton { if !model.path.isEmpty { model.path.removeLast() } }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let trailing {
                        trailing
                    } else {
                        ThemeButton()
                    }
                }
            }
            .toolbarBackground(theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

extension View {
    func eviiChrome(_ title: String) -> some View {
        modifier(Chrome(title: title, trailing: nil))
    }

    func eviiChrome<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(Chrome(title: title, trailing: AnyView(trailing())))
    }
}

struct Thumb: View {
    var data: Data?
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                FrameArt()
            }
        }
    }
}
