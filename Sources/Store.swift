import Foundation
import Photos
import UIKit

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var state = AppState()
    @Published var scanning = false

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(AppState.self, from: data) { state = s }
        // New detection categories need a fresh look at photos that were scanned under older rules.
        if state.scanVersion < 4 { state.seen = []; state.scanVersion = 4; save() }
    }

    func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    @Published var progress = 0

    /// Background runs do one short batch. A manual scan (`full: true`) keeps going, batch after batch,
    /// until every photo has been looked at, saving as it goes so nothing is lost if you leave the app.
    func scan(allowNetwork: Bool = false, full: Bool = false) async -> Int {
        guard !scanning else { return 0 }
        scanning = true; progress = 0
        if full { UIApplication.shared.isIdleTimerDisabled = true }
        defer { scanning = false; UIApplication.shared.isIdleTimerDisabled = false }
        var total = ScanStats()
        var added = 0
        repeat {
            let result = full
                ? await Scanner().run(state: state, allowNetwork: allowNetwork, flaggedLimit: 300, otherLimit: 300)
                : await Scanner().run(state: state, allowNetwork: allowNetwork)
            state.seen.formUnion(result.seen)
            let existing = Set(state.queue.map(\.id))
            let fresh = result.candidates.filter { !existing.contains($0.id) }
            state.queue.append(contentsOf: fresh)
            state.queue.sort { $0.score > $1.score }
            added += fresh.count
            total.add(result.stats)
            state.lastStats = total
            state.lastScan = Date()
            progress = total.examined
            save()
            if result.seen.isEmpty || Task.isCancelled { break }
        } while full
        return added
    }

    /// Teach by example from photos you pick: always delete photos like these, or always keep them.
    func teach(ids: [String], keep: Bool) async -> Int {
        var n = 0
        for id in ids {
            guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                  let img = await Scanner.thumbnail(a, allowNetwork: true), let cg = img.cgImage,
                  let p = Scanner.analyse(cg).print else { continue }
            state.decisions.append(Decision(print: Learner.archive(p), keep: keep, strong: true))
            n += 1
        }
        save()
        return n
    }

    /// `deleteIDs` are approved; every other queued item is treated as "keep" and taught to the learner.
    func resolve(deleteIDs: Set<String>, strongKeep: Set<String>) async -> Bool {
        let toDelete = state.queue.filter { deleteIDs.contains($0.id) }
        if !toDelete.isEmpty {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: toDelete.map(\.id), options: nil)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
            } catch { return false }   // user cancelled the system prompt: change nothing
        }
        for c in state.queue {
            let deleted = deleteIDs.contains(c.id)
            state.decisions.append(Decision(print: c.print, keep: !deleted, strong: strongKeep.contains(c.id)))
            for r in c.reasons {
                var s = state.stats[r.rawValue] ?? ReasonStats()
                if deleted { s.deleted += 1 } else { s.kept += 1 }
                state.stats[r.rawValue] = s
            }
        }
        if !toDelete.isEmpty { state.log.insert(LogEntry(date: Date(), deleted: toDelete.count), at: 0) }
        state.queue.removeAll()
        save()
        return true
    }
}
