import SwiftUI

struct InterpolationView: View {
    var jobID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    private var job: ClipJob? { model.job(jobID) }

    var body: some View {
        Group {
            if let job {
                content(job)
            } else {
                Text("Кліп не знайдено").foregroundStyle(theme.secondary)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .eviiChrome("Інтерполяція")
    }

    private func content(_ job: ClipJob) -> some View {
        let plan = Planner.plan(job.planRequest())
        let hint = Timing.runtimeHint(
            sourceFrames: job.activeFrameCount,
            outputFrames: plan.samples.count,
            width: job.outputPixelSize().width,
            height: job.outputPixelSize().height
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(job)
                SectionLabel(text: "ВХІД")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(title: "Роздільність", value: Format.resolution(job.info.width, job.info.height))
                    StatTile(title: "Частота", value: Format.fps(job.info.fps))
                    StatTile(title: "Тривалість", value: Format.clock(job.activeDuration))
                    StatTile(title: "Кадрів", value: "\(job.activeFrameCount)")
                }
                if let note = job.note {
                    Text(note).font(.system(size: 13)).foregroundStyle(theme.secondary)
                }
                HStack(spacing: 8) {
                    PillChoice(title: "Множник", selected: !job.interpolation.useTargetFPS) {
                        model.mutate(jobID) { $0.interpolation.useTargetFPS = false }
                    }
                    PillChoice(title: "Цільовий FPS", selected: job.interpolation.useTargetFPS) {
                        model.mutate(jobID) { $0.interpolation.useTargetFPS = true }
                    }
                }
                if job.interpolation.useTargetFPS {
                    HStack(spacing: 8) {
                        ForEach([48.0, 60, 90, 120, 240], id: \.self) { fps in
                            PillChoice(title: Format.fpsNumber(fps), selected: job.interpolation.targetFPS == fps, lime: true) {
                                model.mutate(jobID) { $0.interpolation.targetFPS = fps }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(job.interpolation.multiplierChoices, id: \.self) { factor in
                            PillChoice(title: "x\(factor)", selected: job.interpolation.multiplier == factor, lime: true) {
                                model.mutate(jobID) { $0.interpolation.multiplier = factor }
                            }
                        }
                    }
                }
                if job.interpolation.multiplier == 16 && !job.interpolation.useTargetFPS {
                    Text("x16 довго і гріє телефон. Застосунок має лишатися відкритим.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondary)
                }
                outputCard(job, plan: plan)
                EviiCard {
                    VStack(spacing: 4) {
                        NavRow(title: "Модель", value: "\(job.interpolation.resolvedModel().title) · Найкраща") {
                            model.path.append(.interpSettings(jobID))
                        }
                        NavRow(title: "Інтерполяція", value: summary(job)) {
                            model.path.append(.interpSettings(jobID))
                        }
                        NavRow(title: "Експорт", value: "\(job.export.codec.title) · \(job.export.resolvedContainer.title)") {
                            model.path.append(.export(jobID))
                        }
                    }
                }
                PrimaryButton(title: "Старт  ·  \(Timing.formatRuntime(low: hint.low, high: hint.high))", systemImage: "play.fill") {
                    model.start(jobID)
                }
            }
            .padding(16)
        }
    }

    private func header(_ job: ClipJob) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Thumb(data: job.thumbnailJPEG)
                Text(short(job.activeDuration))
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.info.filename + ".MOV")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("\(job.info.codecLabel) · \(Format.megabytes(job.info.fileSize)) · \(job.info.hasAudio ? "зі звуком" : "без звуку")")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
            }
            Spacer()
        }
    }

    private func short(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func outputCard(_ job: ClipJob, plan: Plan) -> some View {
        EviiCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("ВИХІД")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.fpsNumber(plan.outputFPS))
                        .font(.system(size: 40, weight: .bold))
                    Text("fps")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(plan.samples.count) кадрів")
                            .font(.system(size: 15, weight: .semibold))
                        Text(job.limitCaption())
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondary)
                    }
                }
                .foregroundStyle(theme.text)
            }
        }
    }

    private func summary(_ job: ClipJob) -> String {
        let scene = job.interpolation.skipSceneChanges ? "Сцени" : "Без сцен"
        let dedup: String
        switch job.interpolation.dedup {
        case .off: dedup = "без дедупл."
        case .fast: dedup = "дедупл."
        case .accurate: dedup = "дедупл. точно"
        }
        return "\(scene) · \(dedup)"
    }
}

struct InterpolationSettingsView: View {
    var jobID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        Group {
            if let job = model.job(jobID) {
                form(job)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .eviiChrome("Інтерполяція")
    }

    private func form(_ job: ClipJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(text: "МОДЕЛЬ")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(ModelChoice.allCases) { choice in
                        PillChoice(title: choice.title, selected: job.interpolation.model == choice, lime: choice == .rife425) {
                            model.mutate(jobID) { $0.interpolation.model = choice }
                        }
                    }
                }
                Text(modelNote(job))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)

                EviiCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ToggleRow(
                            title: "Пропускати зміну сцени",
                            subtitle: "Не «морфити» між різними кадрами",
                            isOn: binding(\.skipSceneChanges)
                        )
                        sliderBlock(
                            title: "Чутливість",
                            value: bindingDouble(\.sceneSensitivity),
                            range: 0...1,
                            leading: "низька",
                            trailing: "висока",
                            center: "\(Int((job.interpolation.sceneSensitivity * 100).rounded()))%"
                        )
                    }
                }

                EviiCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Дедуплікація кадрів")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Для аніме/2D. Для відео з камери — вимкнути")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondary)
                        HStack(spacing: 8) {
                            ForEach(DedupMode.allCases) { mode in
                                PillChoice(title: mode.title, selected: job.interpolation.dedup == mode) {
                                    model.mutate(jobID) { $0.interpolation.dedup = mode }
                                }
                            }
                        }
                        sliderBlock(
                            title: "",
                            value: bindingDouble(\.dedupThresholdPercent),
                            range: 0...5,
                            leading: "0%",
                            trailing: "5%",
                            center: String(format: "поріг %.1f%%", job.interpolation.dedupThresholdPercent),
                            enabled: job.interpolation.dedup != .off
                        )
                    }
                }

                EviiCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ToggleRow(title: "Зациклити", subtitle: "Інтерполяція з кінця на початок", isOn: binding(\.loop))
                        ToggleRow(
                            title: "Максимальна якість",
                            subtitle: "Усереднення дзеркал, близько ×4 часу",
                            isOn: binding(\.maximumQuality)
                        )
                        Text("Чотири проходи однієї моделі: кадр, горизонталь, вертикаль і обидва. Телефон має лишатися відкритим і нагріється. Офіційний ensemble у вагах від 4.21 нічого не робить — це зовнішнє усереднення.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.tertiary)
                        ToggleRow(title: "Режим UHD", subtitle: "Офіційний scale 0.5: швидше, менше деталей", isOn: binding(\.uhd))
                        Text("Не зібрано. Для 4K є пакети 2176×3840 і 3840×2176 — їх вмикає ліміт роздільності, не цей перемикач.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.tertiary)
                    }
                }

                SectionLabel(text: "ОБРОБКА")
                HStack(spacing: 8) {
                    ForEach(ProcessStyle.allCases) { style in
                        PillChoice(title: style.title, selected: job.interpolation.style == style) {
                            model.mutate(jobID) { $0.interpolation.style = style }
                        }
                    }
                }
                Text("Покроково: зупинка після аналізу сцен і дублікатів")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
            }
            .padding(16)
        }
    }

    private func modelNote(_ job: ClipJob) -> String {
        switch job.interpolation.model {
        case .rife425:
            return "Типовий вибір, MIT. У Practical-RIFE саме 4.25 покращила аніме. Окремої аніме-моделі з вільною ліцензією немає."
        case .rife426:
            return "Ті самі 5 блоків, що в 4.25. Новіші ваги від 21 вересня 2024. MIT."
        case .rife426Heavy:
            return "RIFE 4.26 heavy: контекст 16 каналів замість 4. Важча і повільніша. MIT."
        case .rife422:
            return "RIFE 4.22: чотири ширші блоки. Автор радив її для дифузійного відео. MIT."
        case .rifeLite:
            return "RIFE 4.25 lite: вужчий останній блок, піраміда 32…1. Менше обчислень, не максимум якості. MIT."
        case .apple:
            if AppleFrameRate.isRuntimeSupported {
                return "isSupported == true. Сесію VTFrameProcessor не відкриваю, старт візьме RIFE 4.25."
            }
            return "isSupported == false на цьому iPhone. Старт візьме RIFE 4.25."
        }
    }

    private func binding(_ keyPath: WritableKeyPath<InterpolationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.job(jobID)?.interpolation[keyPath: keyPath] ?? false },
            set: { newValue in model.mutate(jobID) { $0.interpolation[keyPath: keyPath] = newValue } }
        )
    }

    private func bindingDouble(_ keyPath: WritableKeyPath<InterpolationSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.job(jobID)?.interpolation[keyPath: keyPath] ?? 0 },
            set: { newValue in model.mutate(jobID) { $0.interpolation[keyPath: keyPath] = newValue } }
        )
    }

    private func sliderBlock(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        leading: String,
        trailing: String,
        center: String,
        enabled: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.system(size: 15, weight: .medium))
            }
            Slider(value: value, in: range).tint(enabled ? theme.lime : theme.tertiary).disabled(!enabled)
            HStack {
                Text(leading)
                Spacer()
                Text(center)
                Spacer()
                Text(trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondary)
        }
    }
}
