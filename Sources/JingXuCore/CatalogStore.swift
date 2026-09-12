import Foundation
import GRDB

public enum CatalogAnnotationError: LocalizedError {
    case assetMissing
    public var errorDescription: String? { "照片已不在图库中，无法保存标注" }
}

public protocol CatalogRepository: Sendable {
    func registerSource(at url: URL) async throws -> SourceRoot
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
    @discardableResult func setRating(_ rating: Int, for assetID: String) async throws -> UserAnnotation
    @discardableResult func setFlag(_ flag: AssetFlag, for assetID: String) async throws -> UserAnnotation
    @discardableResult func setKeywords(_ keywords: [String], for assetID: String) async throws -> UserAnnotation
    func saveAnalysis(_ analysis: AnalysisResult) async throws
    func saveComputedAnalysis(_ analysis: AnalysisResult, expectedAsset: MediaAsset, fileURL: URL) async throws
    func recordAnalysisFailure(assetID: String, reason: String, fingerprint: AnalysisFingerprint) async throws
    func saveSimilarGroup(_ groupID: String, assetIDs: [String]) async throws
    func analysis(for assetID: String) async throws -> AnalysisResult?
    func assetIDsNeedingAnalysis(sourceID: String, algorithmVersion: Int) async throws -> [String]
    func saveAlbum(_ album: Album) async throws
    func albums() async throws -> [Album]
    func add(assetID: String, toAlbum albumID: String) async throws
}

