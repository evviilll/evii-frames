import PhotosUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme
    @State private var picker: [PhotosPickerItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evii Frames")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(theme.text)
                        Text("ШІ домалює проміжні кадри. Усе на телефоні.\nНазва тимчасова")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    ThemeButton()
                        .padding(.top, 8)
                }

                modeCard(
                    mode: .slowMo,
                    title: "Сповільнення",
                    subtitle: "Швидко: x2 · x4 · x8, весь кліп або фрагмент",
                    symbol: "gauge.with.needle"
                )
                modeCard(
                    mode: .interpolation,
                    title: "Інтерполяція",
                    subtitle: "x2–x16 або цільовий FPS, усі налаштування",
                    symbol: "rectangle.stack"
                )

                PhotosPicker(selection: $picker, maxSelectionCount: 8, matching: .videos) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                        Text("Вибрати відео")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(theme.lime, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isImporting)
                .overlay {
                    if model.isImporting { ProgressView().tint(theme.ink) }
                }

                Text("До 30 с · можна кілька — оброблю чергою")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity)

                HStack {
                    SectionLabel(text: "НЕЩОДАВНІ")
                    Spacer()
                    Button("Усі") { model.path.append(.recents) }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.secondary)
                }
                if model.recents.isEmpty {
                    Text("Тут з’являться оброблені кліпи")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.recents) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .topLeading) {
                                        Thumb(data: item.thumbnailJPEG)
                                        Text(item.durationLabel)
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                                            .padding(8)
                                    }
                                    .frame(width: 112, height: 148)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(theme.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: picker) { _, items in
            let batch = items
            picker = []
            Task { await model.importItems(batch) }
        }
    }

    private func modeCard(mode: WorkMode, title: String, subtitle: String, symbol: String) -> some View {
        Button {
            model.homeMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.tertiary)
            }
            .foregroundStyle(theme.text)
            .padding(14)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(model.homeMode == mode ? theme.lime : theme.hairline, lineWidth: model.homeMode == mode ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(mode == .slowMo ? "mode-slow" : "mode-interp")
    }
}

struct RecentsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if model.recents.isEmpty {
                    Text("Нещодавніх ще немає")
                        .foregroundStyle(theme.secondary)
                        .padding(.top, 40)
                }
                ForEach(model.recents) { item in
                    HStack(spacing: 12) {
                        Thumb(data: item.thumbnailJPEG)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 16, weight: .semibold))
                            Text(item.durationLabel).font(.system(size: 13)).foregroundStyle(theme.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(theme.bg.ignoresSafeArea())
        .eviiChrome("Нещодавні")
    }
}
