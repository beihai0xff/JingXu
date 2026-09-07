import Foundation
import GRDB

public protocol CatalogRepository: Sendable {
    func upsertSource(_ source: SourceRoot) async throws
    func sources() async throws -> [SourceRoot]
    func source(id: String) async throws -> SourceRoot?
    @discardableResult func upsertAsset(_ asset: MediaAsset) async throws -> MediaAsset
    @discardableResult func upsertAssets(_ assets: [MediaAsset]) async throws -> [MediaAsset]
    func asset(id: String) async throws -> MediaAsset?
    func asset(sourceID: String, relativePath: String) async throws -> MediaAsset?
    func assets(sourceID: String) async throws -> [MediaAsset]
    func assets(_ query: AssetQuery) async throws -> [AssetListItem]
    func annotation(for assetID: String) async throws -> UserAnnotation
    func saveAnnotation(_ annotation: UserAnnotation) async throws
    func saveAnalysis(_ analysis: AnalysisResult) async throws
    func analysis(for assetID: String) async throws -> AnalysisResult?
    func assetIDsNeedingAnalysis(sourceID: String, algorithmVersion: Int) async throws -> [String]
    func saveImportSession(_ session: ImportSession) async throws
    func saveAlbum(_ album: Album) async throws
    func albums() async throws -> [Album]
    func add(assetID: String, toAlbum albumID: String) async throws
}

