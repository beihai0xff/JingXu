import Foundation
import GRDB

extension CatalogStore {
    public func saveImportReport(_ report: ImportReport, includePayload: Bool = true, starting: Bool = false) throws {
        let payload = includePayload ? String(decoding: try JSONEncoder().encode(report), as: UTF8.self) : nil
        let state: JobState = switch report.outcome {
        case .running: .running
        case .completed: .completed
        case .partial, .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .paused
        }
        try dbPool.write { db in
            if starting { try report.session.insert(db) } else { try report.session.save(db) }
            if let payload {
                let job = BackgroundJob(id: report.id, kind: "import", payloadJSON: payload, state: state,
                    progress: Double(report.session.completedFiles + report.session.skippedFiles + report.session.failedFiles) / Double(max(1, report.session.totalFiles)),
                    errorMessage: report.issues.last?.reason, createdAt: report.session.createdAt, updatedAt: report.session.updatedAt)
                if starting { try job.insert(db) } else { try job.save(db) }
            } else {
                try db.execute(sql: "UPDATE backgroundJobs SET progress = ?, updatedAt = ? WHERE id = ? AND kind = 'import'", arguments: [Double(report.session.completedFiles + report.session.skippedFiles + report.session.failedFiles) / Double(max(1, report.session.totalFiles)), report.session.updatedAt, report.id])
            }
        }
    }
    public func recoverImportJobs() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE importSessions SET status = 'failed', errorMessage = '上次导入中断，请重新预检后重试' WHERE id IN (SELECT id FROM backgroundJobs WHERE kind = 'import' AND state = 'running')")
            try db.execute(sql: "UPDATE backgroundJobs SET state = 'paused' WHERE kind = 'import' AND state = 'running'")
        }
    }
    public func latestImportReport() throws -> ImportReport? {
        try dbPool.read { db in
            guard let job = try BackgroundJob.filter(Column("kind") == "import").order(Column("createdAt").desc).fetchOne(db) else { return nil }
            var report = try JSONDecoder().decode(ImportReport.self, from: Data(job.payloadJSON.utf8))
            guard let session = try ImportSession.fetchOne(db, key: job.id) else { throw ColorEditError("导入记录不完整") }
            report.session = session
            if job.state == .paused { report.outcome = .interrupted }
            return report
        }
    }
}