public actor CatalogStore: CatalogRepository {
    public let databasePath: String
    let dbPool: DatabasePool

    public init(databaseURL: URL, lease: CatalogLease? = nil) throws {
        // The app coordinator retains its lease for the session. Direct/test stores
        // acquire one for opening/migration only, not for unrelated later readers.
        let openingLease = try lease ?? CatalogLease(databaseURL: databaseURL)
        defer { withExtendedLifetime(openingLease) {} }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        databasePath = databaseURL.path
        try CatalogUpgradeCoordinator.prepare(databaseURL)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.createCurrentSchema(dbPool)
        try CatalogUpgradeCoordinator.validate(dbPool)
        // Rebuildable indexes apply to new, current and successfully upgraded catalogs.
        try dbPool.write { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS mediaAssets_browseOrder ON mediaAssets(COALESCE(capturedAt, modifiedAt) DESC, fileName ASC, id ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS mediaAssets_sourceBrowseOrder ON mediaAssets(sourceID, COALESCE(capturedAt, modifiedAt) DESC, fileName ASC, id ASC)")
        }
        try Data().write(to: databaseURL.appendingPathExtension("initialized"), options: .atomic)
    }

    public static func inMemory() throws -> CatalogStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JingXuTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        return try CatalogStore(databaseURL: url)
    }

    static func createCurrentSchema(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            if try Int.fetchOne(db, sql: "PRAGMA user_version") == CatalogUpgradeCoordinator.schemaVersion { return }
            try db.create(table: "sourceRoots") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("bookmarkData", .blob)
                table.column("directoryIdentityJSON", .text)
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
                table.column("assessmentStatus", .text)
                table.column("diagnosticJSON", .text)
                table.column("fingerprintJSON", .text)
                table.column("analysisError", .text)
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
            try db.create(index: "mediaAssets_fileIdentifier", on: "mediaAssets", columns: ["fileIdentifier"])
            try db.create(index: "sourceRoots_directoryIdentity", on: "sourceRoots", columns: ["directoryIdentityJSON"])
            try db.create(index: "analysisResults_qualityStatus", on: "analysisResults", columns: ["algorithmVersion", "assessmentStatus", "suggestionState"])
            try db.create(table: "qualityJobItems") { table in
                table.column("jobID", .text).notNull().references("backgroundJobs", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                table.column("assetID", .text).notNull()
                table.column("state", .text).notNull().defaults(to: "queued")
                table.column("errorMessage", .text)
                table.primaryKey(["jobID", "ordinal"])
                table.uniqueKey(["jobID", "assetID"])
            }
            try db.create(index: "qualityJobItems_pending", on: "qualityJobItems", columns: ["jobID", "state", "ordinal"])
            try createColorTables(db)
            try db.execute(sql: "PRAGMA user_version = \(CatalogUpgradeCoordinator.schemaVersion)")
            try db.execute(sql: "PRAGMA application_id = \(CatalogUpgradeCoordinator.applicationID)")
        }
    }

    static func createColorTables(_ db: Database) throws {
            try db.create(table: "colorEdits") { table in
                table.column("assetID", .text).primaryKey().references("mediaAssets", onDelete: .cascade)
                table.column("adjustmentsJSON", .text).notNull()
                table.column("fingerprintJSON", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("isEdited", .boolean).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "colorPresets") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("patchJSON", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
    }

    public func upsertSource(_ source: SourceRoot) throws {
        try dbPool.write { db in try source.save(db) }
    }

    public func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try DatabaseQueue(path: url.path)
        try dbPool.backup(to: destination)
        try destination.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try destination.close()
    }

    public func removeSource(id: String, backupURL: URL) throws -> Set<String> {
        try backup(to: backupURL)
        return try dbPool.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM mediaAssets WHERE sourceID = ?", arguments: [id])
            _ = try SourceRoot.deleteOne(db, key: id)
            return Set(ids)
        }
    }

    public func deleteAlbum(id: String) throws {
        try dbPool.write { db in _ = try Album.deleteOne(db, key: id) }
    }

    public func prepareSourceMerge() throws -> SourceMergePlan {
        var groups: [[SourceRoot]] = []
        var identities: [SourceIdentity] = []
        var warnings: [String] = []
        for source in try sources().sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            guard let url = try? BookmarkStore.resolve(source).url,
                  let identity = try? SourceIdentity.resolve(url) else {
                warnings.append("\(source.pathHint)：来源离线或未授权，未参与合并")
                continue
            }
            if let index = identities.firstIndex(where: { $0.matches(identity) }) { groups[index].append(source) }
            else { identities.append(identity); groups.append([source]) }
        }
        groups = groups.filter { $0.count > 1 }
        var conflicts = 0
        for group in groups {
            var annotations: [String: UserAnnotation] = [:]
            for source in group {
                for asset in try assets(sourceID: source.id) {
                    let value = try annotation(for: asset.id)
                    if let previous = annotations[asset.relativePath], previous.rating != value.rating || previous.flag != value.flag { conflicts += 1 }
                    annotations[asset.relativePath] = value
                }
            }
        }
        return SourceMergePlan(groups: groups, conflicts: conflicts, warnings: warnings)
    }

    public func mergeSources(_ plan: SourceMergePlan, backupURL: URL) throws -> SourceMergeReport {
        try backup(to: backupURL)
        var verified: [[SourceRoot]] = []
        var report = SourceMergeReport()
        for group in plan.groups {
            guard let first = group.first,
                  let root = try? BookmarkStore.resolve(first).url,
                  let identity = try? SourceIdentity.resolve(root) else {
                report.skipped.append("来源无法访问，已跳过"); continue
            }
            let valid = try group.allSatisfy { snapshot in
                guard let current = try source(id: snapshot.id), current == snapshot,
                      let url = try? BookmarkStore.resolve(current).url,
                      let other = try? SourceIdentity.resolve(url) else { return false }
                return identity.matches(other)
            }
            if valid { verified.append(group) }
            else { report.skipped.append("\(first.pathHint)：来源已改变或离线") }
        }
        // All eligible groups commit atomically. File conflicts skip a whole group before writes.
        return try dbPool.write { db in
            for group in verified {
                let keeper = group[0]
                var byPath: [String: [MediaAsset]] = [:]
                for source in group {
                    for asset in try MediaAsset.filter(Column("sourceID") == source.id).fetchAll(db) {
                        byPath[asset.relativePath, default: []].append(asset)
                    }
                }
                let conflict = byPath.values.contains { records in
                    guard records.count > 1, let first = records.first else { return false }
                    return records.dropFirst().contains {
                        guard let left = first.fileIdentifier, let right = $0.fileIdentifier else { return true }
                        return left != right || first.fileSize != $0.fileSize || first.modifiedAt != $0.modifiedAt
                    }
                }
                if conflict { report.skipped.append("\(keeper.pathHint)：文件身份冲突或未知"); continue }
                var colorConflict = false
                for records in byPath.values {
                    let edits = try records.compactMap { try ColorEditRecord.fetchOne(db, key: $0.id) }
                    if let first = edits.first {
                        let adjustments = try first.adjustments
                        if try edits.dropFirst().contains(where: { try $0.adjustments != adjustments }) { colorConflict = true }
                    }
                }
                if colorConflict { report.skipped.append("\(keeper.pathHint)：调色记录冲突，请先统一调整后再合并"); continue }
                for records in byPath.values {
                    var target = records[0]
                    if records.count > 1 {
                        var merged = try UserAnnotation.fetchOne(db, key: target.id) ?? UserAnnotation(assetID: target.id, updatedAt: .distantPast)
                        var keywords = merged.keywords
                        if var edit = try records.compactMap({ try ColorEditRecord.fetchOne(db, key: $0.id) }).first {
                            edit.assetID = target.id
                            try edit.save(db)
                        }
                        for record in records.dropFirst() {
                            let value = try UserAnnotation.fetchOne(db, key: record.id) ?? UserAnnotation(assetID: record.id, updatedAt: .distantPast)
                            keywords += value.keywords
                            if value.updatedAt > merged.updatedAt { merged = value }
                            try db.execute(sql: "INSERT OR IGNORE INTO albumAssets(albumID, assetID, addedAt) SELECT albumID, ?, addedAt FROM albumAssets WHERE assetID = ?", arguments: [target.id, record.id])
                            _ = try MediaAsset.deleteOne(db, key: record.id)
                            report.invalidatedIDs.insert(record.id)
                        }
                        merged.assetID = target.id; merged.keywords = keywords
                        try merged.save(db)
                    }
                    target.sourceID = keeper.id
                    try target.update(db)
                    _ = try AnalysisResult.deleteOne(db, key: target.id)
                    report.invalidatedIDs.insert(target.id)
                }
                for source in group.dropFirst() { _ = try SourceRoot.deleteOne(db, key: source.id) }
                report.mergedGroups += 1
            }
            return report
        }
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
                    if !AnalysisFingerprint(asset: existing).matches(AnalysisFingerprint(asset: record)) {
                        try db.execute(sql: "UPDATE analysisResults SET assessmentStatus = 'stale', analysisError = NULL WHERE assetID = ?", arguments: [existing.id])
                    }
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

    public func validateArchive(_ files: [ArchiveFile], reversed: Bool, destination: SourceRoot? = nil) throws {
        try dbPool.read { db in
            for file in files {
                guard let expected = file.asset else { continue }
                guard let current = try MediaAsset.fetchOne(db, key: expected.id),
                      (current.sourceID == expected.sourceID && current.relativePath == file.from) ||
                        (current.sourceID == (destination?.id ?? expected.sourceID) && current.relativePath == file.to),
                      AnalysisFingerprint(asset: current).matches(file.fingerprint) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }

    public func commitArchive(_ files: [ArchiveFile], reversed: Bool, destination: SourceRoot? = nil) throws {
        try dbPool.write { db in
            if let destination, !reversed {
                if var existing = try SourceRoot.fetchOne(db, key: destination.id) {
                    guard existing.pathHint == destination.pathHint else { throw CocoaError(.fileReadNoPermission) }
                    existing.bookmarkData = destination.bookmarkData
                    try existing.update(db)
                } else { try destination.insert(db) }
            }
            for file in files {
                guard let expected = file.asset else { continue }
                guard var current = try MediaAsset.fetchOne(db, key: expected.id),
                      (current.sourceID == expected.sourceID && current.relativePath == file.from) ||
                        (current.sourceID == (destination?.id ?? expected.sourceID) && current.relativePath == file.to),
                      AnalysisFingerprint(asset: current).matches(file.fingerprint) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                current.relativePath = reversed ? file.from : file.to
                current.sourceID = reversed ? expected.sourceID : (destination?.id ?? expected.sourceID)
                current.fileName = (current.relativePath as NSString).lastPathComponent
                current.rawPairKey = expected.rawPairKey == nil ? nil :
                    (current.fileName as NSString).deletingPathExtension.lowercased()
                try current.update(db)
                // A same-volume rename preserves inode, bytes and mtime, so analysis fingerprints
                // and user review remain valid. No annotations or analysis rows are replaced.
            }
        }
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
        try queryAssets(query, rejectedOnly: false)
    }

    public func analysisCandidates(_ query: AssetQuery = AssetQuery(), legacyOnly: Bool = false) throws -> [String] {
        var unlimited = query; unlimited.limit = Int.max; unlimited.offset = 0
        let (sql, arguments) = try Self.assetQuerySQL(unlimited, rejectedOnly: false, photosOnly: true,
            legacyOnly: legacyOnly, projection: "a.id")
        return try dbPool.read { try String.fetchAll($0, sql: sql, arguments: arguments) }
    }

    public func assetListItem(id: String) throws -> AssetListItem? {
        let (sql, arguments) = try Self.assetQuerySQL(AssetQuery(limit: 1), rejectedOnly: false, assetID: id)
        return try dbPool.read { try AssetListItem.fetchOne($0, sql: sql, arguments: arguments) }
    }

    public func deletionCandidates(_ query: AssetQuery) throws -> [MediaAsset] {
        var unlimited = query
        unlimited.limit = Int.max
        unlimited.offset = 0
        let ids = try queryAssets(unlimited, rejectedOnly: true).map(\.id)
        return try dbPool.read { db in try ids.compactMap { try MediaAsset.fetchOne(db, key: $0) } }
    }

    public func prepareMissingAssetCleanup(_ query: AssetQuery) throws -> MissingAssetPlan {
        var unlimited = query
        unlimited.limit = Int.max; unlimited.offset = 0
        let (sql, arguments) = try Self.assetQuerySQL(unlimited, rejectedOnly: false, projection: "a.*")
        let candidates = try dbPool.read { try MediaAsset.fetchAll($0, sql: sql, arguments: arguments) }
        var plan = MissingAssetPlan()
        for (sourceID, files) in Dictionary(grouping: candidates, by: \.sourceID) {
            try Task.checkCancellation()
            guard let source = try source(id: sourceID) else { continue }
            do {
                let identity = try MissingAssetProbe.identity(for: source)
                plan.sources[sourceID] = source; plan.identities[sourceID] = identity
                for file in files {
                    try Task.checkCancellation()
                    do {
                        if try MissingAssetProbe.isMissing(file, source: source, expected: identity) { plan.files.append(file) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { plan.warnings.append("\(source.pathHint)/\(file.relativePath)：无法可靠确认，已保留（\(error.localizedDescription)）") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { plan.warnings.append("\(source.pathHint)：来源离线、身份变化或无法访问，保留全部索引（\(error.localizedDescription)）") }
        }
        plan.files.sort { ($0.sourceID, $0.relativePath) < ($1.sourceID, $1.relativePath) }
        return plan
    }

    public func cleanupMissingAssets(_ plan: MissingAssetPlan, backupURL: URL) throws -> MissingAssetReport {
        try Task.checkCancellation()
        try backup(to: backupURL)
        // One transaction: cancellation or database failure rolls back every record.
        return try dbPool.write { db in
            var report = MissingAssetReport()
            for file in plan.files {
                try Task.checkCancellation()
                guard !report.removedIDs.contains(file.id) else { continue }
                guard let current = try MediaAsset.fetchOne(db, key: file.id), current == file,
                      let source = try SourceRoot.fetchOne(db, key: file.sourceID), source == plan.sources[file.sourceID],
                      let identity = plan.identities[file.sourceID] else {
                    report.skipped.append("\(file.relativePath)：图库记录已改变"); continue
                }
                do {
                    guard try MissingAssetProbe.isMissing(file, source: source, expected: identity) else {
                        report.skipped.append("\(file.relativePath)：文件已存在，已保留"); continue
                    }
                } catch {
                    report.skipped.append("\(file.relativePath)：无法复核，已保留（\(error.localizedDescription)）"); continue
                }
                _ = try MediaAsset.deleteOne(db, key: file.id)
                report.removedIDs.insert(file.id)
            }
            try Task.checkCancellation()
            return report
        }
    }

    public func removeAssetRecords(_ ids: [String]) throws {
        try dbPool.write { db in
            for id in ids { _ = try MediaAsset.deleteOne(db, key: id) }
        }
    }

    public func assetsWithFileIdentifier(_ identifier: String) throws -> [MediaAsset] {
        try dbPool.read { db in
            try MediaAsset.fetchAll(db, sql: "SELECT * FROM mediaAssets WHERE fileIdentifier = ?", arguments: [identifier])
        }
    }

    private func queryAssets(_ query: AssetQuery, rejectedOnly: Bool) throws -> [AssetListItem] {
        let (sql, arguments) = try Self.assetQuerySQL(query, rejectedOnly: rejectedOnly)
        return try dbPool.read { try AssetListItem.fetchAll($0, sql: sql, arguments: arguments) }
    }

    public func matchingAssetCount(_ query: AssetQuery) throws -> Int {
        let (sql, arguments) = try Self.assetQuerySQL(query, rejectedOnly: false, projection: "COUNT(*)", paginated: false)
        return try dbPool.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
    }

    private static func assetQuerySQL(_ query: AssetQuery, rejectedOnly: Bool, photosOnly: Bool = false,
                                     legacyOnly: Bool = false, projection: String? = nil, assetID: String? = nil,
                                     paginated: Bool = true) throws -> (String, StatementArguments) {
        let hasSearch = !query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsAnnotation = projection == nil || rejectedOnly || query.collection == .rejected || hasSearch || query.minimumRating > 0 || query.flag != nil
        let needsAnalysis = projection == nil || legacyOnly || query.collection == .review
        var joins = ""
        if needsAnnotation { joins += " LEFT JOIN annotations an ON an.assetID = a.id" }
        if needsAnalysis { joins += " LEFT JOIN analysisResults ar ON ar.assetID = a.id" }
        if projection == nil { joins += " LEFT JOIN colorEdits ce ON ce.assetID = a.id" }
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if rejectedOnly { conditions.append("a.kind = 'photo' AND an.flag = 'rejected'") }
        if photosOnly { conditions.append("a.kind = 'photo'") }
        if legacyOnly { conditions.append("ar.algorithmVersion < 2") }
        if let assetID { conditions.append("a.id = ?"); arguments += [assetID] }

        if let albumID = query.albumID {
            joins += " JOIN albumAssets aa ON aa.assetID = a.id"
            conditions.append("aa.albumID = ?")
            arguments += [albumID]
        }
        if let sourceID = query.sourceID {
            conditions.append("a.sourceID = ?")
            arguments += [sourceID]
        }
        if let directory = query.relativeDirectory {
            guard query.sourceID != nil else { throw CatalogFolderError.missingSource }
            guard !directory.contains("\0"), directory.isEmpty || directory.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CatalogFolderError.invalidDirectory }
            if !directory.isEmpty {
                // '/' is immediately followed by '0' in BINARY order. This range
                // uses the existing (sourceID, relativePath) index, not LIKE's
                // case folding or wildcard semantics, and includes a slash boundary.
                conditions.append("a.relativePath COLLATE BINARY >= ? AND a.relativePath COLLATE BINARY < ?")
                arguments += [directory + "/", directory + "0"]
            }
            if !query.includeSubdirectories {
                conditions.append("instr(substr(a.relativePath, ?), '/') = 0")
                arguments += [directory.isEmpty ? 1 : directory.unicodeScalars.count + 2]
            }
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
            conditions.append("ar.algorithmVersion = 2 AND ar.assessmentStatus = 'suspectedBlur' AND ar.suggestionState = 'pending' AND EXISTS (SELECT 1 FROM json_each(ar.issuesJSON) WHERE value = 'blurry')")
        case .rejected:
            conditions.append("an.flag = 'rejected'")
        }

        if hasSearch {
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
        if paginated { arguments += [query.limit, query.offset] }
        let columns = projection ?? """
                   a.id, a.sourceID, a.relativePath, a.fileName, a.kind,
                   a.capturedAt, a.importedAt, a.width, a.height,
                   a.cameraModel, a.lens, a.metadataError,
                   COALESCE(an.rating, 0) AS rating,
                   COALESCE(an.flag, 'none') AS flag,
                   COALESCE(an.keywordsJSON, '[]') AS keywordsJSON,
                   ar.issuesJSON, ar.suggestionState, ar.algorithmVersion, ar.assessmentStatus,
                   ar.diagnosticJSON, ar.analysisError, ar.similarGroupID,
                   COALESCE(ce.revision, 0) AS colorRevision, COALESCE(ce.isEdited, 0) AS isColorEdited,
                   COALESCE(a.fileIdentifier, '') || '|' || a.fileSize || '|' || a.modifiedAt AS fileVersion
            """
        let sql = """
            SELECT \(columns)
            FROM mediaAssets a
            \(joins)
            \(whereClause)
            \(paginated ? "ORDER BY COALESCE(a.capturedAt, a.modifiedAt) DESC, a.fileName ASC, a.id ASC LIMIT ? OFFSET ?" : "")
            """
        return (sql, arguments)
    }

    public func annotation(for assetID: String) throws -> UserAnnotation {
        try dbPool.read { db in
            try UserAnnotation.fetchOne(db, key: assetID) ?? UserAnnotation(assetID: assetID)
        }
    }

    @discardableResult public func setRating(_ rating: Int, for assetID: String) throws -> UserAnnotation {
        try updateAnnotation(for: assetID) { $0.rating = min(max(rating, 0), 5) }
    }

    @discardableResult public func setFlag(_ flag: AssetFlag, for assetID: String) throws -> UserAnnotation {
        try updateAnnotation(for: assetID) { $0.flag = flag }
    }

    @discardableResult public func setKeywords(_ keywords: [String], for assetID: String) throws -> UserAnnotation {
        try updateAnnotation(for: assetID) { $0.keywords = keywords }
    }

    private func updateAnnotation(for assetID: String, change: (inout UserAnnotation) -> Void) throws -> UserAnnotation {
        try dbPool.write { db in
            guard try MediaAsset.fetchOne(db, key: assetID) != nil else { throw CatalogAnnotationError.assetMissing }
            var value = try UserAnnotation.fetchOne(db, key: assetID) ?? UserAnnotation(assetID: assetID)
            change(&value)
            value.updatedAt = Date()
            try value.save(db)
            return value
        }
    }

    public func saveAnalysis(_ analysis: AnalysisResult) throws {
        try dbPool.write { db in try analysis.save(db) }
    }

    /// Computation never writes annotations and preserves the latest review, not the worker's stale copy.
    public func saveComputedAnalysis(_ analysis: AnalysisResult, expectedAsset: MediaAsset, fileURL: URL) throws {
        try dbPool.write { db in
            guard let current = try MediaAsset.fetchOne(db, key: analysis.assetID),
                  current.sourceID == expectedAsset.sourceID, current.relativePath == expectedAsset.relativePath,
                  AnalysisFingerprint(asset: current).matches(AnalysisFingerprint(asset: expectedAsset)),
                  let fingerprint = analysis.fingerprint,
                  fingerprint.matches(AnalysisFingerprint(asset: current)),
                  fingerprint.matches(try AnalysisFingerprint(url: fileURL)) else { throw QualityAnalysisError.changedFile }
            var value = analysis
            if let existing = try AnalysisResult.fetchOne(db, key: analysis.assetID) {
                value.suggestionState = existing.suggestionState
                value.similarGroupID = existing.similarGroupID
                // A failed Vision request must not reuse a print produced for different bytes.
                if value.featurePrint == nil, let previous = existing.fingerprint, let current = value.fingerprint,
                   previous.matches(current) { value.featurePrint = existing.featurePrint }
            }
            try value.save(db)
        }
    }

    public func recordAnalysisFailure(assetID: String, reason: String, fingerprint: AnalysisFingerprint) throws {
        try dbPool.write { db in
            guard let asset = try MediaAsset.fetchOne(db, key: assetID), fingerprint.matches(AnalysisFingerprint(asset: asset)) else { return }
            var value = try AnalysisResult.fetchOne(db, key: assetID) ?? AnalysisResult(assetID: assetID,
                algorithmVersion: 2, sharpnessScore: 0, shadowClipping: 0, highlightClipping: 0)
            // Existing metrics/review remain available, but a failed attempt never appears normal.
            value.assessmentStatus = .failed; value.analysisError = reason
            if value.fingerprint == nil { value.fingerprint = fingerprint }
            try value.save(db)
        }
    }

    @discardableResult public func saveQualityReview(assetID: String, state: SuggestionState) throws -> Bool {
        try dbPool.write { db in
            guard var result = try AnalysisResult.fetchOne(db, key: assetID), result.hasPendingQualityWarning,
                  state != .pending else { return false }
            result.suggestionState = state
            try result.update(db, columns: ["suggestionState"])
            if state == .accepted {
                var annotation = try UserAnnotation.fetchOne(db, key: assetID) ?? UserAnnotation(assetID: assetID)
                annotation.flag = .rejected; annotation.updatedAt = Date()
                try annotation.save(db)
            }
            return true
        }
    }

    public func saveSimilarGroup(_ groupID: String, assetIDs: [String]) throws {
        try dbPool.write { db in
            for id in assetIDs {
                try db.execute(sql: "UPDATE analysisResults SET similarGroupID = ? WHERE assetID = ?", arguments: [groupID, id])
            }
        }
    }

    public func analysis(for assetID: String) throws -> AnalysisResult? {
        try dbPool.read { db in try AnalysisResult.fetchOne(db, key: assetID) }
    }

    public func createQualityJob(_ plan: QualityReanalysisPlan, backupURL: URL) throws -> String {
        guard try qualityJobs().allSatisfy({ [.completed, .cancelled].contains($0.job.state) }) else {
            throw CatalogUpgradeError.blocked("请先继续或取消已有重算任务")
        }
        try backup(to: backupURL)
        var configuration = Configuration(); configuration.readonly = true
        let check = try DatabaseQueue(path: backupURL.path, configuration: configuration)
        try CatalogUpgradeCoordinator.validate(check)
        try check.close()
        let payload = QualityJobPayload(title: plan.title, backupPath: backupURL.path, backupSHA256: try FileHasher.sha256(of: backupURL), total: plan.assetIDs.count)
        let job = BackgroundJob(kind: "quality-v2", payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self))
        try dbPool.write { db in
            try job.insert(db)
            for (index, id) in plan.assetIDs.enumerated() {
                try db.execute(sql: "INSERT INTO qualityJobItems(jobID, ordinal, assetID) VALUES (?, ?, ?)", arguments: [job.id, index, id])
            }
        }
        return job.id
    }

    public func qualityJobs() throws -> [QualityJobSnapshot] {
        try dbPool.read { db in
            try BackgroundJob.filter(Column("kind") == "quality-v2").order(Column("createdAt").desc).fetchAll(db).map { job in
                let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM qualityJobItems WHERE jobID = ?", arguments: [job.id]) ?? 0
                let completed = try Int.fetchOne(db, sql: "SELECT count(*) FROM qualityJobItems WHERE jobID = ? AND state <> 'queued'", arguments: [job.id]) ?? 0
                let failed = try Int.fetchOne(db, sql: "SELECT count(*) FROM qualityJobItems WHERE jobID = ? AND state = 'failed'", arguments: [job.id]) ?? 0
                return QualityJobSnapshot(job: job, total: total, completed: completed, failed: failed)
            }
        }
    }

    public func recoverQualityJobs() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE backgroundJobs SET state = 'paused', errorMessage = '上次运行中断，可继续未完成项目' WHERE kind = 'quality-v2' AND state = 'running'")
        }
    }

    public func nextQualityJobItem(_ jobID: String) throws -> (ordinal: Int, assetID: String)? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT ordinal, assetID FROM qualityJobItems WHERE jobID = ? AND state = 'queued' ORDER BY ordinal LIMIT 1", arguments: [jobID]) else { return nil }
            return (row["ordinal"], row["assetID"])
        }
    }

    public func finishQualityJobItem(_ jobID: String, ordinal: Int, error: String?) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE qualityJobItems SET state = ?, errorMessage = ? WHERE jobID = ? AND ordinal = ? AND state = 'queued'",
                arguments: [error == nil ? "completed" : "failed", error, jobID, ordinal])
            if db.changesCount == 1 {
                try db.execute(sql: "UPDATE backgroundJobs SET progress = min(1, progress + 1.0 / max(1, json_extract(payloadJSON, '$.total'))), updatedAt = ? WHERE id = ?", arguments: [Date(), jobID])
            }
        }
    }

    public func setQualityJobState(_ id: String, state: JobState, error: String? = nil) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE backgroundJobs SET state = ?, errorMessage = ?, updatedAt = ? WHERE id = ? AND kind = 'quality-v2'", arguments: [state.rawValue, error, Date(), id])
        }
    }

    public func qualityJobAssetIDs(_ jobID: String) throws -> [String] {
        try dbPool.read { try String.fetchAll($0, sql: "SELECT assetID FROM qualityJobItems WHERE jobID = ? AND state = 'completed' ORDER BY ordinal", arguments: [jobID]) }
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
                      AND ar.assetID IS NULL
                    ORDER BY COALESCE(a.capturedAt, a.modifiedAt) ASC
                    """,
                arguments: [sourceID]
            )
        }
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