public actor CatalogStore: CatalogRepository {
    public let databasePath: String
    private let dbPool: DatabasePool

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        databasePath = databaseURL.path

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(dbPool)
    }

    public static func inMemory() throws -> CatalogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JingXuTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        return try CatalogStore(databaseURL: url)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-catalog") { db in
            try db.create(table: "sourceRoots") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("bookmarkData", .blob)
                table.column("pathHint", .text).notNull()
                table.column("volumeIdentifier", .text)
                table.column("isOnline", .boolean).notNull().defaults(to: true)
                table.column("lastScanAt", .datetime)
                table.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "mediaAssets") { table in
                table.column("id", .text).primaryKey()
                table.column("sourceID", .text).notNull().indexed()
                    .references("sourceRoots", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("fileIdentifier", .text)
                table.column("fileName", .text).notNull()
                table.column("uniformType", .text)
                table.column("kind", .text).notNull().indexed()
                table.column("fileSize", .integer).notNull()
                table.column("modifiedAt", .datetime).notNull()
                table.column("capturedAt", .datetime).indexed()
                table.column("importedAt", .datetime).notNull().indexed()
                table.column("width", .integer)
                table.column("height", .integer)
                table.column("duration", .double)
                table.column("cameraMake", .text).indexed()
                table.column("cameraModel", .text).indexed()
                table.column("lens", .text).indexed()
                table.column("orientation", .integer)
                table.column("latitude", .double)
                table.column("longitude", .double)
                table.column("rawPairKey", .text).indexed()
                table.column("sha256", .text).indexed()
                table.column("metadataError", .text)
                table.uniqueKey(["sourceID", "relativePath"])
            }

            try db.create(table: "annotations") { table in
                table.column("assetID", .text).primaryKey()
                    .references("mediaAssets", onDelete: .cascade)
                table.column("rating", .integer).notNull().defaults(to: 0).indexed()
                table.column("flag", .text).notNull().defaults(to: AssetFlag.none.rawValue).indexed()
                table.column("keywordsJSON", .text).notNull().defaults(to: "[]")
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "analysisResults") { table in
                table.column("assetID", .text).primaryKey()
                    .references("mediaAssets", onDelete: .cascade)
                table.column("algorithmVersion", .integer).notNull()
                table.column("sharpnessScore", .double).notNull()
                table.column("shadowClipping", .double).notNull()
                table.column("highlightClipping", .double).notNull()
                table.column("featurePrint", .blob)
                table.column("issuesJSON", .text).notNull().defaults(to: "[]")
                table.column("suggestionState", .text).notNull().indexed()
                table.column("similarGroupID", .text).indexed()
                table.column("analyzedAt", .datetime).notNull()
            }

            try db.create(table: "albums") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "albumAssets") { table in
                table.column("albumID", .text).notNull().references("albums", onDelete: .cascade)
                table.column("assetID", .text).notNull().references("mediaAssets", onDelete: .cascade)
                table.column("addedAt", .datetime).notNull()
                table.primaryKey(["albumID", "assetID"])
            }

            try db.create(table: "importSessions") { table in
                table.column("id", .text).primaryKey()
                table.column("sourcePath", .text).notNull()
                table.column("destinationPath", .text).notNull()
                table.column("batchName", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("totalFiles", .integer).notNull()
                table.column("completedFiles", .integer).notNull()
                table.column("skippedFiles", .integer).notNull()
                table.column("failedFiles", .integer).notNull()
                table.column("errorMessage", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "backgroundJobs") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull().indexed()
                table.column("payloadJSON", .text).notNull()
                table.column("state", .text).notNull().indexed()
                table.column("progress", .double).notNull()
                table.column("errorMessage", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        return migrator
    }

    public func upsertSource(_ source: SourceRoot) throws {
        try dbPool.write { db in try source.save(db) }
    }

    public func sources() throws -> [SourceRoot] {
        try dbPool.read { db in
            try SourceRoot.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    public func source(id: String) throws -> SourceRoot? {
        try dbPool.read { db in try SourceRoot.fetchOne(db, key: id) }
    }

    @discardableResult
    public func upsertAsset(_ asset: MediaAsset) throws -> MediaAsset {
        try upsertAssets([asset])[0]
    }

    @discardableResult
    public func upsertAssets(_ assets: [MediaAsset]) throws -> [MediaAsset] {
        guard !assets.isEmpty else { return [] }
        return try dbPool.write { db in
            var stored: [MediaAsset] = []
            stored.reserveCapacity(assets.count)
            for asset in assets {
                var record = asset
                if let existing = try MediaAsset
                    .filter(Column("sourceID") == asset.sourceID && Column("relativePath") == asset.relativePath)
                    .fetchOne(db) {
                    record.id = existing.id
                    record.importedAt = existing.importedAt
                }
                try record.save(db)
                if try UserAnnotation.fetchOne(db, key: record.id) == nil {
                    try UserAnnotation(assetID: record.id).insert(db)
                }
                stored.append(record)
            }
            return stored
        }
    }

    public func asset(id: String) throws -> MediaAsset? {
        try dbPool.read { db in try MediaAsset.fetchOne(db, key: id) }
    }

    public func asset(sourceID: String, relativePath: String) throws -> MediaAsset? {
        try dbPool.read { db in
            try MediaAsset
                .filter(Column("sourceID") == sourceID && Column("relativePath") == relativePath)
                .fetchOne(db)
        }
    }

    public func assets(sourceID: String) throws -> [MediaAsset] {
        try dbPool.read { db in try MediaAsset.filter(Column("sourceID") == sourceID).fetchAll(db) }
    }

    public func assets(_ query: AssetQuery) throws -> [AssetListItem] {
        var joins = "LEFT JOIN annotations an ON an.assetID = a.id LEFT JOIN analysisResults ar ON ar.assetID = a.id"
        var conditions: [String] = []
        var arguments: StatementArguments = []

        if let albumID = query.albumID {
            joins += " JOIN albumAssets aa ON aa.assetID = a.id"
            conditions.append("aa.albumID = ?")
            arguments += [albumID]
        }
        if let sourceID = query.sourceID {
            conditions.append("a.sourceID = ?")
            arguments += [sourceID]
        }

        switch query.collection {
        case .all:
            break
        case .recent:
            conditions.append("a.importedAt >= datetime('now', '-30 days')")
        case .photos:
            conditions.append("a.kind = 'photo'")
        case .videos:
            conditions.append("a.kind = 'video'")
        case .raw:
            let extensions = MediaSupport.rawExtensions.sorted()
            conditions.append("(" + extensions.map { _ in "lower(a.fileName) LIKE ?" }.joined(separator: " OR ") + ")")
            for ext in extensions { arguments += ["%.\(ext)"] }
        case .review:
            conditions.append("ar.suggestionState = 'pending' AND ar.issuesJSON <> '[]'")
        case .rejected:
            conditions.append("an.flag = 'rejected'")
        }

        if !query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pattern = "%\(query.searchText)%"
            conditions.append("(a.fileName LIKE ? OR a.cameraModel LIKE ? OR a.lens LIKE ? OR an.keywordsJSON LIKE ?)")
            arguments += [pattern, pattern, pattern, pattern]
        }
        if query.minimumRating > 0 {
            conditions.append("COALESCE(an.rating, 0) >= ?")
            arguments += [query.minimumRating]
        }
        if let flag = query.flag {
            conditions.append("COALESCE(an.flag, 'none') = ?")
            arguments += [flag.rawValue]
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        arguments += [query.limit, query.offset]
        let sql = """
            SELECT a.id, a.sourceID, a.relativePath, a.fileName, a.kind,
                   a.capturedAt, a.importedAt, a.width, a.height,
                   a.cameraModel, a.lens, a.metadataError,
                   COALESCE(an.rating, 0) AS rating,
                   COALESCE(an.flag, 'none') AS flag,
                   COALESCE(an.keywordsJSON, '[]') AS keywordsJSON,
                   ar.issuesJSON, ar.suggestionState
            FROM mediaAssets a
            \(joins)
            \(whereClause)
            ORDER BY COALESCE(a.capturedAt, a.modifiedAt) DESC, a.fileName ASC
            LIMIT ? OFFSET ?
            """
        return try dbPool.read { db in try AssetListItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    public func annotation(for assetID: String) throws -> UserAnnotation {
        try dbPool.read { db in
            try UserAnnotation.fetchOne(db, key: assetID) ?? UserAnnotation(assetID: assetID)
        }
    }

    public func saveAnnotation(_ annotation: UserAnnotation) throws {
        var value = annotation
        value.rating = min(max(value.rating, 0), 5)
        value.updatedAt = Date()
        try dbPool.write { db in try value.save(db) }
    }

    public func saveAnalysis(_ analysis: AnalysisResult) throws {
        try dbPool.write { db in try analysis.save(db) }
    }

    public func analysis(for assetID: String) throws -> AnalysisResult? {
        try dbPool.read { db in try AnalysisResult.fetchOne(db, key: assetID) }
    }

    public func assetIDsNeedingAnalysis(sourceID: String, algorithmVersion: Int) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT a.id
                    FROM mediaAssets a
                    LEFT JOIN analysisResults ar ON ar.assetID = a.id
                    WHERE a.sourceID = ? AND a.kind = 'photo'
                      AND (ar.assetID IS NULL OR ar.algorithmVersion < ?)
                    ORDER BY COALESCE(a.capturedAt, a.modifiedAt) ASC
                    """,
                arguments: [sourceID, algorithmVersion]
            )
        }
    }

    public func saveImportSession(_ session: ImportSession) throws {
        try dbPool.write { db in try session.save(db) }
    }

    public func saveAlbum(_ album: Album) throws {
        try dbPool.write { db in try album.save(db) }
    }

    public func albums() throws -> [Album] {
        try dbPool.read { db in try Album.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    public func add(assetID: String, toAlbum albumID: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO albumAssets (albumID, assetID, addedAt) VALUES (?, ?, ?)",
                arguments: [albumID, assetID, Date()]
            )
        }
    }
}
