import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Черга")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
                Text("Кілька кліпів ідуть один за одним. Ліміт кожного — 30 с.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.secondary)

                if model.jobs.isEmpty {
                    Text("Черга порожня. На головній можна вибрати кілька відео.")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.tertiary)
                        .padding(.top, 12)
                } else {
                    ForEach(model.jobs) { job in
                        jobCard(job)
                    }
                    if let next = model.jobs.first(where: { $0.status == .queued || $0.status == .draft }) {
                        PrimaryButton(title: "Старт черги", systemImage: "play.fill") {
                            model.start(next.id)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func jobCard(_ job: ClipJob) -> some View {
        HStack(spacing: 12) {
            Thumb(data: job.thumbnailJPEG)
                .frame(width: 64, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(subtitle(job))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
                Text(status(job))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(job.status == .running ? theme.lime : theme.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func subtitle(_ job: ClipJob) -> String {
        switch job.mode {
        case .slowMo:
            return "Сповільнення · x\(job.slow.factor) · \(job.slow.speedLabel(for: job.slow.factor))"
        case .interpolation:
            let factor = job.interpolation.useTargetFPS ? "\(Format.fpsNumber(job.interpolation.targetFPS)) fps" : "x\(job.interpolation.multiplier)"
            return "Інтерполяція · \(factor)"
        }
    }

    private func status(_ job: ClipJob) -> String {
        switch job.status {
        case .draft: return "Чернетка"
        case .queued: return "У черзі"
        case .running: return "Обробляється"
        case .done: return "Готово"
        case .failed(let reason): return reason
        case .cancelled: return "Скасовано"
        }
    }
}
