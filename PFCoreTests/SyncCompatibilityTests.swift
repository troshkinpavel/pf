import CloudKit
import Foundation
import Testing
import PFCore

// The wire format every PF client shares (CloudKit record fields + JSON payloads). Run on
// macOS (`swift test`) and inside each client's own test run.

/// A payload exactly as the Mac writes it today (sorted keys, ISO 8601, decimals as strings).
/// If this test fails on either platform, the platforms no longer interoperate.
private let macTransactionPayload = #"{"assetID":"cg:bitcoin","currency":"USD","fee":"0","id":"6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11","portfolioID":"0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E","price":"58400","quantity":"0.12","timestamp":"2024-09-06T12:00:00Z","type":"BUY"}"#
private let macPortfolioPayload = #"{"createdAt":"2024-09-06T00:00:00Z","glyph":"◈","id":"0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E","isDemo":false,"name":"MAIN","status":"active"}"#

private func fixtureDoc() -> PortfolioDocument {
    let pid = UUID(uuidString: "0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E")!
    let p = PortfolioInfo(id: pid, name: "MAIN", glyph: "◈", createdAt: ISO8601DateFormatter().date(from: "2024-09-06T00:00:00Z")!)
    let t = Transaction(id: UUID(uuidString: "6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11")!, portfolioID: pid, assetID: "cg:bitcoin", type: .buy,
                        quantity: Decimal(string: "0.12")!, price: 58400, timestamp: ISO8601DateFormatter().date(from: "2024-09-06T12:00:00Z")!)
    return PortfolioDocument(portfolios: [p], assets: [AssetCatalog.known.first { $0.symbol == "BTC" }!], transactions: [t])
}

struct SyncCompatibilityTests {
    @Test func payloadsAreByteIdenticalToTheMacFormat() {
        let objs = SyncEngine.localObjects(fixtureDoc())
        let tx = objs["transaction.6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11"]!
        let pf = objs["portfolio.0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E"]!
        #expect(String(decoding: tx.payload, as: UTF8.self) == macTransactionPayload)
        #expect(String(decoding: pf.payload, as: UTF8.self) == macPortfolioPayload)
        #expect(tx.portfolioID == "0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E")
    }

    @Test func macPayloadDecodesToTheSameModel() throws {
        let t = try PortfolioDocument.decoder.decode(Transaction.self, from: Data(macTransactionPayload.utf8))
        #expect(t == fixtureDoc().transactions[0])
        let p = try PortfolioDocument.decoder.decode(PortfolioInfo.self, from: Data(macPortfolioPayload.utf8))
        #expect(p == fixtureDoc().portfolios[0])
    }

    @Test func applyingAMacRecordUpsertsByStableID() {
        let r = SyncRecord(kind: .transaction, id: "6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11", modifiedAt: Date(), deviceID: "mac", deviceName: "MacBook Pro",
                           payload: Data(macTransactionPayload.utf8), portfolioID: "0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E")
        var doc = fixtureDoc()
        #expect(SyncEngine.apply(r, &doc))
        #expect(SyncEngine.apply(r, &doc))
        #expect(doc.transactions.count == 1, "same stable id → no duplicate")
    }

    /// The CloudKit schema both apps rely on: private DB, zone PFZone, record type PFRecord,
    /// record name "<kind>.<id>", payload only in encryptedValues.
    @Test func cloudKitRecordMappingRoundTrips() {
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncStore.zoneName, ownerName: CKCurrentUserDefaultName)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let r = SyncRecord(kind: .transaction, id: "6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11", modifiedAt: when, deviceID: "dev-1", deviceName: "iPhone",
                           payload: Data(macTransactionPayload.utf8), portfolioID: "0F3B7C2A-1111-4C4C-9A9A-5E5E5E5E5E5E")
        let ck = CloudKitSyncStore.ckRecord(r, zoneID: zone)
        #expect(CloudKitSyncStore.recordType == "PFRecord")
        #expect(CloudKitSyncStore.zoneName == "PFZone")
        #expect(ck.recordType == "PFRecord")
        #expect(ck.recordID.recordName == "transaction.6B1F0C1E-4A4D-4E1B-9D55-2F8B0C9A7E11")
        #expect(ck.recordID.zoneID.zoneName == "PFZone")
        #expect(ck["payload"] == nil, "the payload is never a plain field")
        #expect(ck.encryptedValues["payload"] as? Data == r.payload)
        let back = CloudKitSyncStore.record(ck)!
        #expect(back.kind == r.kind && back.id == r.id && back.schemaVersion == SyncRecord.currentSchema)
        #expect(back.modifiedAt == when && back.deletedAt == nil && back.deviceName == "iPhone" && back.portfolioID == r.portfolioID)
        #expect(back.payload == r.payload)
    }

    @Test func tombstonesCarryNoPayload() {
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncStore.zoneName, ownerName: CKCurrentUserDefaultName)
        let r = SyncRecord(kind: .transaction, id: UUID().uuidString, modifiedAt: Date(), deletedAt: Date(), deviceID: "d", payload: nil)
        let back = CloudKitSyncStore.record(CloudKitSyncStore.ckRecord(r, zoneID: zone))!
        #expect(back.isTombstone && back.payload == nil)
    }

    /// Market data, caches and settings are not sync record kinds.
    @Test func onlyUserOwnedRecordsSync() {
        #expect(Set(SyncKind.allCases.map(\.rawValue)) == ["portfolio", "transaction", "asset"])
        var doc = fixtureDoc()
        doc.settings = AppSettings()
        let payloads = SyncEngine.localObjects(doc).values.map { String(decoding: $0.payload, as: UTF8.self) }
        #expect(payloads.allSatisfy { !$0.contains("refreshSeconds") && !$0.contains("coingecko-api-key") })
        let asset = SyncEngine.localObjects(doc)["asset.cg:bitcoin"]!
        #expect(!String(decoding: asset.payload, as: UTF8.self).contains("\"price\""), "asset identity only, no market data")
    }

    @Test func newerSchemaRecordsAreBlockedNotApplied() {
        var doc = fixtureDoc(), st = SyncState()
        var r = SyncRecord(kind: .transaction, id: UUID().uuidString, modifiedAt: Date(), deviceID: "future", payload: Data("{}".utf8))
        r.schemaVersion = SyncRecord.currentSchema + 1
        SyncEngine.applyRemote([r], &doc, &st, now: Date())
        #expect(st.blocked.contains(r.key))
        #expect(doc.transactions.count == 1)
    }

    @Test func olderSyncStateFilesStillDecode() throws {
        // A sync-state.json written before the device stamps existed (v0.4 Mac).
        let old = #"{"mode":"iCloud","deviceID":"A","deviceName":"MacBook Pro","known":{},"conflicts":[],"blocked":[]}"#
        let st = try JSONDecoder().decode(SyncState.self, from: Data(old.utf8))
        #expect(st.mode == .iCloud && st.devices == nil && st.lastRemoteChange == nil)
    }
}

