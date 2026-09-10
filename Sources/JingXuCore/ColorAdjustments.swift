import Foundation
import GRDB

public struct ColorEditError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ColorGroup: String, Codable, CaseIterable, Sendable {
    case tone, whiteBalance, color
    public var title: String { switch self { case .tone: "明暗"; case .whiteBalance: "白平衡"; case .color: "色彩" } }
}

public enum ColorParameter: String, Codable, CaseIterable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, saturation, vibrance
    public var title: String {
        switch self {
        case .exposure: "曝光"; case .contrast: "对比度"; case .highlights: "高光"; case .shadows: "阴影"
        case .whites: "白色"; case .blacks: "黑色"; case .temperature: "色温"; case .tint: "色调"
        case .saturation: "饱和度"; case .vibrance: "鲜艳度"
        }
    }
    public var group: ColorGroup {
        switch self { case .temperature, .tint: .whiteBalance; case .saturation, .vibrance: .color; default: .tone }
    }
    public func range(isRAW: Bool) -> ClosedRange<Double> {
        switch self {
        case .exposure: -5...5
        case .temperature: isRAW ? 2000...50000 : -100...100
        case .tint: isRAW ? -150...150 : -100...100
        default: -100...100
        }
    }
}

public enum ColorWhiteBalance: String, Codable, Sendable { case asShot, raw, relative }
public enum ColorPresetTarget: String, Codable, Sendable { case all, raw, rendered }

/// Values describe JingXu's renderer, not Adobe's proprietary rendering process.
public struct ColorAdjustments: Codable, Equatable, Sendable {
    public var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
    public var whites = 0.0, blacks = 0.0, saturation = 0.0, vibrance = 0.0
    public var whiteBalance: ColorWhiteBalance = .asShot
    public var temperature = 6500.0, tint = 0.0
    public init() {}
    public var isIdentity: Bool {
        ColorParameter.allCases.filter { $0.group != .whiteBalance }.allSatisfy { self[$0] == 0 } &&
        (whiteBalance == .asShot || (whiteBalance == .relative && temperature == 0 && tint == 0))
    }
    public subscript(_ parameter: ColorParameter) -> Double {
        get {
            switch parameter {
            case .exposure: exposure; case .contrast: contrast; case .highlights: highlights; case .shadows: shadows
            case .whites: whites; case .blacks: blacks; case .temperature: temperature; case .tint: tint
            case .saturation: saturation; case .vibrance: vibrance
            }
        }
        set {
            switch parameter {
            case .exposure: exposure = newValue; case .contrast: contrast = newValue; case .highlights: highlights = newValue
            case .shadows: shadows = newValue; case .whites: whites = newValue; case .blacks: blacks = newValue
            case .temperature: temperature = newValue; case .tint: tint = newValue
            case .saturation: saturation = newValue; case .vibrance: vibrance = newValue
            }
        }
    }
    public func validate(isRAW: Bool) throws {
        guard whiteBalance == .asShot || (isRAW ? whiteBalance == .raw : whiteBalance == .relative) else {
            throw ColorEditError("白平衡类型不适用；RAW 使用绝对色温，普通图片使用相对调整。可取消选择白平衡组。")
        }
        for p in ColorParameter.allCases where p.group != .whiteBalance || whiteBalance != .asShot {
            guard self[p].isFinite, p.range(isRAW: isRAW).contains(self[p]) else { throw ColorEditError("\(p.title)超出支持范围") }
        }
    }
}

/// Sparse patches preserve fields absent from an imported preset.
public struct ColorPatch: Codable, Equatable, Sendable {
    public var values: [ColorParameter: Double]
    public var whiteBalance: ColorWhiteBalance?
    public var target: ColorPresetTarget = .all
    public init(values: [ColorParameter: Double] = [:], whiteBalance: ColorWhiteBalance? = nil) {
        self.values = values; self.whiteBalance = whiteBalance
    }
    public init(_ adjustments: ColorAdjustments) {
        values = Dictionary(uniqueKeysWithValues: ColorParameter.allCases.map { ($0, adjustments[$0]) })
        whiteBalance = adjustments.whiteBalance
    }
    public func applying(to original: ColorAdjustments, groups: Set<ColorGroup>, isRAW: Bool) throws -> ColorAdjustments {
        guard !groups.isEmpty else { throw ColorEditError("请选择至少一组调整") }
        guard target == .all || (isRAW ? target == .raw : target == .rendered) else { throw ColorEditError("该预设限制了可应用的照片类型") }
        var result = original
        for (key, value) in values where groups.contains(key.group) { result[key] = value }
        if groups.contains(.whiteBalance), let whiteBalance { result.whiteBalance = whiteBalance }
        try result.validate(isRAW: isRAW)
        return result
    }
}

