import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.evii) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Налаштування")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)

                EviiCard {
                    ToggleRow(title: "Темна тема", subtitle: "Один лаймовий акцент на чорному", isOn: $model.isDark)
                }

                EviiCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Evii Frames 0.1.1")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Кліпи до 30 секунд. Інтерполяція на цьому iPhone, без хмари. Назва тимчасова.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.secondary)
                        Text("Цільовий телефон — iPhone 14 Pro, A16, 6 ГБ, iOS 27. Мінімальна версія застосунку — iOS 17, верхньої межі немає. Вихід за замовчуванням — 1080p, щоб активація вмістилась у 6 ГБ. 4K і оригінал не зменшують кадр: для них зібрані пакети 2176×3840 і 3840×2176. Якщо застосунок закриється на 4K, поверніть 1080p.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.secondary)
                        Text(appleNote)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.secondary)
                        Text("Моделі на вибір, усі MIT (Practical-RIFE, не GPL): RIFE 4.25, 4.26, 4.26 heavy, 4.25 lite, 4.22. Типова — 4.25, бо автор відзначає краще аніме. Згортки FP16, варп FP32, спочатку Neural Engine. Окремий FP32 не веземо: на плавному зсуві округлення ваг дає близько 0.00001 і не помітне. «Максимальна якість» — чотири дзеркальні проходи, близько ×4 часу.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.secondary)
                        Text(model.proResAvailable ? "ProRes на цьому пристрої доступний." : "ProRes тут недоступний — лишаються HEVC і H.264.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.secondary)
                    }
                }

                SectionLabel(text: "ЖУРНАЛ")
                EviiCard {
                    if model.logLines.isEmpty {
                        Text("Тут з’являться кроки обробки.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.logLines.suffix(40).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(theme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var appleNote: String {
        if AppleFrameRate.isRuntimeSupported {
            return "VTFrameRateConversion isSupported на цьому iPhone. Сесію процесора v0.1 ще не відкриває."
        }
        return "VTFrameRateConversion на цьому пристрої: isSupported == false. Застосунок його не викликає."
    }
}
