import Foundation
import GRDB

extension CatalogStore {
    public func colorSnapshot(assetID: String) throws -> ColorEditSnapshot {
        try dbPool.read { db in
            guard let asset = try MediaAsset.fetchOne(db, key: assetID), asset.kind == .photo,
                  let source = try SourceRoot.fetchOne(db, key: asset.sourceID) else { throw ColorEditError("照片或来源已不存在") }
            return ColorEditSnapshot(asset: asset, source: source, record: try ColorEditRecord.fetchOne(db, key: assetID))
        }
    }
    private static func checkColorSnapshot(_ snapshot: ColorEditSnapshot, db: Database) throws {
        guard try MediaAsset.fetchOne(db, key: snapshot.asset.id) == snapshot.asset,
              try SourceRoot.fetchOne(db, key: snapshot.source.id) == snapshot.source,
              try ColorEditRecord.fetchOne(db, key: snapshot.asset.id) == snapshot.record else {
            throw ColorEditError("照片或调整记录已变化，请重新打开照片或重新生成操作清单。")
        }
    }
    @discardableResult
    public func saveColorAdjustments(_ adjustments: ColorAdjustments, snapshot: ColorEditSnapshot) throws -> ColorEditSnapshot {
        try adjustments.validate(isRAW: snapshot.isRAW)
        let access = try ColorSourceAccess(snapshot)
        return try dbPool.write { db in
            try Self.checkColorSnapshot(snapshot, db: db)
            try access.revalidate()
            let record = try ColorEditRecord(assetID: snapshot.asset.id, adjustments: adjustments,
                fingerprint: access.fingerprint, revision: snapshot.revision + 1)
            try record.save(db)
            return ColorEditSnapshot(asset: snapshot.asset, source: snapshot.source, record: try ColorEditRecord.fetchOne(db, key: snapshot.asset.id))
        }
    }
    /// Explicit user action after rescan. Does not apply the stale recipe to a replacement file.
    public func discardStaleColorAdjustments(assetID: String) throws -> ColorEditSnapshot {
        let snapshot = try colorSnapshot(assetID: assetID)
        let access = try ColorSourceAccess(snapshot, checkAdjustment: false)
        return try dbPool.write { db in
            try Self.checkColorSnapshot(snapshot, db: db); try access.revalidate()
            let record = try ColorEditRecord(assetID: assetID, adjustments: ColorAdjustments(),
                fingerprint: access.fingerprint, revision: snapshot.revision + 1)
            try record.save(db)
            return ColorEditSnapshot(asset: snapshot.asset, source: snapshot.source, record: try ColorEditRecord.fetchOne(db, key: assetID))
        }
    }
    public func prepareColorBatch(assetIDs: [String], patch: ColorPatch, groups: Set<ColorGroup>) async throws -> ColorBatchPlan {
        var plan = ColorBatchPlan(groups: groups)
        for id in Array(Set(assetIDs)).sorted() {
            try Task.checkCancellation()
            do {
                let snapshot = try colorSnapshot(assetID: id)
                let adjustments = try patch.applying(to: snapshot.adjustments, groups: groups, isRAW: snapshot.isRAW)
                _ = try await ColorImageRenderer.shared.render(snapshot, adjustments: adjustments, maximumDimension: 64)
                plan.items.append(ColorBatchItem(snapshot: snapshot, adjustments: adjustments))
            } catch is CancellationError { throw CancellationError() }
            catch { plan.warnings.append("\((try? asset(id: id))?.fileName ?? id)：\(error.localizedDescription)") }
        }
        return plan
    }
    /// Returns a revision-checked inverse plan. Backup and all writes precede a single commit.
    public func applyColorBatch(_ plan: ColorBatchPlan, backupURL: URL) throws -> ColorBatchPlan {
        guard !plan.items.isEmpty, Set(plan.items.map(\.id)).count == plan.items.count else { throw ColorEditError("调色清单为空或包含重复照片") }
        try Task.checkCancellation()
        let accesses = try plan.items.map { try ColorSourceAccess($0.snapshot) }
        try backup(to: backupURL)
        return try dbPool.write { db in
            var undo = ColorBatchPlan(groups: plan.groups)
            for (item, access) in zip(plan.items, accesses) {
                try Task.checkCancellation()
                try Self.checkColorSnapshot(item.snapshot, db: db); try access.revalidate()
                try item.adjustments.validate(isRAW: item.snapshot.isRAW)
                let record = try ColorEditRecord(assetID: item.id, adjustments: item.adjustments,
                    fingerprint: access.fingerprint, revision: item.snapshot.revision + 1)
                try record.save(db)
                let saved = ColorEditSnapshot(asset: item.snapshot.asset, source: item.snapshot.source, record: try ColorEditRecord.fetchOne(db, key: item.id))
                undo.items.append(ColorBatchItem(snapshot: saved, adjustments: try item.snapshot.adjustments))
            }
            return undo
        }
    }
    public func validateColorSnapshot(_ snapshot: ColorEditSnapshot) throws {
        try dbPool.read { db in try Self.checkColorSnapshot(snapshot, db: db) }
        _ = try ColorSourceAccess(snapshot)
    }
    public func colorPresets() throws -> [ColorPreset] {
        try dbPool.read { try ColorPreset.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
    }
    public func saveColorPreset(_ preset: ColorPreset) throws {
        let value = try ColorPreset(id: preset.id, name: preset.name, patch: preset.patch)
        try dbPool.write { try value.save($0) }
    }
    public func deleteColorPreset(id: String) throws { _ = try dbPool.write { try ColorPreset.deleteOne($0, key: id) } }
}
