import Vision

/// On-device k-nearest-neighbour learner over Vision feature prints.
/// Every Keep/Delete decision you make becomes a labelled example; new photos are
/// compared against them. No network, no cost, and it improves with each review.
struct Learner {
    // Feature-print distance: lower = more similar. Tunable.
    static let voteRadius: Float = 0.6
    static let strongKeepRadius: Float = 0.45
    static let keepRadius: Float = 0.30
    static let deleteRadius: Float = 0.35

    private let examples: [(print: VNFeaturePrintObservation, keep: Bool, strong: Bool)]

    init(decisions: [Decision]) {
        examples = decisions.suffix(3000).compactMap { d in
            guard let p = Learner.unarchive(d.print) else { return nil }
            return (p, d.keep, d.strong)
        }
    }

    static func archive(_ o: VNFeaturePrintObservation) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: o, requiringSecureCoding: true)) ?? Data()
    }
    static func unarchive(_ d: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d)
    }

    /// `adjustment` in -1...1 (negative = you kept similar photos, positive = you deleted them).
    /// `protected` is true when a very similar photo was kept, or one you marked "never delete like this".
    func evaluate(_ p: VNFeaturePrintObservation) -> (adjustment: Double, protected: Bool, strongDelete: Bool) {
        var del = 0.0, keep = 0.0
        var isProtected = false
        var strongDelete = false
        for e in examples {
            var d: Float = 0
            guard (try? p.computeDistance(&d, to: e.print)) != nil, d < Learner.voteRadius else { continue }
            if !e.keep && e.strong && d < Learner.deleteRadius { strongDelete = true }
            let w = Double(1 - d / Learner.voteRadius)
            if e.keep {
                keep += w
                if d < Learner.keepRadius || (e.strong && d < Learner.strongKeepRadius) { isProtected = true }
            } else { del += w }
        }
        let total = del + keep
        return (total > 0 ? (del - keep) / total : 0, isProtected, strongDelete)
    }
}
