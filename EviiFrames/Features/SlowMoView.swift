import SwiftUI

struct SlowMoView: View {
    var jobID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme
    @State private var showAudio = false

    var body: some View {
        Group {
            if let job = model.job(jobID) {
                content(job)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .eviiChrome("Сповільнення") {
            Button("Далі") { model.start(jobID) }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.lime)
                .accessibilityIdentifier("slowmo-next")
        }
    }

    private func content(_ job: ClipJob) -> some View {
        let fragment = job.slow.fragmentSeconds(duration: job.activeDuration)
        let duration = Timing.slowMoDuration(
            clip: job.activeDuration,
            fragment: job.slow.wholeClip ? nil : fragment,
            factor: job.slow.factor
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Thumb(data: job.thumbnailJPEG)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("\(min(job.info.width, job.info.height) >= 1000 ? "1080p" : "\(job.info.height)p") · \(Format.fps(job.info.fps)) · \(short(job.activeDuration))")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(8)
                }

                SectionLabel(text: "ЩО СПОВІЛЬНИТИ")
                HStack(spacing: 8) {
                    PillChoice(title: "Весь кліп", selected: job.slow.wholeClip) {
                        model.mutate(jobID) { $0.slow.wholeClip = true }
                    }
                    PillChoice(title: "Фрагмент", selected: !job.slow.wholeClip) {
                        model.mutate(jobID) { $0.slow.wholeClip = false }
                    }
                }
                Filmstrip(
                    duration: job.activeDuration,
                    start: startBinding,
                    end: endBinding,
                    enabled: !job.slow.wholeClip
                )

                SectionLabel(text: "НАСКІЛЬКИ")
                HStack(spacing: 8) {
                    ForEach(job.slow.factorChoices, id: \.self) { factor in
                        PillChoice(
                            title: "x\(factor)",
                            subtitle: job.slow.speedLabel(for: factor),
                            selected: job.slow.factor == factor,
                            lime: true
                        ) {
                            model.mutate(jobID) { $0.slow.factor = factor }
                        }
                    }
                }

                Button { showAudio = true } label: {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Звук у фрагменті")
                        Spacer()
                        Text(job.slow.fragmentAudio.title).foregroundStyle(theme.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(theme.tertiary)
                    }
                    .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.plain)

                HStack {
                    Text("Результат")
                        .foregroundStyle(theme.secondary)
                    Spacer()
                    Text("\(Format.approxClock(duration)) · \(Format.fps(job.info.fps))")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(16)
            .foregroundStyle(theme.text)
        }
        .confirmationDialog("Звук у фрагменті", isPresented: $showAudio, titleVisibility: .visible) {
            ForEach(FragmentAudio.allCases) { mode in
                Button(mode.title) { model.mutate(jobID) { $0.slow.fragmentAudio = mode } }
            }
        } message: {
            Text("Вимкнено прибирає звук лише зі сповільненої частини. Розтягнути зберігає його з нижчим тоном.")
        }
    }

    private var startBinding: Binding<Double> {
        Binding(
            get: { model.job(jobID)?.slow.fragmentStart ?? 0.3 },
            set: { value in
                model.mutate(jobID) {
                    $0.slow.fragmentStart = min(value, $0.slow.fragmentEnd - 0.05)
                }
            }
        )
    }

    private var endBinding: Binding<Double> {
        Binding(
            get: { model.job(jobID)?.slow.fragmentEnd ?? 0.75 },
            set: { value in
                model.mutate(jobID) {
                    $0.slow.fragmentEnd = max(value, $0.slow.fragmentStart + 0.05)
                }
            }
        )
    }

    private func short(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct Filmstrip: View {
    var duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var enabled: Bool
    @Environment(\.evii) private var theme

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<28, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(theme.cardRaised)
                                .frame(height: 18 + CGFloat((index * 17) % 28))
                        }
                    }
                    .frame(height: 64)
                    if enabled {
                        let x = width * start
                        let w = max(24, width * (end - start))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.lime, lineWidth: 2)
                            .background(theme.lime.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                            .frame(width: w, height: 72)
                            .offset(x: x)
                            .overlay(alignment: .top) {
                                Text(String(format: "фрагмент %.1f с", duration * max(0, end - start)))
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.lime, in: Capsule())
                                    .foregroundStyle(theme.ink)
                                    .offset(y: -10)
                            }
                            .gesture(DragGesture().onChanged { value in
                                let delta = value.translation.width / width
                                let length = end - start
                                var next = start + delta
                                next = min(max(0, next), 1 - length)
                                start = next
                                end = next + length
                            })
                    }
                }
            }
            .frame(height: 84)
            HStack {
                Text(Format.clock(duration * start, decimals: 1))
                Spacer()
                Text(Format.clock(duration * end, decimals: 1))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.secondary)
        }
        .opacity(enabled ? 1 : 0.45)
    }
}
