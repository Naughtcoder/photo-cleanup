import Photos
import Vision
import UIKit
import ImageIO

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
        var waIDs = Set<String>()
        var flagged: [PHAsset] = []
        var others: [PHAsset] = []
        for i in 0..<all.count {
            if Task.isCancelled { break }
            let a = all.object(at: i)
            if state.seen.contains(a.localIdentifier) { continue }
            if a.isFavorite || protectedIDs.contains(a.localIdentifier) { stats.protectedFavOrAlbum += 1; continue }
            let shot = a.mediaSubtypes.contains(.photoScreenshot)
            var wa = false
            if !shot { wa = await Self.isWhatsApp(a) }
            if wa { waIDs.insert(a.localIdentifier) }
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

            let isWhatsApp = !isScreenshot && waIDs.contains(asset.localIdentifier)
            if isWhatsApp { reasons.append(.whatsapp); score = max(score, 0.75) }

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

            // New categories from Apple's on-device image classifier.
            let isSelfie = analysis.faceCount == 1 && analysis.largestFaceArea >= 0.12
            if !isScreenshot {
                if (analysis.labels["medicine"] ?? 0) >= 0.35 { reasons.append(.medicine); score = max(score, 0.70) }
                let L = analysis.labels
                let board = L["whiteboard"] ?? 0
                let paper = max(L["document"] ?? 0, L["receipt"] ?? 0, L["newspaper"] ?? 0,
                                L["printed_page"] ?? 0, L["handwriting"] ?? 0)
                if board >= 0.40 { reasons.append(.document); score = max(score, 0.78) }         // whiteboards start ticked
                else if paper >= 0.30 { reasons.append(.document); score = max(score, 0.62) }    // other documents need a tap
                // A phone photo of a computer screen (calibrated on real examples: laptop 0.36-0.72, screenshot 0.2-0.6).
                let screen = max(L["laptop"] ?? 0, L["computer"] ?? 0, L["computer_monitor"] ?? 0, L["television"] ?? 0, L["screenshot"] ?? 0)
                if screen >= 0.30 && !analysis.hasFaces { reasons.append(.screenPhoto); score = max(score, 0.78) }
                if isSelfie { reasons.append(.selfie); score = max(score, 0.80) }
            }

            // Self-learning: photos you kept, deleted, or taught.
            let verdict = learner.evaluate(print)
            if verdict.protected { if !reasons.isEmpty { stats.learnedProtected += 1 }; continue }
            if verdict.strongDelete { reasons.append(.similar); score = max(score, 0.80) }

            if reasons.isEmpty { continue }
            if reasons.count > 1 { score += 0.1 * Double(reasons.count - 1) }

            var capUnticked = false
            // Value protections: people (other than selfies) and documents sent over WhatsApp or duplicated.
            if analysis.isUtility && (isWhatsApp || reasons.contains(.duplicate)) && !isScreenshot { score -= 0.30; notes.append("looks like a document or receipt") }
            if analysis.hasFaces && !isScreenshot && !isSelfie && !verdict.strongDelete {
                if isWhatsApp { score -= 0.25; notes.append("has people") }
                else if reasons.contains(.duplicate) && reasons.count == 1 { capUnticked = true; notes.append("duplicate with people"); stats.peopleSkipped += 1 }
            }

            score += 0.35 * verdict.adjustment
            for r in reasons {
                let s = state.stats[r.rawValue] ?? ReasonStats()
                let rate = Double(s.deleted + 1) / Double(s.deleted + s.kept + 2)
                score += (rate - 0.5) * 0.4 / Double(reasons.count)
            }
            if verdict.adjustment > 0.3 { notes.append("similar to photos you deleted") }

            if capUnticked { score = min(score, 0.6) }   // people duplicates are queued but never pre-ticked
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

    /// iPhone WhatsApp saves get ordinary file names, so the name alone is not enough. A saved WhatsApp photo is
    /// small (longest side 1600 or less), has no GPS and carries no camera make or model. Android-style names
    /// (IMG-20261121-WA0003) are also accepted.
    static func isWhatsApp(_ asset: PHAsset) async -> Bool {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
        if name.range(of: #"-WA\d+"#, options: .regularExpression) != nil { return true }
        guard max(asset.pixelWidth, asset.pixelHeight) <= 1700,
              asset.location == nil,
              !asset.mediaSubtypes.contains(.photoScreenshot) else { return false }
        return !(await hasCameraInfo(asset))
    }

    /// True when the file carries a camera make or model. If it cannot be read, assume yes (the safe answer).
    static func hasCameraInfo(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
                guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                    cont.resume(returning: true); return
                }
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                cont.resume(returning: tiff?[kCGImagePropertyTIFFMake] != nil || tiff?[kCGImagePropertyTIFFModel] != nil)
            }
        }
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

    struct Analysis {
        var print: VNFeaturePrintObservation?
        var isUtility = false
        var hasFaces = false
        var faceCount = 0
        var largestFaceArea: CGFloat = 0
        var labels: [String: Float] = [:]
    }

    static func analyse(_ cg: CGImage) -> Analysis {
        let fp = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([fp, faces, aesthetics, classify])
        var a = Analysis()
        a.print = fp.results?.first
        a.isUtility = (aesthetics.results?.first)?.isUtility ?? false
        let boxes = (faces.results ?? []).map { $0.boundingBox }
        a.hasFaces = !boxes.isEmpty
        a.faceCount = boxes.count
        a.largestFaceArea = boxes.map { $0.width * $0.height }.max() ?? 0
        for o in classify.results ?? [] where o.confidence >= 0.1 { a.labels[o.identifier] = o.confidence }
        return a
    }
}