public struct ColorEditRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "colorEdits"
    public var assetID: String
    public var adjustmentsJSON: String
    public var fingerprintJSON: String
    public var revision: Int
    public var isEdited: Bool
    public var updatedAt: Date
    public var adjustments: ColorAdjustments { get throws { try JSONDecoder().decode(ColorAdjustments.self, from: Data(adjustmentsJSON.utf8)) } }
    public var fingerprint: AnalysisFingerprint { get throws { try JSONDecoder().decode(AnalysisFingerprint.self, from: Data(fingerprintJSON.utf8)) } }
    public init(assetID: String, adjustments: ColorAdjustments, fingerprint: AnalysisFingerprint, revision: Int) throws {
        self.assetID = assetID; self.revision = revision; isEdited = !adjustments.isIdentity; updatedAt = Date()
        adjustmentsJSON = String(decoding: try JSONEncoder().encode(adjustments), as: UTF8.self)
        fingerprintJSON = String(decoding: try JSONEncoder().encode(fingerprint), as: UTF8.self)
    }
}

public struct ColorPreset: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "colorPresets"
    public var id: String
    public var name: String
    public var patchJSON: String
    public var updatedAt: Date
    public var patch: ColorPatch { get throws { try JSONDecoder().decode(ColorPatch.self, from: Data(patchJSON.utf8)) } }
    public init(id: String = UUID().uuidString, name: String, patch: ColorPatch) throws {
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines); updatedAt = Date()
        guard !self.name.isEmpty, self.name.count <= 100 else { throw ColorEditError("预设名称需为 1–100 个字符") }
        patchJSON = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
    }
}

public struct ColorEditSnapshot: Sendable {
    public let asset: MediaAsset
    public let source: SourceRoot
    public let record: ColorEditRecord?
    public var isRAW: Bool { MediaSupport.isRaw(URL(fileURLWithPath: asset.fileName)) }
    public var adjustments: ColorAdjustments { get throws { try record?.adjustments ?? ColorAdjustments() } }
    public var revision: Int { record?.revision ?? 0 }
    public init(asset: MediaAsset, source: SourceRoot, record: ColorEditRecord?) { self.asset = asset; self.source = source; self.record = record }
}

public struct ColorBatchItem: Sendable, Identifiable {
    public var id: String { snapshot.asset.id }
    public let snapshot: ColorEditSnapshot
    public let adjustments: ColorAdjustments
    public init(snapshot: ColorEditSnapshot, adjustments: ColorAdjustments) { self.snapshot = snapshot; self.adjustments = adjustments }
}
public struct ColorBatchPlan: Identifiable, Sendable {
    public let id = UUID()
    public let groups: Set<ColorGroup>
    public var items: [ColorBatchItem] = []
    public var warnings: [String] = []
    public init(groups: Set<ColorGroup> = Set(ColorGroup.allCases)) { self.groups = groups }
}

/// Pure history makes one drag one undo step, and can be exercised without a UI.
public struct ColorEditHistory: Sendable {
    private var past: [ColorAdjustments] = [], future: [ColorAdjustments] = []
    public init() {}
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func push(_ value: ColorAdjustments) { past.append(value); if past.count > 100 { past.removeFirst() }; future.removeAll() }
    public mutating func undo(_ current: ColorAdjustments) -> ColorAdjustments? { guard let value = past.popLast() else { return nil }; future.append(current); return value }
    public mutating func redo(_ current: ColorAdjustments) -> ColorAdjustments? { guard let value = future.popLast() else { return nil }; past.append(current); return value }
}