/// TEL has no Binance pair; when CoinGecko is rate-limited it must still get a price.
struct PriceFallbackTests {
    private struct Failing: MarketDataProvider {
        let name = "CoinGecko"
        func supports(_ a: Asset) -> Bool { a.coingeckoID != nil }
        func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] { throw MarketError.rateLimited(retryAfter: 60) }
    }
    /// Answers like DexScreener, for exactly what the real provider supports.
    private struct DexStub: MarketDataProvider {
        let name = "DexScreener"
        func supports(_ a: Asset) -> Bool { DexScreenerProvider().supports(a) }
        func quotes(for assets: [Asset], currency: String) async throws -> [AssetID: Quote] {
            Dictionary(uniqueKeysWithValues: assets.filter(supports).map { ($0.id, Quote(price: Decimal(string: "0.0019")!, source: name, timestamp: Date())) })
        }
    }

    @Test func telHasADexFallbackUnderItsExistingID() {
        let tel = AssetCatalog.known.first { $0.symbol == "TEL" }!
        #expect(tel.id == "cg:telcoin" && tel.binanceSymbol == nil)
        #expect(DexScreenerProvider().supports(tel))
        #expect(AssetCatalog.dexIdentity(tel)?.chain == "ethereum")
        #expect(AssetCatalog.dexIdentity(tel)?.contract == "0x7e13b43065380acdec1c2d138c579cbbbafa0731", "the canonical telcoin-2 contract")
        // A TEL identity synced from an older ledger (no chain/contract) is covered too.
        let synced = Asset(id: "cg:telcoin", symbol: "TEL", name: "Telcoin", coingeckoID: "telcoin-2")
        #expect(DexScreenerProvider().supports(synced))
        #expect(!DexScreenerProvider().supports(AssetCatalog.known.first { $0.symbol == "BTC" }!))
    }

    @Test func rateLimitedCoinGeckoFallsThroughForTEL() async {
        let tel = AssetCatalog.known.first { $0.symbol == "TEL" }!
        let r = await ProviderRouter(providers: [Failing(), DexStub()]).quotes(for: [tel], currency: "USD")
        #expect(r.quotes[tel.id]?.source == "DexScreener")
        #expect(r.unresolved.isEmpty)
    }
}

/// The headline total both apps show: exact when fully priced, "≈ … · N unpriced" otherwise.
struct PartialTotalLabelTests {
    let f = Fmt(style: .comma, currency: "USD")
    let assets = Dictionary(uniqueKeysWithValues: ["BTC", "ETH", "TEL"].map { s in
        let a = AssetCatalog.known.first { $0.symbol == s }!; return (a.id, a) })
    var ids: [AssetID] { ["BTC", "ETH", "TEL"].map { s in assets.values.first { $0.symbol == s }!.id } }

    func summary(priced: Set<Int>) -> PortfolioSummary {
        let pid = UUID(), t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let txs = ids.map { Transaction(portfolioID: pid, assetID: $0, type: .buy, quantity: 1, price: 10, currency: "USD", timestamp: t0) }
        let prices: [Decimal] = [90_000, 6_380, 0.002]
        let quotes = Dictionary(uniqueKeysWithValues: priced.map { (ids[$0], Quote(price: prices[$0], source: "test", timestamp: t0)) })
        return PortfolioEngine.summarize(transactions: txs, assets: assets, quotes: quotes, now: t0.addingTimeInterval(60))
    }

    @Test func fullyPriced() {
        let s = summary(priced: [0, 1, 2])
        #expect(!s.isPartial)
        #expect(s.totalLabel(f) == "$96,380.00")
    }

    @Test func oneUnpriced() {
        let s = summary(priced: [0, 1])
        #expect(s.isPartial && s.unpriced == [ids[2]])
        #expect(s.totalLabel(f) == "≈ $96,380.00 · 1 unpriced")
        #expect(s.valuation(ids[2])?.value == nil, "the unpriced row stays unpriced, no guessed value")
    }

    @Test func multipleUnpriced() {
        let s = summary(priced: [0])
        #expect(s.totalLabel(f) == "≈ $90,000.00 · 2 unpriced")
    }

    @Test func recovery() {
        #expect(summary(priced: [0]).isPartial)
        let back = summary(priced: [0, 1, 2])
        #expect(!back.isPartial && back.totalLabel(f, 0) == "$96,380")
    }
}
