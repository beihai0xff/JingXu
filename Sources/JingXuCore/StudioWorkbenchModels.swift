import CoreGraphics
import Foundation

public enum AppAppearanceMode: String, CaseIterable, Codable, Sendable {
    case darkroom
    case systemWithDarkroomStage

    public static let defaultValue: AppAppearanceMode = .darkroom
    public static let storageKey = "AppAppearanceMode"

    public var title: String {
        switch self {
        case .darkroom:
            "专业暗房深色"
        case .systemWithDarkroomStage:
            "图库跟随系统（看片与调色强制暗房）"
        }
    }

    public func forcesDarkStage(for stage: StudioStageMode) -> Bool {
        switch self {
        case .darkroom:
            true
        case .systemWithDarkroomStage:
            stage != .grid
        }
    }

    public static func load(from defaults: UserDefaults) -> AppAppearanceMode {
        guard let raw = defaults.string(forKey: storageKey),
              let mode = AppAppearanceMode(rawValue: raw) else {
            return defaultValue
        }
        return mode
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

public enum GridAspectMode: String, CaseIterable, Codable, Sendable {
    case aspectFit
    case squareFill

    public static let defaultValue: GridAspectMode = .aspectFit
    public static let storageKey = "BrowseGridAspectMode"

    public var title: String {
        switch self {
        case .aspectFit:
            "原比例框"
        case .squareFill:
            "正方形铺满"
        }
    }

    public var symbolName: String {
        switch self {
        case .aspectFit:
            "rectangle.center.inset.filled"
        case .squareFill:
            "square.grid.2x2.fill"
        }
    }

    public var gridSpacing: CGFloat {
        switch self {
        case .aspectFit:
            10
        case .squareFill:
            6
        }
    }

    public static func load(from defaults: UserDefaults) -> GridAspectMode {
        guard let raw = defaults.string(forKey: storageKey),
              let mode = GridAspectMode(rawValue: raw) else {
            return defaultValue
        }
        return mode
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

public enum StudioStageMode: String, CaseIterable, Codable, Sendable {
    case grid
    case loupe
    case compare
    case develop

    public var title: String {
        switch self {
        case .grid: "网格"
        case .loupe: "单图"
        case .compare: "对比"
        case .develop: "调色"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .grid: "G"
        case .loupe: "␣"
        case .compare: "C"
        case .develop: "D"
        }
    }

    public var symbolName: String {
        switch self {
        case .grid: "square.grid.3x3"
        case .loupe: "photo"
        case .compare: "rectangle.split.2x1"
        case .develop: "slider.horizontal.3"
        }
    }

    public static func resolve(hasPreview: Bool, isComparing: Bool, isEditing: Bool) -> StudioStageMode {
        guard hasPreview else { return .grid }
        if isEditing { return .develop }
        if isComparing { return .compare }
        return .loupe
    }
}

public struct StudioSidebarMemory: Sendable, Equatable {
    public private(set) var userPreferredVisible: Bool
    public private(set) var isSidebarVisible: Bool

    public init(userPreferredVisible: Bool = true) {
        self.userPreferredVisible = userPreferredVisible
        self.isSidebarVisible = userPreferredVisible
    }

    public mutating func transition(from oldStage: StudioStageMode, to newStage: StudioStageMode) {
        guard oldStage != newStage else { return }
        if oldStage != .develop && newStage == .develop {
            isSidebarVisible = false
        } else if oldStage == .develop && newStage != .develop {
            isSidebarVisible = userPreferredVisible
        }
    }

    public mutating func setManualVisibility(_ visible: Bool, in stage: StudioStageMode) {
        isSidebarVisible = visible
        if stage != .develop {
            userPreferredVisible = visible
        }
    }
}

public struct DarkroomSliderGeometry: Sendable, Equatable {
    public let parameter: ColorParameter
    public let range: ClosedRange<Double>
    public let clampedValue: Double
    public let thumbFraction: Double
    public let zeroFraction: Double?
    public let fillStart: Double
    public let fillWidth: Double

    public init(parameter: ColorParameter, value: Double, isRAW: Bool) {
        self.parameter = parameter
        let range = parameter.range(isRAW: isRAW)
        self.range = range
        let span = max(0.000001, range.upperBound - range.lowerBound)
        let safeValue = value.isFinite ? value : 0
        let clamped = min(range.upperBound, max(range.lowerBound, safeValue))
        self.clampedValue = clamped
        let thumb = (clamped - range.lowerBound) / span
        self.thumbFraction = thumb

        if range.lowerBound < 0 && range.upperBound > 0 {
            let zero = (0 - range.lowerBound) / span
            self.zeroFraction = zero
            self.fillStart = min(zero, thumb)
            self.fillWidth = abs(thumb - zero)
        } else {
            self.zeroFraction = nil
            self.fillStart = 0
            self.fillWidth = thumb
        }
    }

    public func value(forFraction fraction: Double) -> Double {
        let clamped = min(1.0, max(0.0, fraction.isFinite ? fraction : 0.0))
        let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        let rounded: Double
        if parameter == .exposure {
            rounded = (raw * 100).rounded() / 100
        } else {
            rounded = raw.rounded()
        }
        return min(range.upperBound, max(range.lowerBound, rounded))
    }
}

public enum StudioKeyCommand: Sendable, Equatable {
    case openLoupe
    case returnToGrid
    case enterCompare
    case enterSimilarCompare
    case exitCompareToLoupe
    case enterDevelop
    case finishDevelopToLoupe
    case toggleInspector
    case toggleFilmstrip
    case reject(advance: Bool)
    case unreject
    case rate(stars: Int, advance: Bool)
    case clearSelection
    case cancelCrop
    case beginOriginalComparison
    case endOriginalComparison
}

public enum StudioKeyRouter {
    private static let ratingByKeyCode: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
        82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5
    ]

    public static func route(
        code: UInt16,
        text: String,
        shift: Bool = false,
        isRepeat: Bool = false,
        isKeyUp: Bool = false,
        stage: StudioStageMode,
        selectionCount: Int = 1,
        hasSimilarGroup: Bool = false,
        isComposingCrop: Bool = false,
        supportsCompare: Bool = true
    ) -> StudioKeyCommand? {
        let lower = text.lowercased()
        let isBackslash = code == 42 || lower == "\\"

        if isKeyUp {
            return (isBackslash && stage == .develop) ? .endOriginalComparison : nil
        }

        if isBackslash {
            guard stage == .develop, !isComposingCrop, !isRepeat else { return nil }
            return .beginOriginalComparison
        }

        guard !isRepeat else { return nil }

        if code == 53 {
            switch stage {
            case .grid:
                return selectionCount > 0 ? .clearSelection : nil
            case .loupe, .compare:
                return .returnToGrid
            case .develop:
                return isComposingCrop ? .cancelCrop : .finishDevelopToLoupe
            }
        }

        if code == 49 || text == " " {
            switch stage {
            case .grid:
                return selectionCount >= 1 ? .openLoupe : nil
            case .loupe, .compare:
                return .returnToGrid
            case .develop:
                return nil
            }
        }

        if code == 14 || lower == "e" {
            switch stage {
            case .grid:
                return selectionCount >= 1 ? .openLoupe : nil
            case .loupe:
                return nil
            case .compare:
                return .exitCompareToLoupe
            case .develop:
                return isComposingCrop ? nil : .finishDevelopToLoupe
            }
        }

        if code == 5 || lower == "g" {
            switch stage {
            case .grid:
                return nil
            case .loupe, .compare:
                return .returnToGrid
            case .develop:
                return isComposingCrop ? nil : .returnToGrid
            }
        }

        if code == 8 || lower == "c" {
            guard supportsCompare else { return nil }
            switch stage {
            case .grid:
                return selectionCount == 2 ? .enterCompare : nil
            case .loupe:
                if selectionCount == 2 { return .enterCompare }
                return hasSimilarGroup ? .enterSimilarCompare : nil
            case .compare:
                return .exitCompareToLoupe
            case .develop:
                return nil
            }
        }

        if code == 2 || lower == "d" {
            switch stage {
            case .grid:
                return selectionCount >= 1 ? .enterDevelop : nil
            case .loupe, .compare:
                return .enterDevelop
            case .develop:
                return isComposingCrop ? nil : .finishDevelopToLoupe
            }
        }

        if code == 34 || lower == "i" {
            return stage == .develop ? nil : .toggleInspector
        }

        if code == 3 || lower == "f" {
            return stage == .grid ? nil : .toggleFilmstrip
        }

        if code == 51 || code == 117 || code == 7 || lower == "x" {
            switch stage {
            case .grid:
                guard selectionCount >= 1 else { return nil }
                return .reject(advance: selectionCount == 1)
            case .loupe, .compare:
                return .reject(advance: true)
            case .develop:
                return nil
            }
        }

        if code == 32 || lower == "u" {
            switch stage {
            case .grid:
                return selectionCount >= 1 ? .unreject : nil
            case .loupe, .compare:
                return .unreject
            case .develop:
                return nil
            }
        }

        let stars: Int? = ratingByKeyCode[code] ?? {
            guard let parsed = Int(text), (0...5).contains(parsed) else { return nil }
            return parsed
        }()
        if let stars {
            switch stage {
            case .grid:
                guard selectionCount >= 1 else { return nil }
                return .rate(stars: stars, advance: shift && selectionCount == 1)
            case .loupe, .compare:
                return .rate(stars: stars, advance: shift)
            case .develop:
                guard !isComposingCrop, !shift else { return nil }
                return .rate(stars: stars, advance: false)
            }
        }

        return nil
    }
}
