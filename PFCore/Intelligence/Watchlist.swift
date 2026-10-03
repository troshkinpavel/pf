import Foundation

/// An asset the user follows without holding it (design §05). Keyed by the canonical
/// `AssetID` (never a ticker) and global across portfolios. Converting it to a position
/// archives it (kept for context and undo); it is only deleted on an explicit remove.
public struct WatchItem: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), asset: Asset, addedAt: Date, priceAtAdd: Decimal?, entry: Decimal? = nil, target: Decimal? = nil,
                note: String? = nil, archivedAt: Date? = nil, convertedTx: UUID? = nil) {
        self.id = id; self.asset = asset; self.addedAt = addedAt; self.priceAtAdd = priceAtAdd; self.entry = entry; self.target = target
        self.note = note; self.archivedAt = archivedAt; self.convertedTx = convertedTx
    }
    public var id: UUID
    /// Identity + metadata (symbol, routing) so a watched asset can be priced without a ledger entry.
    public var asset: Asset
    public var addedAt: Date
    /// Price when it was added; nil if no price was known then (SINCE ADDED shows —).
    public var priceAtAdd: Decimal?
    /// Planned entry price (buy at or below).
    public var entry: Decimal?
    public var target: Decimal?
    public var note: String?
    /// Set when converted to a position (or archived): hidden from the list, kept as context.
    public var archivedAt: Date?
    public var convertedTx: UUID?

    public var assetID: AssetID { asset.id }
    public var isActive: Bool { archivedAt == nil }
}

public enum Watchlist {
    public struct Row: Equatable, Sendable {
        public let item: WatchItem
        public let price: Decimal?
        public let change24h: Double?
        /// Price change since the item was added, in %.
        public let sinceAdded: Double?
        /// How far the price must fall to reach the entry, in % (negative = above entry).
        /// ≥ 0 means at or below entry ("at entry").
        public let toEntry: Double?
        public var atEntry: Bool { (toEntry ?? -1) >= 0 }
    }

    public static func row(_ w: WatchItem, quote: Quote?) -> Row {
        let p = quote?.price
        let since: Double? = { guard let p, let a = w.priceAtAdd, a > 0 else { return nil }; return ((p / a) - 1).double * 100 }()
        let toEntry: Double? = { guard let p, p > 0, let e = w.entry else { return nil }; return ((e / p) - 1).double * 100 }()
        return Row(item: w, price: p, change24h: quote?.change24h, sinceAdded: since, toEntry: toEntry)
    }

    /// Active items, sorted by distance to entry (closest first; items without an entry last,
    /// then by add date, newest first).
    public static func rows(_ items: [WatchItem], quotes: [AssetID: Quote]) -> [Row] {
        items.filter(\.isActive).map { row($0, quote: quotes[$0.assetID]) }.sorted { a, b in
            switch (a.toEntry, b.toEntry) {
            case let (x?, y?): return x != y ? x > y : a.item.addedAt > b.item.addedAt
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.item.addedAt > b.item.addedAt
            }
        }
    }

    /// Adds an asset unless it is already actively watched (by canonical id). Returns the item.
    @discardableResult
    public static func add(_ asset: Asset, price: Decimal?, entry: Decimal? = nil, target: Decimal? = nil, note: String? = nil,
                           to doc: inout IntelDocument, now: Date) -> WatchItem {
        if let i = doc.watchlist.firstIndex(where: { $0.assetID == asset.id && $0.isActive }) {
            if let entry { doc.watchlist[i].entry = entry }
            if let target { doc.watchlist[i].target = target }
            if let note, !note.isEmpty { doc.watchlist[i].note = note }
            return doc.watchlist[i]
        }
        let w = WatchItem(asset: asset, addedAt: now, priceAtAdd: price, entry: entry, target: target, note: note?.isEmpty == true ? nil : note)
        doc.watchlist.append(w)
        return w
    }

    public static func remove(_ id: UUID, from doc: inout IntelDocument) { doc.watchlist.removeAll { $0.id == id } }

    /// The most recent watch history for an asset (active or archived), for Asset Detail context.
    public static func history(_ asset: AssetID, in doc: IntelDocument) -> WatchItem? {
        doc.watchlist.filter { $0.assetID == asset }.max { $0.addedAt < $1.addedAt }
    }
}

// MARK: - Watch → position

/// Converting a watched asset into a position (design §06). It produces a real ledger
/// transaction through the normal planner; this only computes what is carried over and the
/// review numbers. Nothing here touches accounting.
public enum WatchConversion {
    public struct CarryOver: Equatable, Sendable {
        public init(target: Bool = true, note: Bool = true, alert: Bool = true, keepWatching: Bool = false) {
            self.target = target; self.note = note; self.alert = alert; self.keepWatching = keepWatching
        }
        public var target, note, alert, keepWatching: Bool
    }

    public struct Review: Equatable, Sendable {
        public let cost: Decimal
        public let vsWatchAdd: Double?      // % vs the price when it was added
        public let vsEntry: Double?         // % vs the planned entry
        public let weightAfter: Double?     // % of the destination portfolio after the buy
    }

    public static func review(_ w: WatchItem, quantity: Decimal, price: Decimal, fee: Decimal, portfolioValue: Decimal) -> Review {
        let cost = quantity * price + fee
        let pct = { (ref: Decimal?) -> Double? in ref.flatMap { $0 > 0 ? ((price / $0) - 1).double * 100 : nil } }
        let after = portfolioValue + quantity * price
        return Review(cost: cost, vsWatchAdd: pct(w.priceAtAdd), vsEntry: pct(w.entry),
                      weightAfter: after > 0 ? ((quantity * price) / after).double * 100 : nil)
    }

    /// Applies the carry-over to the intel document after the transaction was recorded.
    /// Returns the previous document for ⌘Z.
    @discardableResult
    public static func apply(_ w: WatchItem, tx: UUID, carry: CarryOver, to doc: inout IntelDocument, now: Date) -> IntelDocument {
        let before = doc
        if carry.target, let t = w.target {
            let base = Scenarios.ensureBase(in: &doc, now: now)
            if let i = doc.scenarios.firstIndex(where: { $0.id == base }) {
                doc.scenarios[i].targets[w.assetID, default: ScenarioTarget(price: t)].price = t
                doc.scenarios[i].editedAt = now
            }
        }
        if carry.alert {
            // The entry alert has done its job; a target alert takes over (re-armed above target).
            for i in doc.alerts.indices where doc.alerts[i].subject == .asset(w.assetID) && doc.alerts[i].kind == .priceBelow {
                doc.alerts[i].paused = true
            }
            if let t = w.target {
                doc.alerts.append(AlertRule(number: doc.nextAlertNumber, kind: .priceAbove, subject: .asset(w.assetID), threshold: t.double,
                                            repeatMode: .once, createdAt: now, note: "carried over from the watchlist"))
            }
        }
        if !carry.keepWatching, let i = doc.watchlist.firstIndex(where: { $0.id == w.id }) {
            doc.watchlist[i].archivedAt = now
            doc.watchlist[i].convertedTx = tx
        }
        return before
    }
}
