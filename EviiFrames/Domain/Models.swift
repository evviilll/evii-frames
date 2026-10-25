import Foundation

enum WorkMode: String, Codable, CaseIterable, Identifiable {
    case slowMo
    case interpolation

    var id: String { rawValue }
}

enum ModelChoice: String, Codable, CaseIterable, Identifiable {
    case rife425
    case rifeLite
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rife425: return "RIFE 4.25"
        case .rifeLite: return "RIFE lite"
        case .apple: return "Apple"
        }
    }

    /// RIFE lite has no package. Apple FRC runs only when this phone's
    /// VideoToolbox says `isSupported` — an iPhone 14 Pro on iOS 27 is not assumed.
    var engineAvailable: Bool {
        switch self {
        case .rife425: return true
        case .rifeLite: return false
        case .apple: return AppleFrameRate.isRuntimeSupported
        }
    }
}

enum DedupMode: String, Codable, CaseIterable, Identifiable {
    case off
    case fast
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Вимк."
        case .fast: return "Швидко"
        case .accurate: return "Точно"
        }
    }
}

enum ProcessStyle: String, Codable, CaseIterable, Identifiable {
    case together
    case stepwise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .together: return "Усе разом"
        case .stepwise: return "Покроково"
        }
    }
}

enum FragmentAudio: String, Codable, CaseIterable, Identifiable {
    case mute
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mute: return "Вимкнено"
        case .stretch: return "Розтягнути"
        }
    }
}

enum CodecChoice: String, Codable, CaseIterable, Identifiable {
    case hevc
    case h264
    case prores

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .prores: return "ProRes"
        }
    }
}

enum ContainerChoice: String, Codable, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }
}

enum MaxFPSChoice: String, Codable, CaseIterable, Identifiable {
    case none
    case p60
    case p120
    case p240

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Без"
        case .p60: return "60"
        case .p120: return "120"
        case .p240: return "240"
        }
    }

    var fps: Double? {
        switch self {
        case .none: return nil
        case .p60: return 60
        case .p120: return 120
        case .p240: return 240
        }
    }
}

enum MaxResolution: String, Codable, CaseIterable, Identifiable {
    case original
    case uhd4k
    case p1080
    case p720

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Ориг."
        case .uhd4k: return "4K"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    /// Long edge, short edge. Nil keeps the source size.
    var limit: (Int, Int)? {
        switch self {
        case .original: return nil
        case .uhd4k: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        }
    }
}

struct InterpolationSettings: Equatable, Codable {
    var model: ModelChoice = .rife425
    var useTargetFPS: Bool = false
    var multiplier: Int = 4
    var targetFPS: Double = 60
    var skipSceneChanges: Bool = true
    var sceneSensitivity: Double = 0.40
    var dedup: DedupMode = .off
    var dedupThresholdPercent: Double = 1.0
    var loop: Bool = false
    var uhd: Bool = false
    var preferFP32: Bool = false
    var style: ProcessStyle = .together

    var multiplierChoices: [Int] { [2, 4, 8, 16] }

    func resolvedModel() -> ModelChoice {
        model.engineAvailable ? model : .rife425
    }
}

struct SlowMoSettings: Equatable, Codable {
    var wholeClip: Bool = true
    /// Fraction of the active window, 0...1.
    var fragmentStart: Double = 0.30
    var fragmentEnd: Double = 0.75
    var factor: Int = 4
    var fragmentAudio: FragmentAudio = .mute

    var factorChoices: [Int] { [2, 4, 8] }

    func fragmentSeconds(duration: Double) -> ClosedRange<Double> {
        let a = min(max(0, fragmentStart), 0.95) * duration
        let b = min(max(a + 0.05, fragmentEnd * duration), duration)
        return a...b
    }

    func speedLabel(for factor: Int) -> String {
        switch factor {
        case 2: return "0.5x"
        case 4: return "0.25x"
        case 8: return "0.125x"
        default: return String(format: "%.3gx", 1.0 / Double(factor))
        }
    }
}

struct ExportSettings: Equatable, Codable {
    var codec: CodecChoice = .hevc
    var quality: Double = 75
    var container: ContainerChoice = .mov
    var maxFPS: MaxFPSChoice = .none
    /// 1080p is the default because the target phone is an iPhone 14 Pro:
    /// A16, 6 GB. A 4K RIFE activation does not fit that budget. The 4K
    /// choice still scales into the 1088×1920 package.
    var maxResolution: MaxResolution = .p1080
    var keepAudio: Bool = true
    var keepMetadata: Bool = true
    var minimumDuration: Double? = nil
    var filenamePattern: String = "{name}_{fps}fps"

    var resolvedContainer: ContainerChoice {
        codec == .prores ? .mov : container
    }

    static let minimumDurationPresets: [Double?] = [nil, 3, 5, 10, 15, 30]
}

struct VideoInfo: Equatable, Codable {
    var filename: String
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    var frameCount: Int
    var fileSize: Int64
    var hasAudio: Bool
    var codecLabel: String
    var creationDate: Date? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
}

struct SourceWindow: Equatable, Codable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }

    static func full(_ info: VideoInfo, limit: Double = 30) -> SourceWindow {
        SourceWindow(start: 0, end: min(info.duration, limit))
    }
}

enum JobStatus: Equatable {
    case draft
    case queued
    case running
    case done
    case failed(String)
    case cancelled
}

struct JobResult: Equatable {
    var url: URL
    var filename: String
    var frameCount: Int
    var fps: Double
    var duration: Double
    var fileSize: Int64
    var elapsed: Double
    var width: Int
    var height: Int
}

struct ClipJob: Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceURL: URL
    var info: VideoInfo
    var window: SourceWindow
    var mode: WorkMode
    var slow: SlowMoSettings
    var interpolation: InterpolationSettings
    var export: ExportSettings
    var status: JobStatus = .draft
    var result: JobResult? = nil
    var thumbnailJPEG: Data? = nil
    var note: String? = nil
    var isFixture: Bool = false

    var activeDuration: Double { window.duration }

    var activeFrameCount: Int {
        max(1, Int((activeDuration * info.fps).rounded()))
    }
}

struct RecentItem: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var subtitle: String
    var durationLabel: String
    var thumbnailJPEG: Data? = nil
    var createdAt: Date
}

struct PipelineProgress: Equatable {
    enum Phase: Equatable {
        case analysis
        case paused
        case interpolation
        case encoding
        case finished
    }

    var phase: Phase = .analysis
    var fraction: Double = 0
    var frameIndex: Int = 0
    var frameCount: Int = 0
    var sourceFrames: Int = 0
    var sceneCuts: Int = 0
    var duplicates: Int = 0
    var framesPerSecond: Double = 0
    var eta: Double? = nil
    var timestep: Float? = nil
    var queueIndex: Int = 1
    var queueCount: Int = 1
    var detail: String = ""
}

