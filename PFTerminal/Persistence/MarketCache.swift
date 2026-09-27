import Foundation
import SwiftData

@Model final class SnapshotRecord {
    var context: String = ""       // PortfolioContext.storageKey; "" = recorded before multi-portfolio
    var timestamp: Date
    var value: Double
    var costBasis: Double
    var unrealized: Double
    init(_ s: PortfolioSnapshotValue, context: String) { self.context = context; timestamp = s.timestamp; value = s.value; costBasis = s.costBasis; unrealized = s.unrealized }
    var snapshot: PortfolioSnapshotValue { .init(timestamp: timestamp, value: value, costBasis: costBasis, unrealized: unrealized) }
}

@Model final class CachedQuoteRecord {
    @Attribute(.unique) var key: String          // assetID|currency
    var payload: Data
    var timestamp: Date
    init(key: String, payload: Data, timestamp: Date) { self.key = key; self.payload = payload; self.timestamp = timestamp }
}

@Model final class CachedHistoryRecord {
    @Attribute(.unique) var key: String          // assetID|range|currency
    var payload: Data
    var fetchedAt: Date
    init(key: String, payload: Data, fetchedAt: Date) { self.key = key; self.payload = payload; self.fetchedAt = fetchedAt }
}

/// Local cache of market data (last-known quotes, price history) and portfolio snapshots.
/// Market data here is public information; snapshots stay on this Mac.
@MainActor
final class MarketCache {
    let container: ModelContainer
    private var ctx: ModelContext { container.mainContext }

    init(directory: URL?, inMemory: Bool = false) {
        let schema = Schema([SnapshotRecord.self, CachedQuoteRecord.self, CachedHistoryRecord.self])
        let config: ModelConfiguration
        if inMemory || directory == nil {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            try? FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
            // `.none`: with the iCloud entitlement SwiftData would otherwise mirror this store to
            // CloudKit automatically. Market data is a local cache and never syncs.
            config = ModelConfiguration(schema: schema, url: directory!.appendingPathComponent("market.store"), cloudKitDatabase: .none)
        }
        if let c = try? ModelContainer(for: schema, configurations: config) {
            container = c
        } else {
            // Corrupt or incompatible cache: it is only a cache, start fresh in memory.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
    }

    // MARK: quotes
    func saveQuotes(_ q: [AssetID: Quote], currency: String) {
        let enc = JSONEncoder()
        for (id, quote) in q {
            let key = id + "|" + currency
            guard let data = try? enc.encode(quote) else { continue }
            let fd = FetchDescriptor<CachedQuoteRecord>(predicate: #Predicate { $0.key == key })
            if let r = try? ctx.fetch(fd).first { r.payload = data; r.timestamp = quote.timestamp }
            else { ctx.insert(CachedQuoteRecord(key: key, payload: data, timestamp: quote.timestamp)) }
        }
        try? ctx.save()
    }

    func quotes(currency: String) -> [AssetID: Quote] {
        let dec = JSONDecoder()
        let suffix = "|" + currency
        let rows = (try? ctx.fetch(FetchDescriptor<CachedQuoteRecord>())) ?? []
        var out: [AssetID: Quote] = [:]
        for r in rows where r.key.hasSuffix(suffix) {
            if var q = try? dec.decode(Quote.self, from: r.payload) {
                q.source = "cache"
                out[String(r.key.dropLast(suffix.count))] = q
            }
        }
        return out
    }

    // MARK: history
    func history(_ id: AssetID, _ range: ChartRange, _ currency: String) -> (points: [PricePoint], fetchedAt: Date)? {
        let key = "\(id)|\(range.rawValue)|\(currency)"
        let fd = FetchDescriptor<CachedHistoryRecord>(predicate: #Predicate { $0.key == key })
        guard let r = try? ctx.fetch(fd).first, let p = try? JSONDecoder().decode([PricePoint].self, from: r.payload) else { return nil }
        return (p, r.fetchedAt)
    }

    func saveHistory(_ id: AssetID, _ range: ChartRange, _ currency: String, _ points: [PricePoint]) {
        let key = "\(id)|\(range.rawValue)|\(currency)"
        guard let data = try? JSONEncoder().encode(points) else { return }
        let fd = FetchDescriptor<CachedHistoryRecord>(predicate: #Predicate { $0.key == key })
        if let r = try? ctx.fetch(fd).first { r.payload = data; r.fetchedAt = Date() }
        else { ctx.insert(CachedHistoryRecord(key: key, payload: data, fetchedAt: Date())) }
        try? ctx.save()
    }

    func deleteHistory(assetID: AssetID) {
        for r in (try? ctx.fetch(FetchDescriptor<CachedHistoryRecord>())) ?? [] where r.key.hasPrefix(assetID + "|") { ctx.delete(r) }
        try? ctx.save()
    }

    // MARK: snapshots
    /// Snapshots are per context: MAIN's history never shows up for TRADING.
    func addSnapshot(_ s: PortfolioSnapshotValue, context: String, minInterval: TimeInterval = 300) {
        var fd = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.context == context }, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        fd.fetchLimit = 1
        if let last = try? ctx.fetch(fd).first, s.timestamp.timeIntervalSince(last.timestamp) < minInterval { return }
        ctx.insert(SnapshotRecord(s, context: context))
        try? ctx.save()
    }

    func snapshots(since: Date, context: String) -> [PortfolioSnapshotValue] {
        let fd = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.timestamp >= since && $0.context == context }, sortBy: [SortDescriptor(\.timestamp)])
        return ((try? ctx.fetch(fd)) ?? []).map(\.snapshot)
    }

    /// Pre-multi-portfolio snapshots belonged to the single ledger, which became MAIN.
    func assignLegacySnapshots(to context: String) {
        let fd = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.context == "" })
        for r in (try? ctx.fetch(fd)) ?? [] { r.context = context }
        try? ctx.save()
    }

    func deleteSnapshots(context: String) {
        try? ctx.delete(model: SnapshotRecord.self, where: #Predicate { $0.context == context })
        try? ctx.save()
    }

    /// A ledger edit dated `from` makes every later snapshot wrong.
    func invalidateSnapshots(from: Date) {
        try? ctx.delete(model: SnapshotRecord.self, where: #Predicate { $0.timestamp >= from })
        try? ctx.save()
    }

    func clearAll() {
        try? ctx.delete(model: SnapshotRecord.self)
        try? ctx.delete(model: CachedHistoryRecord.self)
        try? ctx.delete(model: CachedQuoteRecord.self)
        try? ctx.save()
    }
}
