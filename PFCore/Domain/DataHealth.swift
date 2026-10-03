import Foundation

/// A compact read-only check of the ledger, prices, sync and recovery. Never changes data;
/// each finding names what to review.
public enum DataHealth {
    public enum Level: Int, Comparable, Sendable { case ok, warning, problem; public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue } }
    public enum Area: String, Sendable { case ledger, duplicates, prices, sync, recovery }

    public struct Finding: Identifiable, Equatable, Sendable {
        public var id: String { area.rawValue + "|" + text }
        public let area: Area
        public let level: Level
        public let text: String
        /// An asset to open for review, when one is responsible.
        public let asset: AssetID?
    }

    public struct Input {
        public init(doc: PortfolioDocument, quotes: [AssetID: Quote], marketDriven: [AssetID], now: Date = Date(),
                    staleAfter: TimeInterval = 15 * 60, sync: SyncState? = nil, syncError: Bool = false, latestSnapshot: Date? = nil) {
            self.doc = doc; self.quotes = quotes; self.marketDriven = marketDriven; self.now = now; self.staleAfter = staleAfter
            self.sync = sync; self.syncError = syncError; self.latestSnapshot = latestSnapshot
        }
        public var doc: PortfolioDocument
        public var quotes: [AssetID: Quote]
        public var marketDriven: [AssetID]       // held assets valued at a market price
        public var now: Date
        public var staleAfter: TimeInterval
        public var sync: SyncState?              // nil when sync is off
        public var syncError: Bool
        public var latestSnapshot: Date?
    }

    public static func check(_ i: Input) -> [Finding] {
        var out: [Finding] = []
        let sym = { (id: AssetID) in i.doc.assets.first { $0.id == id }?.symbol ?? id }

        // Ledger: the app's own validation (oversold, unknown asset/portfolio, bad numbers).
        let errs = i.doc.validationErrors()
        if errs.isEmpty { out.append(.init(area: .ledger, level: .ok, text: "ledger valid · \(i.doc.transactions.count) transactions", asset: nil)) }
        else {
            let firstBad = i.doc.transactions.first { t in errs.contains { $0.hasPrefix("tx \(t.id.uuidString.prefix(8))") } }
            out.append(.init(area: .ledger, level: .problem, text: "\(errs.count) ledger problem\(errs.count == 1 ? "" : "s") · \(errs[0])", asset: firstBad?.assetID))
        }
        let dups = ImportPlanner.likelyDuplicates(in: i.doc)
        if !dups.isEmpty {
            let n = dups.reduce(0) { $0 + $1.count - 1 }
            out.append(.init(area: .duplicates, level: .warning, text: "\(n) possible duplicate transaction\(n == 1 ? "" : "s") · \(sym(dups[0][0].assetID)) \(DateFmt.ymd(dups[0][0].timestamp))", asset: dups[0][0].assetID))
        }

        // Prices.
        let missing = i.marketDriven.filter { i.quotes[$0] == nil }
        let stale = i.marketDriven.filter { i.quotes[$0].map { i.now.timeIntervalSince($0.timestamp) > i.staleAfter } ?? false }
        if missing.isEmpty && stale.isEmpty { out.append(.init(area: .prices, level: .ok, text: "prices current", asset: nil)) }
        if !missing.isEmpty { out.append(.init(area: .prices, level: .warning, text: "no price · " + missing.map(sym).sorted().joined(separator: ", "), asset: missing.first)) }
        if !stale.isEmpty { out.append(.init(area: .prices, level: .warning, text: "\(stale.count) stale price\(stale.count == 1 ? "" : "s") · " + stale.map(sym).sorted().joined(separator: ", "), asset: stale.first)) }

        // Sync.
        if let s = i.sync {
            if !s.conflicts.isEmpty { out.append(.init(area: .sync, level: .warning, text: "\(s.conflicts.count) sync conflict\(s.conflicts.count == 1 ? "" : "s") to review", asset: nil)) }
            if !s.blocked.isEmpty { out.append(.init(area: .sync, level: .warning, text: "\(s.blocked.count) record\(s.blocked.count == 1 ? "" : "s") from a newer PF version held back · update PF", asset: nil)) }
            if i.syncError { out.append(.init(area: .sync, level: .problem, text: "sync error · changes stay queued (\(s.pendingCount))", asset: nil)) }
            else if s.conflicts.isEmpty && s.blocked.isEmpty {
                let stale = s.lastSync.map { i.now.timeIntervalSince($0) > 86400 } ?? true
                out.append(.init(area: .sync, level: stale ? .warning : .ok,
                                 text: stale ? "no successful sync in the last 24h" : "sync healthy" + (s.pendingCount > 0 ? " · \(s.pendingCount) queued" : ""), asset: nil))
            }
        }

        // Recovery.
        if let t = i.latestSnapshot {
            let old = i.now.timeIntervalSince(t) > 7 * 86400
            out.append(.init(area: .recovery, level: old ? .warning : .ok, text: old ? "latest recovery snapshot is over a week old" : "recovery snapshot available", asset: nil))
        } else if !i.doc.transactions.isEmpty {
            out.append(.init(area: .recovery, level: .warning, text: "no local recovery snapshot yet", asset: nil))
        }
        return out.sorted { $0.level != $1.level ? $0.level > $1.level : $0.area.rawValue < $1.area.rawValue }
    }
}
