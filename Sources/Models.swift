import Foundation

enum Reason: String, Codable, CaseIterable {
    case screenshot, whatsapp, duplicate
    var label: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .whatsapp: return "WhatsApp"
        case .duplicate: return "Duplicate"
        }
    }
}

struct Candidate: Identifiable, Codable, Hashable {
    var id: String               // PHAsset.localIdentifier
    var reasons: [Reason]
    var notes: [String]          // e.g. "looks like a document"
    var score: Double
    var print: Data              // archived Vision feature print, used for learning
}

struct Decision: Codable {
    var print: Data
    var keep: Bool
    var strong: Bool             // "never delete anything like this"
}

struct ReasonStats: Codable {
    var deleted = 0
    var kept = 0
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var deleted: Int
}

struct ScanStats: Codable {
    var libraryImages = 0, examined = 0, screenshots = 0, whatsapp = 0
    var protectedFavOrAlbum = 0, tooNew = 0, thumbFail = 0
    mutating func add(_ o: ScanStats) {
        libraryImages = o.libraryImages
        examined += o.examined; screenshots += o.screenshots; whatsapp += o.whatsapp
        protectedFavOrAlbum = o.protectedFavOrAlbum; tooNew = o.tooNew; thumbFail += o.thumbFail
        duplicates += o.duplicates; peopleSkipped += o.peopleSkipped; learnedProtected += o.learnedProtected
        belowThreshold += o.belowThreshold; queued += o.queued
    }
    var duplicates = 0, peopleSkipped = 0, learnedProtected = 0, belowThreshold = 0, queued = 0
}

struct AppState: Codable {
    var lastStats: ScanStats?
    var seen: Set<String> = []
    var queue: [Candidate] = []
    var decisions: [Decision] = []
    var stats: [String: ReasonStats] = [:]
    var log: [LogEntry] = []
    var lastScan: Date?
}
