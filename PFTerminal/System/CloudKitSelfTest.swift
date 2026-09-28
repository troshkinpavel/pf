#if DEBUG
import PFCore
import PFCoreUI
import AppKit
import CloudKit

/// DEBUG only: `--ui-testing --cloudkit-selftest` exercises the raw CloudKit operations that
/// CloudKitSyncStore relies on, in a throwaway zone of the signed-in account's private database
/// (never PFZone), then deletes that zone. Prints one PASS/FAIL line per stage. The app's own
/// ledger is never touched (run with --ui-testing).
enum CloudKitSelfTest {
    /// `--ui-testing --list-pfzone`: metadata of the real PFZone (counts, times, device) — no payloads.
    @MainActor
    static func listZoneIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--list-pfzone"), let id = AppStore.cloudContainerID else { return }
        Task { @MainActor in
            let db = CKContainer(identifier: id).privateCloudDatabase
            print("environment", AppStore.cloudEnvironment, "· zones:", (try? await db.allRecordZones().map(\.zoneID.zoneName).sorted()) ?? [])
            let zone = CKRecordZone.ID(zoneName: CloudKitSyncStore.zoneName, ownerName: CKCurrentUserDefaultName)
            if let ch = try? await db.recordZoneChanges(inZoneWith: zone, since: nil) {
                let recs = ch.modificationResultsByID.values.compactMap { try? $0.get().record }
                let kinds = Dictionary(grouping: recs, by: { $0["kind"] as? String ?? "?" }).mapValues(\.count)
                let created = recs.compactMap(\.creationDate).sorted()
                print("PFZone records:", recs.count, kinds, "· created", created.first.map { "\($0)" } ?? "-", "…", created.last.map { "\($0)" } ?? "-",
                      "· devices:", Set(recs.compactMap { $0["deviceName"] as? String }))
            } else { print("PFZone: none") }
            exit(0)
        }
    }

    @MainActor
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--cloudkit-selftest") else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ stage: String) { print(ok ? "PASS" : "FAIL", stage); if !ok { failures += 1 } }

            print("container:", AppStore.cloudContainerID ?? "none", "· environment", AppStore.cloudEnvironment, "(from entitlement)")
            guard AppStore.hasCloudEntitlement, let id = AppStore.cloudContainerID else { check(false, "CloudKit entitlement"); exit(1) }
            let db = CKContainer(identifier: id).privateCloudDatabase
            let store = CloudKitSyncStore(containerIdentifier: id, zoneName: "PFSelfTest-\(UUID().uuidString.prefix(8))")
            let zone = store.zoneID

            // 1 account
            let status = await store.accountStatus()
            check(status == .available, "1 iCloud account available (\(status))")
            do {
                // 2 private database access
                let zones = try await db.allRecordZones()
                check(true, "2 private database access (zones: \(zones.map(\.zoneID.zoneName).sorted().joined(separator: ", ")))")
                check(!zones.contains { $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone" }, "2b no SwiftData/Core Data mirroring zone in the private database")

                // 3 zone creation (fetch on a missing zone creates it, as the engine does)
                let empty = try await store.fetchChanges(since: nil)
                let after = try await db.allRecordZones()
                check(empty.records.isEmpty && after.contains { $0.zoneID == zone }, "3 custom zone created (\(zone.zoneName))")

                // 4 CKRecord creation (engine mapping)
                let tx = Transaction(portfolioID: UUID(), assetID: "cg:bitcoin", type: .buy, quantity: Decimal(string: "0.12345678")!,
                                     price: 58400, timestamp: Date(timeIntervalSince1970: 1_725_000_000), fee: Decimal(string: "1.5")!)
                let payload = try SyncEngine.encoder.encode(tx)
                let rec = SyncRecord(kind: .transaction, id: tx.id.uuidString, modifiedAt: Date(), deviceID: "selftest", deviceName: "selftest",
                                     payload: payload, portfolioID: tx.portfolioID.uuidString)
                let ck = store.ckRecord(rec)
                check(ck.recordType == "PFRecord" && ck.recordID.zoneID == zone && ck.encryptedValues["payload"] as? Data == payload,
                      "4 CKRecord built (type PFRecord, name \(rec.key.prefix(20))…, payload in encryptedValues)")

                // 5a raw save, so a failure shows the unmapped CKError
                let probe = CKRecord(recordType: CloudKitSyncStore.recordType, recordID: .init(recordName: "probe", zoneID: zone))
                probe["kind"] = "probe"
                let pr = try await db.modifyRecords(saving: [probe], deleting: [], savePolicy: .allKeys, atomically: false).saveResults
                if case let .failure(e)? = pr.values.first {
                    let c = e as? CKError
                    print("raw save error: code \(c?.code.rawValue ?? -1) · retryAfter \(c?.retryAfterSeconds ?? 0) · \((e as NSError).userInfo[NSLocalizedDescriptionKey] ?? "") · server: \((e as NSError).userInfo["ServerErrorDescription"] ?? "-")")
                } else { _ = try? await db.modifyRecords(saving: [], deleting: [probe.recordID]) }

                // 5 save
                let out = try await store.save([rec])
                guard case let .saved(_, tag, v1)? = out.first else { check(false, "5 save: \(out)"); throw SyncStoreError.unavailable("save") }
                check(v1 != nil, "5 CKRecord saved (change tag \(v1 ?? "-"))")

                // 6 fetch
                let f1 = try await store.fetchChanges(since: nil)
                let got = f1.records.first { $0.key == rec.key }
                check(got?.payload == payload && got?.remoteVersion == v1, "6 fetched with identical payload and version")
                check(got.flatMap { try? PortfolioDocument.decoder.decode(Transaction.self, from: $0.payload!) } == tx,
                      "6b payload decodes to the identical transaction (decimals, ids, date)")

                // 7 modification (current version → accepted; stale version → conflict)
                var edited = tx; edited.note = "modified"
                var r2 = rec; r2.payload = try SyncEngine.encoder.encode(edited); r2.remoteTag = tag; r2.remoteVersion = v1; r2.modifiedAt = Date()
                let out2 = try await store.save([r2])
                guard case let .saved(_, tag2, v2)? = out2.first else { check(false, "7 modify: \(out2)"); throw SyncStoreError.unavailable("modify") }
                check(v2 != v1, "7 record modified (tag \(v1 ?? "-") → \(v2 ?? "-"))")
                var stale = r2; stale.remoteTag = tag; stale.remoteVersion = v1
                let out3 = try await store.save([stale])
                if case let .conflict(_, server)? = out3.first { check(server.remoteVersion == v2, "7b stale write rejected as conflict (serverRecordChanged), server version returned") }
                else { check(false, "7b stale write should conflict: \(out3)") }

                // 8 change token
                let f2 = try await store.fetchChanges(since: f1.token)
                check(f2.records.count == 1 && f2.records[0].remoteVersion == v2, "8 fetch since token returns only the change (\(f2.records.count) record)")
                let f3 = try await store.fetchChanges(since: f2.token)
                check(f3.records.isEmpty, "8b fetch since latest token is empty")

                // 9 tombstone (how the engine deletes) + hard delete
                var tomb = r2; tomb.payload = nil; tomb.deletedAt = Date(); tomb.remoteTag = tag2; tomb.remoteVersion = v2
                _ = try await store.save([tomb])
                let f4 = try await store.fetchChanges(since: f3.token)
                check(f4.records.first?.isTombstone == true && f4.records.first?.payload == nil, "9 tombstone saved and fetched via change token")
                let del = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: rec.key, zoneID: zone)]).deleteResults
                check((try? del.values.first?.get()) != nil, "9b hard delete of the CKRecord (engine itself uses tombstones)")
            } catch {
                check(false, "CloudKit: \(error)")
            }
            // 10 cleanup
            do {
                try await store.deleteZone()
                let z = try await db.allRecordZones()
                check(!z.contains { $0.zoneID == zone }, "10 temporary zone deleted")
            } catch { check(false, "10 cleanup: \(error)") }
            print(failures == 0 ? "CLOUDKIT SELFTEST PASSED" : "CLOUDKIT SELFTEST FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
