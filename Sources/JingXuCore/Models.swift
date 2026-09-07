import Foundation
import GRDB

public enum MediaKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case photo
    case video
}

public enum AssetFlag: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case none
    case picked
    case rejected

    public var displayName: String {
        switch self {
        case .none: "未标记"
        case .picked: "保留"
        case .rejected: "淘汰"
        }
    }
}

public enum ImportStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public enum JobState: String, Codable, Sendable, DatabaseValueConvertible {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

public enum SuggestionState: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case accepted
    case ignored
}

public enum QualityIssue: String, Codable, CaseIterable, Sendable {
    case blurry
    case clippedHighlights
    case crushedShadows
    case similarBurst

    public var displayName: String {
        switch self {
        case .blurry: "疑似模糊"
        case .clippedHighlights: "高光溢出"
        case .crushedShadows: "阴影堵塞"
        case .similarBurst: "相似连拍"
        }
    }
}

public struct SourceRoot: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "sourceRoots"

    public var id: String
    public var name: String
    public var bookmarkData: Data?
    public var directoryIdentityJSON: String? = nil
    public var pathHint: String
    public var volumeIdentifier: String?
    public var isOnline: Bool
    public var lastScanAt: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        bookmarkData: Data?,
        pathHint: String,
        volumeIdentifier: String? = nil,
        isOnline: Bool = true,
        lastScanAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.pathHint = pathHint
        self.volumeIdentifier = volumeIdentifier
        self.isOnline = isOnline
        self.lastScanAt = lastScanAt
        self.createdAt = createdAt
    }
}

public struct MediaAsset: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "mediaAssets"

    public var id: String
    public var sourceID: String
    public var relativePath: String
    public var fileIdentifier: String?
    public var fileName: String
    public var uniformType: String?
    public var kind: MediaKind
    public var fileSize: Int64
    public var modifiedAt: Date
    public var capturedAt: Date?
    public var importedAt: Date
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var orientation: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var rawPairKey: String?
    public var sha256: String?
    public var metadataError: String?

    public init(
        id: String = UUID().uuidString,
        sourceID: String,
        relativePath: String,
        fileIdentifier: String?,
        fileName: String,
        uniformType: String?,
        kind: MediaKind,
        fileSize: Int64,
        modifiedAt: Date,
        capturedAt: Date? = nil,
        importedAt: Date = Date(),
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lens: String? = nil,
        orientation: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rawPairKey: String? = nil,
        sha256: String? = nil,
        metadataError: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.fileIdentifier = fileIdentifier
        self.fileName = fileName
        self.uniformType = uniformType
        self.kind = kind
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.capturedAt = capturedAt
        self.importedAt = importedAt
        self.width = width
        self.height = height
        self.duration = duration
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.rawPairKey = rawPairKey
        self.sha256 = sha256
        self.metadataError = metadataError
    }
}

