import PhotosUI
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case home, queue, settings
}

enum AppRoute: Hashable {
    case slowMo(UUID)
    case interpolation(UUID)
    case interpSettings(UUID)
    case export(UUID)
    case recents
}

enum Cover: Identifiable, Equatable {
    case processing
    case done(UUID)

    var id: String {
        switch self {
        case .processing: return "processing"
        case .done(let id): return "done-\(id.uuidString)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var path: [AppRoute] = []
    @Published var cover: Cover?
    @Published var homeMode: WorkMode = .slowMo
    @Published var jobs: [ClipJob] = []
    @Published var recents: [RecentItem] = []
    @Published var isDark = true { didSet { persist() } }
    @Published var interpolation = InterpolationSettings() { didSet { persist() } }
    @Published var slow = SlowMoSettings() { didSet { persist() } }
    @Published var export = ExportSettings() { didSet { persist() } }
    @Published var progress = PipelineProgress()
    @Published var previewImage: UIImage?
    @Published var isImporting = false
    @Published var alert: String?
    @Published var logLines: [String] = []
    @Published var proResAvailable = false
    @Published var screenshot: String?
    @Published var activeJobID: UUID?

    private var task: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    let gate = PauseGate()
    private let defaults = UserDefaults.standard

    init() {
        restore()
        if let name = Self.screenshotArgument() {
            screenshot = name
            applyScreenshot(name)
        }
    }

    func job(_ id: UUID) -> ClipJob? {
        jobs.first { $0.id == id }
    }

    func mutate(_ id: UUID, _ body: (inout ClipJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    func importItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var created: [UUID] = []
        for item in items {
            do {
                guard let picked = try await item.loadTransferable(type: PickedVideo.self) else { continue }
                let info = try await VideoProbe.probe(picked.url)
                let thumb = await VideoProbe.posterJPEG(picked.url)
                var job = ClipJob(
                    sourceURL: picked.url,
                    info: info,
                    window: SourceWindow.full(info),
                    mode: homeMode,
                    slow: slow,
                    interpolation: interpolation,
                    export: export,
                    thumbnailJPEG: thumb
                )
                let notes = VideoProbe.importNotes(info)
                if !notes.isEmpty {
                    job.note = notes.joined(separator: " ")
                }
                jobs.append(job)
                created.append(job.id)
            } catch {
                alert = "Не вдалося прочитати відео. \(error.localizedDescription)"
            }
        }
        guard let first = created.first else { return }
        if created.count == 1 {
            tab = .home
            path = [homeMode == .slowMo ? .slowMo(first) : .interpolation(first)]
        } else {
            for id in created { mutate(id) { $0.status = .queued } }
            tab = .queue
            path = []
        }
    }

    func start(_ id: UUID) {
        guard screenshot == nil else { return }
        guard job(id)?.isFixture != true else { return }
        mutate(id) { $0.status = .queued }
        var order = [id]
        for other in jobs where other.status == .queued && other.id != id && !other.isFixture {
            order.append(other.id)
        }
        activeJobID = id
        progress = PipelineProgress()
        previewImage = nil
        cover = .processing
        task?.cancel()
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let pause = gate
        task = Task {
            await self.run(order, flag: flag, pause: pause)
        }
    }

    func cancelProcessing() {
        cancelFlag.cancel()
        Task { await gate.cancel() }
        log("Скасовано")
    }

    func continueAfterAnalysis() {
        Task { await gate.resume() }
    }

    func saveToPhotos(_ id: UUID) async {
        guard screenshot == nil else { return }
        guard let result = job(id)?.result, let info = job(id)?.info else { return }
        do {
            try await PhotoSave.save(
                url: result.url,
                date: export.keepMetadata ? info.creationDate : nil,
                latitude: export.keepMetadata ? info.latitude : nil,
                longitude: export.keepMetadata ? info.longitude : nil
            )
            alert = "Збережено у Фото"
        } catch {
            alert = error.localizedDescription
        }
    }

    func newProject() {
        cover = nil
        path = []
        tab = .home
    }

    func editAgain(_ id: UUID) {
        cover = nil
        tab = .home
        let mode = job(id)?.mode ?? .interpolation
        path = [mode == .slowMo ? .slowMo(id) : .interpolation(id)]
    }

    func checkHardware() {
        proResAvailable = EncoderSupport.proResAvailable()
    }

    func log(_ line: String) {
        let stamp = Self.logStamp.string(from: Date())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    private func run(_ ids: [UUID], flag: CancelFlag, pause: PauseGate) async {
        var lastDone: UUID?
        for (index, id) in ids.enumerated() {
            if flag.isCancelled { break }
            guard let snapshot = job(id) else { continue }
            mutate(id) { $0.status = .running }
            activeJobID = id
            let callbacks = PipelineCallbacks(
                progress: { [weak self] progress, image in
                    Task { @MainActor in
                        guard let self else { return }
                        var copy = progress
                        copy.queueIndex = index + 1
                        copy.queueCount = ids.count
                        self.progress = copy
                        if let image { self.previewImage = UIImage(cgImage: image) }
                    }
                },
                log: { [weak self] line in
                    Task { @MainActor in self?.log(line) }
                },
                isCancelled: { flag.isCancelled },
                pause: pause
            )
            do {
                let result = try await VideoPipeline().run(
                    job: snapshot,
                    queueIndex: index + 1,
                    queueCount: ids.count,
                    callbacks: callbacks
                )
                mutate(id) {
                    $0.status = .done
                    $0.result = result
                }
                remember(id)
                lastDone = id
            } catch is CancellationError {
                mutate(id) { $0.status = .cancelled }
                break
            } catch PipelineError.cancelled {
                mutate(id) { $0.status = .cancelled }
                break
            } catch {
                mutate(id) { $0.status = .failed(error.localizedDescription) }
                alert = error.localizedDescription
                log(error.localizedDescription)
                break
            }
        }
        if let lastDone, job(lastDone)?.status == .done {
            cover = .done(lastDone)
        } else if cover == .processing {
            cover = nil
        }
    }

    private func remember(_ id: UUID) {
        guard let job = job(id), let result = job.result else { return }
        let subtitle: String
        switch job.mode {
        case .slowMo:
            subtitle = "x\(job.slow.factor) · \(job.slow.speedLabel(for: job.slow.factor))"
        case .interpolation:
            subtitle = Format.fpsNumber(result.fps) + " fps"
        }
        let item = RecentItem(
            id: UUID(),
            title: subtitle,
            subtitle: "",
            durationLabel: String(format: "%d:%02d", Int(job.activeDuration) / 60, Int(job.activeDuration) % 60),
            thumbnailJPEG: job.thumbnailJPEG ?? previewImage?.jpegData(compressionQuality: 0.8),
            createdAt: Date()
        )
        recents.insert(item, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        persist()
    }

    private func persist() {
        guard screenshot == nil else { return }
        defaults.set(isDark, forKey: "evii.dark")
        if let data = try? JSONEncoder().encode(interpolation) { defaults.set(data, forKey: "evii.interp") }
        if let data = try? JSONEncoder().encode(slow) { defaults.set(data, forKey: "evii.slow") }
        if let data = try? JSONEncoder().encode(export) { defaults.set(data, forKey: "evii.export") }
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: "evii.recents") }
    }

    private func restore() {
        if defaults.object(forKey: "evii.dark") != nil {
            isDark = defaults.bool(forKey: "evii.dark")
        }
        if let data = defaults.data(forKey: "evii.interp"), let value = try? JSONDecoder().decode(InterpolationSettings.self, from: data) {
            interpolation = value
        }
        if let data = defaults.data(forKey: "evii.slow"), let value = try? JSONDecoder().decode(SlowMoSettings.self, from: data) {
            slow = value
        }
        if let data = defaults.data(forKey: "evii.export"), let value = try? JSONDecoder().decode(ExportSettings.self, from: data) {
            export = value
        }
        if let data = defaults.data(forKey: "evii.recents"), let value = try? JSONDecoder().decode([RecentItem].self, from: data) {
            recents = value
        }
    }

    private static func screenshotArgument() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-eviiScreenshot"), index + 1 < args.count {
            return args[index + 1]
        }
        return nil
    }

    private func applyScreenshot(_ name: String) {
        isDark = true
        let interp = ScreenshotFixtures.interpolationJob()
        let slow = ScreenshotFixtures.slowJob()
        jobs = [interp, slow]
        recents = ScreenshotFixtures.recents()
        homeMode = .slowMo
        switch name {
        case "home":
            tab = .home
            path = []
        case "queue":
            tab = .queue
            jobs = ScreenshotFixtures.queueJobs()
            path = []
        case "settings":
            tab = .settings
            path = []
            logLines = ["9:41  RIFE 4.25 · FP16/FP32", "9:41  Готово до черги"]
        case "slowmo":
            tab = .home
            path = [.slowMo(slow.id)]
        case "interpolation":
            tab = .home
            path = [.interpolation(interp.id)]
        case "interp-settings":
            tab = .home
            path = [.interpolation(interp.id), .interpSettings(interp.id)]
        case "export":
            tab = .home
            path = [.interpolation(interp.id), .export(interp.id)]
        case "processing":
            tab = .home
            path = []
            activeJobID = interp.id
            progress = ScreenshotFixtures.progress()
            cover = .processing
        case "done":
            var done = interp
            done.result = ScreenshotFixtures.result()
            done.status = .done
            jobs = [done, slow]
            activeJobID = done.id
            cover = .done(done.id)
        case "unsupported":
            tab = .home
            path = []
            alert = "Не вдалося прочитати відео. У файлі немає відеодоріжки."
        default:
            tab = .home
        }
    }

    private static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
