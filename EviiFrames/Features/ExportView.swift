import SwiftUI

struct ExportView: View {
    var jobID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme
    @State private var showDuration = false
    @State private var showName = false
    @State private var draftName = "{name}_{fps}fps"

    var body: some View {
        Group {
            if let job = model.job(jobID) {
                form(job)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .eviiChrome("Експорт")
    }

    private func form(_ job: ClipJob) -> some View {
        let plan = Planner.plan(job.planRequest())
        let bytes = Timing.estimatedBytes(
            width: job.outputPixelSize().width,
            height: job.outputPixelSize().height,
            frames: plan.samples.count,
            quality: job.export.quality,
            codec: job.export.codec
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(text: "КОДЕК")
                HStack(spacing: 8) {
                    ForEach(CodecChoice.allCases) { codec in
                        PillChoice(title: codec.title, selected: job.export.codec == codec) {
                            guard codec != .prores || model.proResAvailable || model.screenshot != nil else {
                                model.alert = "ProRes на цьому пристрої недоступний."
                                return
                            }
                            model.mutate(jobID) {
                                $0.export.codec = codec
                                if codec == .prores { $0.export.container = .mov }
                            }
                            model.export.codec = codec
                        }
                    }
                }
                Text("ProRes — лише на Pro-моделях iPhone")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)

                EviiCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Якість").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text(Format.megabytes(bytes, approximate: true))
                                .foregroundStyle(theme.secondary)
                        }
                        Slider(value: quality, in: 1...100).tint(theme.lime)
                        HStack {
                            Text("менший файл")
                            Spacer()
                            Text("\(Int(job.export.quality.rounded()))")
                            Spacer()
                            Text("краще")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondary)
                    }
                }

                SectionLabel(text: "КОНТЕЙНЕР")
                HStack(spacing: 8) {
                    ForEach(ContainerChoice.allCases) { container in
                        PillChoice(title: container.title, selected: job.export.resolvedContainer == container) {
                            model.mutate(jobID) { $0.export.container = container }
                        }
                    }
                }

                SectionLabel(text: "МАКС. ЧАСТОТА ВИХОДУ")
                HStack(spacing: 8) {
                    ForEach(MaxFPSChoice.allCases) { choice in
                        PillChoice(title: choice.title, selected: job.export.maxFPS == choice) {
                            model.mutate(jobID) { $0.export.maxFPS = choice }
                        }
                    }
                }

                SectionLabel(text: "МАКС. РОЗДІЛЬНІСТЬ")
                HStack(spacing: 8) {
                    ForEach(MaxResolution.allCases) { choice in
                        PillChoice(title: choice.title, selected: job.export.maxResolution == choice) {
                            model.mutate(jobID) { $0.export.maxResolution = choice }
                        }
                    }
                }

                EviiCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ToggleRow(title: "Зберегти звук", isOn: audio)
                        ToggleRow(title: "Зберегти метадані", subtitle: "Дата і місце зйомки", isOn: meta)
                        Button {
                            showDuration = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Мін. тривалість").font(.system(size: 16, weight: .semibold))
                                    Text("Зациклити до N секунд").font(.system(size: 13)).foregroundStyle(theme.secondary)
                                }
                                Spacer()
                                Text(durationTitle(job.export.minimumDuration))
                                    .foregroundStyle(theme.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(theme.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            draftName = job.export.filenamePattern
                            showName = true
                        } label: {
                            HStack {
                                Text("Назва файлу").font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Text(job.export.filenamePattern)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .confirmationDialog("Мінімальна тривалість", isPresented: $showDuration, titleVisibility: .visible) {
            ForEach(ExportSettings.minimumDurationPresets, id: \.self) { preset in
                Button(durationTitle(preset)) {
                    model.mutate(jobID) { $0.export.minimumDuration = preset }
                }
            }
        }
        .alert("Назва файлу", isPresented: $showName) {
            TextField("{name}_{fps}fps", text: $draftName)
            Button("Гаразд") {
                let pattern = draftName.trimmingCharacters(in: .whitespaces)
                model.mutate(jobID) { $0.export.filenamePattern = pattern.isEmpty ? "{name}_{fps}fps" : pattern }
                model.export.filenamePattern = pattern
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Токени: {name} {fps} {factor}")
        }
    }

    private var quality: Binding<Double> {
        Binding(
            get: { model.job(jobID)?.export.quality ?? 75 },
            set: { value in model.mutate(jobID) { $0.export.quality = value } }
        )
    }

    private var audio: Binding<Bool> {
        Binding(
            get: { model.job(jobID)?.export.keepAudio ?? true },
            set: { value in model.mutate(jobID) { $0.export.keepAudio = value } }
        )
    }

    private var meta: Binding<Bool> {
        Binding(
            get: { model.job(jobID)?.export.keepMetadata ?? true },
            set: { value in model.mutate(jobID) { $0.export.keepMetadata = value } }
        )
    }

    private func durationTitle(_ value: Double?) -> String {
        guard let value else { return "Вимк." }
        return "\(Int(value)) с"
    }
}
