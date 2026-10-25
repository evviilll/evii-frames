import SwiftUI
import UIKit

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        let job = model.activeJobID.flatMap { model.job($0) }
        let progress = model.progress
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Text("Обробка")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Spacer()
                    Button("Скасувати") { model.cancelProcessing() }
                        .font(.system(size: 17))
                        .foregroundStyle(theme.text)
                        .accessibilityIdentifier("cancel-processing")
                }
            }
            .foregroundStyle(theme.text)
            .padding(.top, 8)

            ZStack(alignment: .topLeading) {
                if let image = model.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    FrameArt()
                }
                if let t = progress.timestep {
                    Text(String(format: "згенерований кадр · t = %.2f", t))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondary)
                        .padding(12)
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                Text("\(percent)%")
                    .font(.system(size: 48, weight: .bold))
                Spacer()
                Text(etaText)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.secondary)
            }
            .foregroundStyle(theme.text)

            ProgressView(value: min(1, max(0, progress.fraction)))
                .tint(theme.lime)

            HStack {
                Text(progress.frameCount > 0 ? "Кадр \(progress.frameIndex) / \(progress.frameCount)" : "Кадр —")
                Spacer()
                Text(progress.framesPerSecond > 0.05 ? String(format: "%.1f кадр/с", progress.framesPerSecond) : " ")
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.secondary)

            EviiCard {
                VStack(alignment: .leading, spacing: 16) {
                    step(
                        state: stepState(0),
                        title: "Аналіз",
                        detail: analysisDetail
                    )
                    step(
                        state: stepState(1),
                        title: "Інтерполяція",
                        detail: interpolationDetail(job)
                    )
                    step(
                        state: stepState(2),
                        title: "Кодування",
                        detail: encodingDetail(job)
                    )
                }
            }

            if progress.phase == .paused {
                PrimaryButton(title: "Далі", systemImage: "play.fill") {
                    model.continueAfterAnalysis()
                }
                Text("Аналіз готовий. Інтерполяція чекає підтвердження.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
            }

            Spacer()
            Text(queueCaption)
                .font(.system(size: 13))
                .foregroundStyle(theme.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(theme.bg.ignoresSafeArea())
    }

    private var percent: Int {
        Int((model.progress.fraction * 100).rounded())
    }

    private var etaText: String {
        guard let eta = model.progress.eta, eta.isFinite else { return "рахуємо час" }
        if eta < 90 { return "≈ \(max(1, Int(eta.rounded()))) с лишилось" }
        let minutes = max(1, Int((eta / 60).rounded()))
        return "≈ \(minutes) хв лишилось"
    }

    private var analysisDetail: String {
        let progress = model.progress
        let frames = progress.sourceFrames > 0 ? "\(progress.sourceFrames) кадрів" : "кадри"
        return "\(frames) · \(Ukrainian.scenes(progress.sceneCuts)) · \(Ukrainian.duplicates(progress.duplicates))"
    }

    private func interpolationDetail(_ job: ClipJob?) -> String {
        guard let job else { return "RIFE 4.25" }
        let plan = Planner.plan(job.planRequest(
            frames: model.progress.sourceFrames > 0 ? model.progress.sourceFrames : nil,
            cuts: [],
            duplicates: []
        ))
        let factor: String
        switch job.mode {
        case .slowMo:
            factor = "x\(job.slow.factor)"
        case .interpolation:
            factor = job.interpolation.useTargetFPS ? "\(Format.fpsNumber(job.interpolation.targetFPS)) fps" : "x\(job.interpolation.multiplier)"
        }
        return "\(job.interpolation.resolvedModel().title) · \(factor) → \(Format.fps(plan.outputFPS))"
    }

    private func encodingDetail(_ job: ClipJob?) -> String {
        guard let job else { return "HEVC · MOV" }
        let audio = job.export.keepAudio && job.info.hasAudio ? "зі звуком" : "без звуку"
        return "\(job.export.codec.title) · \(job.export.resolvedContainer.title) · \(audio)"
    }

    private var queueCaption: String {
        let progress = model.progress
        if progress.queueCount > 1 {
            return "Черга: \(progress.queueIndex) з \(progress.queueCount) · час — оцінка"
        }
        return "Час — оцінка"
    }

    private enum StepState { case done, active, idle }

    private func stepState(_ index: Int) -> StepState {
        let order: Int
        switch model.progress.phase {
        case .analysis, .paused: order = 0
        case .interpolation: order = 1
        case .encoding: order = 2
        case .finished: order = 3
        }
        if index < order { return .done }
        if index == order { return .active }
        return .idle
    }

    private func step(state: StepState, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepIcon(state)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state == .idle ? theme.secondary : theme.text)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(theme.lime)
        case .active:
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(theme.lime, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 18, height: 18)
        case .idle:
            Circle()
                .stroke(theme.tertiary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }
}