public struct UserAnnotation: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "annotations"

    public var assetID: String
    public var rating: Int
    public var flag: AssetFlag
    public var keywordsJSON: String
    public var updatedAt: Date

    public var keywords: [String] {
        get {
            guard let data = keywordsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            let normalized = Array(Set(newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .filter { !$0.isEmpty }
                .sorted()
            let data = (try? JSONEncoder().encode(normalized)) ?? Data("[]".utf8)
            keywordsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    public init(assetID: String, rating: Int = 0, flag: AssetFlag = .none, keywords: [String] = [], updatedAt: Date = Date()) {
        self.assetID = assetID
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.keywordsJSON = "[]"
        self.updatedAt = updatedAt
        self.keywords = keywords
    }
}

public struct AnalysisResult: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "analysisResults"

    public var assetID: String
    public var algorithmVersion: Int
    public var sharpnessScore: Double
    public var shadowClipping: Double
    public var highlightClipping: Double
    public var featurePrint: Data?
    public var issuesJSON: String
    public var suggestionState: SuggestionState
    public var similarGroupID: String?
    public var analyzedAt: Date

    public var issues: [QualityIssue] {
        get {
            guard let data = issuesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([QualityIssue].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            issuesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    public init(
        assetID: String,
        algorithmVersion: Int = 1,
        sharpnessScore: Double,
        shadowClipping: Double,
        highlightClipping: Double,
        featurePrint: Data? = nil,
        issues: [QualityIssue] = [],
        suggestionState: SuggestionState = .pending,
        similarGroupID: String? = nil,
        analyzedAt: Date = Date()
    ) {
        self.assetID = assetID
        self.algorithmVersion = algorithmVersion
        self.sharpnessScore = sharpnessScore
        self.shadowClipping = shadowClipping
        self.highlightClipping = highlightClipping
        self.featurePrint = featurePrint
        self.issuesJSON = "[]"
        self.suggestionState = suggestionState
        self.similarGroupID = similarGroupID
        self.analyzedAt = analyzedAt
        self.issues = issues
    }
}

public struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "albums"

    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ImportSession: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "importSessions"

    public var id: String
    public var sourcePath: String
    public var destinationPath: String
    public var batchName: String
    public var status: ImportStatus
    public var totalFiles: Int
    public var completedFiles: Int
    public var skippedFiles: Int
    public var failedFiles: Int
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sourcePath: String,
        destinationPath: String,
        batchName: String,
        status: ImportStatus = .pending,
        totalFiles: Int = 0,
        completedFiles: Int = 0,
        skippedFiles: Int = 0,
        failedFiles: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.batchName = batchName
        self.status = status
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BackgroundJob: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "backgroundJobs"

    public var id: String
    public var kind: String
    public var payloadJSON: String
    public var state: JobState
    public var progress: Double
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: String,
        payloadJSON: String = "{}",
        state: JobState = .queued,
        progress: Double = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AssetListItem: Identifiable, Sendable, Equatable, FetchableRecord, Decodable {
    public var id: String
    public var sourceID: String
    public var relativePath: String
    public var fileName: String
    public var kind: MediaKind
    public var capturedAt: Date?
    public var importedAt: Date
    public var width: Int?
    public var height: Int?
    public var cameraModel: String?
    public var lens: String?
    public var metadataError: String?
    public var rating: Int
    public var flag: AssetFlag
    public var keywordsJSON: String
    public var issuesJSON: String?
    public var suggestionState: SuggestionState?

    public var keywords: [String] {
        guard let data = keywordsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public var issues: [QualityIssue] {
        guard let issuesJSON, let data = issuesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QualityIssue].self, from: data)) ?? []
    }
}

public enum SmartCollection: String, CaseIterable, Sendable, Identifiable, Hashable {
    case all
    case recent
    case photos
    case videos
    case raw
    case review
    case rejected

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "所有媒体"
        case .recent: "最近导入"
        case .photos: "照片"
        case .videos: "视频"
        case .raw: "RAW"
        case .review: "待审核建议"
        case .rejected: "已标记淘汰"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .recent: "clock"
        case .photos: "photo"
        case .videos: "video"
        case .raw: "camera.aperture"
        case .review: "sparkles.rectangle.stack"
        case .rejected: "xmark.circle"
        }
    }
}

public struct AssetQuery: Sendable, Equatable {
    public var collection: SmartCollection
    public var sourceID: String?
    public var albumID: String?
    public var searchText: String
    public var minimumRating: Int
    public var flag: AssetFlag?
    public var limit: Int
    public var offset: Int

    public init(
        collection: SmartCollection = .all,
        sourceID: String? = nil,
        albumID: String? = nil,
        searchText: String = "",
        minimumRating: Int = 0,
        flag: AssetFlag? = nil,
        limit: Int = 500,
        offset: Int = 0
    ) {
        self.collection = collection
        self.sourceID = sourceID
        self.albumID = albumID
        self.searchText = searchText
        self.minimumRating = min(max(minimumRating, 0), 5)
        self.flag = flag
        self.limit = max(1, limit)
        self.offset = max(0, offset)
    }
}
