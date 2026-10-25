import SwiftUI
import UIKit

struct DoneView: View {
    var jobID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme
    @State private var wipe: CGFloat = 0.5
    @State private var mode: CompareMode = .side

    private enum CompareMode: String, CaseIterable, Identifiable {
        case side, before, after, quarter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .side: return "Поруч"
            case .before: return "До"
            case .after: return "Після"
            case .quarter: return "0.25x"
            }
        }
    }

    var body: some View {
        Group {
            if let job = model.job(jobID), let result = job.result {
                content(job, result)
            } else {
                Text("Немає результату")
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
            }
        }
    }

    private func content(_ job: ClipJob, _ result: JobResult) -> some View {
        let shown = reveal
        return VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text("Готово")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Spacer()
                    Button("Нове") { model.newProject() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.lime)
                }
            }
            .foregroundStyle(theme.text)

            WipeCompare(
                before: UIImage(data: job.thumbnailJPEG ?? Data()),
                after: model.previewImage,
                position: shown
            )
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack {
                Text("До · \(Format.fps(job.info.fps))")
                Spacer()
                Text("Після · \(Format.fps(result.fps))")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.secondary)

            HStack(spacing: 8) {
                ForEach(CompareMode.allCases) { item in
                    PillChoice(title: item.title, selected: mode == item, lime: item == .quarter) {
                        mode = item
                        switch item {
                        case .side: wipe = 0.5
                        case .before: wipe = 0
                        case .after, .quarter: wipe = 1
                        }
                    }
                }
            }
            if mode == .quarter {
                Text("0.25x — це позначка швидкості перегляду. Порівняння тут зі стілів; ролик відкриється у Фото.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiary)
            }

            EviiCard {
                VStack(alignment: .leading, spacing: 12) {
                    infoRow("Файл", result.filename)
                    infoRow("Результат", "\(Format.clock(result.duration)) · \(result.frameCount) кадрів")
                    infoRow("Розмір · час", "\(Format.megabytes(result.fileSize)) · \(elapsed(result.elapsed))")
                }
            }

            PrimaryButton(title: "Зберегти у Фото", systemImage: "square.and.arrow.down") {
                Task { await model.saveToPhotos(jobID) }
            }

            HStack(spacing: 10) {
                ShareLink(item: result.url) {
                    Label("Поділитись", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(theme.card, in: Capsule())
                }
                Button {
                    model.editAgain(jobID)
                } label: {
                    Label("Змінити", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(theme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("edit-again")
            }
            .foregroundStyle(theme.text)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(theme.bg.ignoresSafeArea())
    }

    private var reveal: CGFloat {
        switch mode {
        case .side: return wipe
        case .before: return 0
        case .after, .quarter: return 1
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 15))
        .foregroundStyle(theme.text)
    }

    private func elapsed(_ seconds: Double) -> String {
        if seconds < 90 { return "\(max(1, Int(seconds.rounded()))) с" }
        return Format.clock(seconds, decimals: 0)
    }
}

private struct WipeCompare: View {
    var before: UIImage?
    var after: UIImage?
    var position: CGFloat
    @Environment(\.evii) private var theme

    var body: some View {
        GeometryReader { geo in
            let x = min(max(0, position), 1) * geo.size.width
            ZStack(alignment: .leading) {
                side(before, dim: true)
                side(after, dim: false)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: max(0, geo.size.width - x))
                    }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .position(x: x, y: geo.size.height / 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(theme.ink.opacity(0.2), lineWidth: 1))
                    .position(x: x, y: geo.size.height / 2)
            }
        }
    }

    @ViewBuilder
    private func side(_ image: UIImage?, dim: Bool) -> some View {
        if let image, image.size.width > 2 {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FrameArt(dim: dim)
        }
    }
}
