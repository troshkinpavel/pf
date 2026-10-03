import Foundation

/// Classifies transactions before they are merged into a portfolio, so nothing is silently
/// duplicated or dropped. Nothing is applied here.
public enum ImportPlanner {
    public enum Status: String, CaseIterable, Sendable { case ready, duplicate, review, invalid }

    public struct Item: Identifiable, Sendable {
        public var id: UUID { tx.id }
        public let tx: Transaction           // re-owned by the target portfolio, original id kept
        public let status: Status
        public let reason: String
    }

    public struct Plan: Sendable {
        public let items: [Item]
        public func count(_ s: Status) -> Int { items.filter { $0.status == s }.count }
        public func transactions(_ s: Set<Status>) -> [Transaction] { items.filter { s.contains($0.status) }.map(\.tx) }
    }

    /// Same economic event: asset, type, time to the second, quantity, price, fee.
    public static func fingerprint(_ t: Transaction) -> String {
        "\(t.assetID)|\(t.type.rawValue)|\(Int(t.timestamp.timeIntervalSince1970))|\(t.quantity)|\(t.price)|\(t.fee)"
    }
    static func sameDayKey(_ t: Transaction) -> String { "\(t.assetID)|\(t.type.rawValue)|\(t.quantity)|\(DateFmt.ymd(t.timestamp))" }

    public static func plan(_ incoming: [Transaction], into pid: UUID, doc: PortfolioDocument, knownAssets: Set<AssetID>) -> Plan {
        let byID = Dictionary(doc.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let target = doc.transactions.filter { $0.portfolioID == pid }
        let others = doc.transactions.filter { $0.portfolioID != pid }
        let targetFP = Dictionary(grouping: target, by: fingerprint)
        let otherFP = Dictionary(grouping: others, by: fingerprint)
        let targetDay = Dictionary(grouping: target, by: sameDayKey)
        let name = { (id: UUID) in doc.portfolio(id)?.name ?? "another portfolio" }
        var seen: [String: Int] = [:]
        var items: [Item] = []
        for raw in incoming {
            var t = raw; t.portfolioID = pid
            let fp = fingerprint(t)
            defer { seen[fp, default: 0] += 1 }
            func add(_ s: Status, _ r: String) { items.append(Item(tx: t, status: s, reason: r)) }
            if t.quantity <= 0 { add(.invalid, "quantity must be greater than 0"); continue }
            if t.price < 0 || t.fee < 0 { add(.invalid, "negative price or fee"); continue }
            if !knownAssets.contains(t.assetID) { add(.invalid, "unknown asset"); continue }
            if let same = byID[raw.id] {
                same.portfolioID == pid ? add(.duplicate, "already in this portfolio (same record)")
                                        : add(.review, "the same record is in \(name(same.portfolioID))")
                continue
            }
            if let hit = targetFP[fp]?.first {
                if let a = hit.note, let b = t.note, !a.isEmpty, !b.isEmpty, a != b { add(.review, "same trade, different note") }
                else { add(.duplicate, "identical transaction already in this portfolio") }
                continue
            }
            if seen[fp, default: 0] > 0 { add(.review, "repeated in the imported file"); continue }
            if let o = otherFP[fp]?.first { add(.review, "identical transaction in \(name(o.portfolioID))"); continue }
            if targetDay[sameDayKey(t)] != nil { add(.review, "same asset, amount and day; different price, fee or time"); continue }
            add(.ready, "")
        }
        // Ready rows must keep the ledger valid (e.g. no sell before its buy).
        let ledger = target + items.filter { $0.status == .ready }.map(\.tx)
        let bad = Set(PortfolioEngine.validate(ledger, knownAssets: knownAssets).compactMap { e -> UUID? in
            if case let .oversold(id, _, _) = e { return id }; return nil
        })
        if !bad.isEmpty {
            items = items.map { $0.status == .ready && bad.contains($0.tx.id) ? Item(tx: $0.tx, status: .invalid, reason: "sells more than held at that date") : $0 }
        }
        return Plan(items: items)
    }

    /// Groups of transactions in the same portfolio that look like the same trade entered twice.
    public static func likelyDuplicates(in doc: PortfolioDocument) -> [[Transaction]] {
        Dictionary(grouping: doc.transactions) { "\($0.portfolioID)|" + fingerprint($0) }
            .values.filter { $0.count > 1 }.sorted { $0[0].timestamp < $1[0].timestamp }
    }
}
