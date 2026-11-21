import Photos
import Vision
import UIKit

struct ScanResult { var seen: Set<String>; var candidates: [Candidate]; var stats: ScanStats }

struct Scanner {
    static let backgroundFlagged = 400     // per background run (iOS gives only a short window)
    static let backgroundOthers = 150
    static let duplicateMinAgeDays = 1.0   // duplicates must be a day old; screenshots and WhatsApp have no age limit
    static let queueThreshold = 0.5
    static let preselectThreshold = 0.75

    func run(state: AppState, allowNetwork: Bool = false,
             flaggedLimit: Int = Scanner.backgroundFlagged, otherLimit: Int = Scanner.backgroundOthers) async -> ScanResult {
        var stats = ScanStats()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return ScanResult(seen: [], candidates: [], stats: stats) }

        let learner = Learner(decisions: state.decisions)
        let protectedIDs = Self.userAlbumAssetIDs()

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: .image, options: opts)
        stats.libraryImages = all.count

        // Pass 1: cheap metadata only. Screenshots and WhatsApp photos go first, wherever they sit in the library.
        let cutoff = Date().addingTimeInterval(-Self.duplicateMinAgeDays * 86400)
        var flagged: [PHAsset] = []
        var others: [PHAsset] = []
        for i in 0..<all.count {
            if Task.isCancelled { break }
            let a = all.object(at: i)
            if state.seen.contains(a.localIdentifier) { continue }
            if a.isFavorite || protectedIDs.contains(a.localIdentifier) { stats.protectedFavOrAlbum += 1; continue }
            let shot = a.mediaSubtypes.contains(.photoScreenshot)
            let wa = !shot && Self.isWhatsApp(a)
            if shot { stats.screenshots += 1 }
            if wa { stats.whatsapp += 1 }
            if shot || wa {
                if flagged.count < flaggedLimit { flagged.append(a) }
            } else if (a.creationDate ?? .distantPast) > cutoff {
                stats.tooNew += 1
            } else if others.count < otherLimit {
                others.append(a)
            }
            if flagged.count >= flaggedLimit && others.count >= otherLimit { break }
        }

        // Pass 2: analyse, newest first so duplicates sit next to each other.
        let work = (flagged + others).sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        var seen = Set<String>()
        var out: [String: Candidate] = [:]
        var recent: [(id: String, print: VNFeaturePrintObservation, date: Date, pixels: Int)] = []

        for asset in work {
            if Task.isCancelled { break }
            stats.examined += 1
            seen.insert(asset.localIdentifier)
            let date = asset.creationDate ?? .distantPast

            guard let image = await Self.thumbnail(asset, allowNetwork: allowNetwork), let cg = image.cgImage else {
                stats.thumbFail += 1; continue
            }
            let analysis = Self.analyse(cg)
            guard let print = analysis.print else { stats.thumbFail += 1; continue }

            var reasons: [Reason] = []
            var notes: [String] = []
            var score = 0.0

            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            if isScreenshot { reasons.append(.screenshot); score = max(score, 0.80) }

            let isWhatsApp = !isScreenshot && Self.isWhatsApp(asset)
            if isWhatsApp { reasons.append(.whatsapp); score = max(score, 0.60) }

            // Near-duplicate of something taken within 10 minutes: propose the lower-quality one.
            let pixels = asset.pixelWidth * asset.pixelHeight
            if let match = recent.first(where: { r in
                abs(r.date.timeIntervalSince(date)) < 600 && Self.distance(r.print, print) < 0.15
            }) {
                if pixels <= match.pixels {
                    reasons.append(.duplicate); score = max(score, 0.70); stats.duplicates += 1
                } else if var other = out[match.id], !other.reasons.contains(.duplicate) {
                    other.reasons.append(.duplicate); other.score = max(other.score, 0.70)
                    out[match.id] = other; stats.duplicates += 1
                }
            }
            recent.append((asset.localIdentifier, print, date, pixels))
            recent = Array(recent.suffix(30))

            if reasons.isEmpty { continue }
            if reasons.count > 1 { score += 0.1 * Double(reasons.count - 1) }

            if analysis.isUtility && !isScreenshot { score -= 0.30; notes.append("looks like a document or receipt") }
            if analysis.hasFaces && !isScreenshot {
                if isWhatsApp { score -= 0.25; notes.append("has people") }
                else { stats.peopleSkipped += 1; continue }
            }

            let verdict = learner.evaluate(print)
            if verdict.protected { stats.learnedProtected += 1; continue }
            score += 0.35 * verdict.adjustment
            for r in reasons {
                let s = state.stats[r.rawValue] ?? ReasonStats()
                let rate = Double(s.deleted + 1) / Double(s.deleted + s.kept + 2)
                score += (rate - 0.5) * 0.4 / Double(reasons.count)
            }
            if verdict.adjustment > 0.3 { notes.append("similar to photos you deleted") }

            if score >= Self.queueThreshold {
                out[asset.localIdentifier] = Candidate(id: asset.localIdentifier, reasons: reasons,
                                                       notes: notes, score: min(score, 1),
                                                       print: Learner.archive(print))
            } else { stats.belowThreshold += 1 }
        }
        stats.queued = out.count
        return ScanResult(seen: seen, candidates: Array(out.values), stats: stats)
    }

    // MARK: helpers

    static func isWhatsApp(_ asset: PHAsset) -> Bool {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
        // WhatsApp saves as IMG-20261121-WA0003.jpg
        return name.range(of: #"-WA\d+"#, options: .regularExpression) != nil
    }

    /// Photos you filed into your own albums are protected. A "WhatsApp" album is ignored because the app creates it.
    static func userAlbumAssetIDs() -> Set<String> {
        var ids = Set<String>()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        albums.enumerateObjects { col, _, _ in
            if col.localizedTitle?.lowercased() == "whatsapp" { return }
            PHAsset.fetchAssets(in: col, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
        }
        return ids
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return d
    }

    static func thumbnail(_ asset: PHAsset, allowNetwork: Bool = false) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = allowNetwork   // iCloud downloads only when you tap Scan yourself
            o.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 299, height: 299),
                                                  contentMode: .aspectFit, options: o) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if resumed { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }

    static func analyse(_ cg: CGImage) -> (print: VNFeaturePrintObservation?, isUtility: Bool, hasFaces: Bool) {
        let fp = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([fp, faces, aesthetics])
        let util = (aesthetics.results?.first)?.isUtility ?? false
        return (fp.results?.first, util, !(faces.results ?? []).isEmpty)
    }
}
