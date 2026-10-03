import PFCore
import PFCoreTestSupport
import Foundation
import Testing
@testable import PFTerminal

/// The Mac half of the Mac ↔ iPhone check (the iOS test target runs the real iPhone store).
/// Client A is the real macOS `AppStore`; client B is an iPhone-shaped SyncHost using the same
/// PFCore engine. Throwaway storage and the in-memory CloudKit stand-in only.
@MainActor
struct MacPhoneCompatibilityTests {
    private let btc = AssetCatalog.known.first { $0.symbol == "BTC" }!

    private func macStore(_ r: MockRemote) -> AppStore {
        var o = AppStore.Options()
        o.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pf-mac-\(UUID().uuidString)")
        o.inMemory = true
        o.mockMarket = true
        o.publishWidgets = false
        o.defaults = UserDefaults(suiteName: "pf.mac.test.\(UUID().uuidString)")!
        o.syncRemote = r
        return AppStore(o)
    }

    @Test func macLedgerReachesPhoneAndPhoneEditsReachMac() async throws {
        let r = MockRemote()
        let mac = macStore(r)
        mac.createEmpty()
        let main = mac.doc.portfolios[0].id
        mac.doc.upsert(Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 60000, timestamp: PortfolioInfo.stamp(Date().addingTimeInterval(-86400))), asset: btc)
        mac.save()
        try await SyncEngine.enable(mac, remote: r, choice: .upload, deviceName: "MacBook Pro")

        let phone = Device("iPhone", PortfolioDocument(portfolios: []), clock: PortfolioInfo.stamp(Date()))   // whole seconds, as stored
        try await phone.enable(r, .useCloud)
        #expect(phone.doc.portfolios.map(\.id) == [main])
        #expect(Set(phone.doc.transactions) == Set(mac.doc.transactions), "identical records, identical ids")

        // The iPhone adds a transaction; the Mac's next cycle applies it without duplicates.
        phone.tick()
        let t = Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 70000, timestamp: phone.clock)
        phone.doc.transactions.append(t)
        try await phone.sync(r)
        try await SyncEngine.cycle(mac, remote: r)
        #expect(mac.doc.transactions.first { $0.id == t.id } == t)
        #expect(mac.doc.transactions.count == 2)
        #expect(await r.liveCount == (1, 2))

        // The Mac deletes it again: the tombstone reaches the iPhone.
        mac.deleteTx(t)
        try await SyncEngine.cycle(mac, remote: r)
        try await phone.sync(r)
        #expect(!phone.doc.transactions.contains { $0.id == t.id })
    }

    /// The Mac's ledger gets reset while sync is on (unreadable portfolio.json set aside, then
    /// "1 empty" in onboarding): iCloud keeps everything and the Mac gets its portfolios back.
    @Test func resetMacDocumentRecoversFromICloudInsteadOfWipingIt() async throws {
        let r = MockRemote()
        let mac = macStore(r)
        mac.createEmpty()
        let main = mac.doc.portfolios[0].id
        mac.doc.upsert(Transaction(portfolioID: main, assetID: btc.id, type: .buy, quantity: 1, price: 60000, timestamp: PortfolioInfo.stamp(Date())), asset: btc)
        mac.save()
        try await SyncEngine.enable(mac, remote: r, choice: .upload, deviceName: "Mac")
        #expect(await r.liveCount == (1, 1))

        mac.createEmpty()                        // save() queues changes right away (scheduleSync)
        #expect(mac.syncState.known.values.allSatisfy { $0.deletedAt == nil }, "no tombstones queued")
        try await SyncEngine.cycle(mac, remote: r)
        #expect(await r.liveCount == (1, 1))
        #expect(mac.doc.portfolios.map(\.id) == [main] && mac.doc.transactions.count == 1)
    }
}
