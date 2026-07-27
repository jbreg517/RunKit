import Foundation
import SwiftUI
import SwiftData

/// Tracks whether the app is actually persisting anything, and makes it loud when
/// it isn't.
///
/// Ported from FuelKit, which learned this the expensive way. Two failures look
/// identical to success unless something watches for them:
///
/// 1. The container fails to open, the app falls back to an in-memory store, and
///    a whole session of data evaporates on quit while every screen looks normal.
/// 2. A bare `try?` save throws, and a save that *failed* is indistinguishable
///    from one that worked — the rows are in the context so the UI shows them, and
///    they're gone on the next launch.
///
/// So: one place that knows whether storage is real, whether the last save
/// succeeded, and what the failure actually said.
///
/// Not actor-isolated, because the save sites are plain synchronous view and
/// service code; property writes hop to the main queue so SwiftUI observation
/// stays on one thread.
@Observable
final class StoreHealth {
    static let shared = StoreHealth()

    /// True when running on throwaway storage — nothing survives a relaunch.
    private(set) var isInMemory = false
    /// Why the real store couldn't be opened, verbatim, for diagnosis.
    private(set) var openError: String?
    /// Where the store lives, for the diagnostics readout.
    var storePath: String?
    /// The most recent save failure, if any.
    private(set) var lastSaveError: String?
    private(set) var lastSaveErrorAt: Date?
    /// Saves that have failed since launch.
    private(set) var failedSaveCount = 0
    /// Set when sessions were rescued from the old shared App Group store, so the
    /// user is told rather than left wondering where their history came back from.
    private(set) var recoveryNote: String?

    var hasProblem: Bool { isInMemory || lastSaveError != nil }

    private init() {}

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func recordOpenFailure(_ error: Error, fellBackToMemory: Bool) {
        let text = String(describing: error)
        onMain {
            self.isInMemory = fellBackToMemory
            self.openError = text
        }
    }

    func recordSaveFailure(_ error: Error) {
        let text = String(describing: error)
        onMain {
            self.lastSaveError = text
            self.lastSaveErrorAt = Date()
            self.failedSaveCount += 1
        }
    }

    func recordSaveSuccess() {
        guard lastSaveError != nil else { return }
        onMain { self.lastSaveError = nil }
    }

    func recordRecovery(_ text: String) {
        onMain { self.recoveryNote = text }
    }

    func clearRecoveryNote() {
        onMain { self.recoveryNote = nil }
    }

    /// A short summary for the user, or nil when storage is healthy.
    var warningText: String? {
        if isInMemory {
            return """
                RunKit couldn’t open your saved history, so it is running on \
                temporary storage — anything you record now will be lost when you \
                close the app. Nothing on your device has been deleted.
                """
        }
        if lastSaveError != nil {
            return """
                RunKit couldn’t save your last change, so it may not survive closing \
                the app. Export a backup from Settings before recording more.
                """
        }
        return nil
    }

    /// Everything worth pasting into a bug report.
    var diagnosticReport: String {
        var lines = ["RunKit \(AppVersion.current)"]
        lines.append("storage: \(isInMemory ? "IN MEMORY (not saving)" : "on disk")")
        if let storePath { lines.append("store: \(storePath)") }
        if let openError { lines.append("open error: \(openError)") }
        lines.append("failed saves: \(failedSaveCount)")
        if let lastSaveError { lines.append("last save error: \(lastSaveError)") }
        lines.append("--- store files ---")
        lines.append(contentsOf: storeFiles.map { "\($0.name)  \($0.bytes) bytes" })
        return lines.joined(separator: "\n")
    }

    /// The files in the store's directory, with sizes.
    ///
    /// This is the question that matters when history has gone missing and there's
    /// no export: a `.store` file of any real size means the rows are still on disk
    /// and recoverable, whereas a near-empty one means SwiftData created a fresh
    /// store and the old data went with it. The `-wal` companion matters too —
    /// recent writes can be sitting there unmerged. Seeing `default.store` listed
    /// next to `RunKit.store` is what identified the shared-store bug.
    var storeFiles: [(name: String, bytes: Int)] {
        guard let storePath else { return [] }
        let directory = (storePath as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().compactMap { name in
            let full = (directory as NSString).appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? Int
            return (name, size ?? 0)
        }
    }

    var storeBytes: Int {
        storeFiles.filter { $0.name.contains(".store") }.reduce(0) { $0 + $1.bytes }
    }
}

/// Saves that report failure instead of hiding it.
enum Persist {
    /// Save, surfacing any failure through `StoreHealth`. Returns whether it
    /// worked, so callers can avoid acting as though it did.
    @discardableResult
    static func save(_ context: ModelContext, _ what: String = "") -> Bool {
        do {
            try context.save()
            StoreHealth.shared.recordSaveSuccess()
            return true
        } catch {
            // Deliberately not swallowed: a silently lost save is exactly the
            // failure that cost FuelKit a day of logging.
            StoreHealth.shared.recordSaveFailure(error)
            return false
        }
    }
}
