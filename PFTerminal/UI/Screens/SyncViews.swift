import PFCore
import PFCoreUI
import SwiftUI

/// iCloud sync confirmations and conflict review. Every data-changing action is an explicit
/// click here; there is no keyboard shortcut or command that turns sync on or off.
struct SyncSheetView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TT(title, 12, Theme.t1, tracking: 0.72)
                Spacer()
                TT("esc cancel", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            content.padding(16)
        }
        .frame(width: 580)
    }

    private var title: String {
        switch store.syncSheet {
        case .disable?: "TURN OFF ICLOUD SYNC"
        case .conflicts?: "SYNC CONFLICTS"
        case .intelConflict?: "SYNC CONFLICT" + (store.intelConflict.map { "  " + store.intelConflictTitle($0) } ?? "")
        default: "ICLOUD SYNC"
        }
    }

    @ViewBuilder private var content: some View {
        switch store.syncSheet {
        case .checking?, nil:
            note("◐ checking your iCloud account and what's already there…", Theme.acc)
            buttons { BracketButton("cancel", color: Theme.t2) { store.syncSheet = nil } }
        case let .working(m)?:
            note("◐ \(m)", Theme.acc)
        case let .unavailable(m)?:
            note("✗ \(m)", Theme.neg)
            buttons { Spacer(); BracketButton("close", color: Theme.t2) { store.syncSheet = nil } }
        case let .confirm(i)?:
            confirm(i)
        case .disable?:
            VStack(alignment: .leading, spacing: 8) {
                note("your portfolios stay on this Mac, unchanged.", Theme.t1)
                note("the copy in your iCloud is not deleted; other devices using it keep it.", Theme.t3)
                note("changes made here stop syncing. turning sync on again compares both sides first.", Theme.t3)
            }
            buttons {
                BracketButton("cancel", color: Theme.t2) { store.syncSheet = nil }
                Spacer()
                BracketButton("turn off", color: Theme.acc) { store.confirmDisableSync() }
            }
        case .conflicts?:
            conflicts
        case .intelConflict?:
            intelConflict
        }
    }

    @ViewBuilder private func confirm(_ i: SyncEngine.Inspection) -> some View {
        let here = "this Mac: \(i.localPortfolios) portfolio\(i.localPortfolios == 1 ? "" : "s") · \(i.localTransactions) tx"
        let cloud = "iCloud:   \(i.cloudPortfolios) portfolio\(i.cloudPortfolios == 1 ? "" : "s") · \(i.cloudTransactions) tx"
            + (i.cloudDevices.isEmpty ? "" : " · from \(i.cloudDevices.joined(separator: ", "))")
        VStack(alignment: .leading, spacing: 8) {
            note(here, Theme.t1)
            note(cloud, Theme.t1)
            Hairline().padding(.vertical, 4)
            switch i.plan {
            case .upload:
                note("iCloud has no PF data yet. your portfolios and transactions will be uploaded to your private iCloud database.", Theme.t2)
            case .useCloud:
                note("this Mac has no transactions. PF will download your portfolios from iCloud.", Theme.t2)
            case .resume:
                note("both already hold the same portfolios and transactions. nothing is replaced.", Theme.t2)
            case .choose:
                note("both have data. choose how to combine them:", Theme.t2)
                note("MERGE      keeps every portfolio and transaction from both, matched by id. the same data imported on both sides is not duplicated; transactions typed in separately on each device are kept twice.", Theme.t3)
                note("USE ICLOUD replaces this Mac's portfolios with iCloud's. a copy of this Mac's ledger is saved next to portfolio.json first.", Theme.t3)
            }
            note("syncs: portfolios · transactions · asset identities. never: prices, api keys, settings, widget data.", Theme.t4)
        }
        buttons {
            BracketButton("cancel", color: Theme.t2) { store.syncSheet = nil }
            Spacer()
            switch i.plan {
            case .upload: BracketButton("upload & turn on", color: Theme.acc) { store.confirmEnableSync(.upload) }
            case .useCloud: BracketButton("use icloud", color: Theme.acc) { store.confirmEnableSync(.useCloud) }
            case .resume: BracketButton("turn on", color: Theme.acc) { store.confirmEnableSync(.merge) }
            case .choose:
                BracketButton("use icloud", color: Theme.t1) { store.confirmEnableSync(.useCloud) }
                BracketButton("merge", color: Theme.acc) { store.confirmEnableSync(.merge) }
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 10) {
            note("the same record changed on two devices before they synced. the kept version is live now; the other is here.", Theme.t3)
            // A plain stack (not a ScrollView): it always sizes to its rows inside the overlay.
            VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.syncState.conflicts.prefix(8)) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            TT(store.conflictTitle(c), 12, Theme.t1)
                            TT(c.reason, 11, Theme.t3)
                            HStack {
                                Spacer()
                                BracketButton(c.other.isTombstone ? "delete it after all" : "use other version", color: Theme.t2) {
                                    store.resolveConflict(c, useOther: true)
                                }
                                BracketButton("keep current", color: Theme.acc) { store.resolveConflict(c, useOther: false) }
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                    if store.syncState.conflicts.count > 8 {
                        TT("+\(store.syncState.conflicts.count - 8) more · resolve these first", 11, Theme.t4).padding(.top, 8)
                    }
            }
            buttons { Spacer(); BracketButton("close", color: Theme.t2) { store.syncSheet = nil } }
        }
    }

    /// Design §28: whole record, pick a side, newer is the default (⌘↵).
    @ViewBuilder private var intelConflict: some View {
        if let c = store.intelConflict {
            let other = store.otherDevice(c), otherNewer = store.intelConflictOtherIsNewer(c)
            VStack(alignment: .leading, spacing: 8) {
                note(c.reason, Theme.t3)
                Hairline().padding(.vertical, 4)
                note("this Mac   " + store.intelConflictLine(c, other: false) + (otherNewer ? "" : " · newer"), Theme.t1)
                note(other + "   " + store.intelConflictLine(c, other: true) + " · " + DateFmt.hm(c.other.modifiedAt) + (otherNewer ? " · newer" : ""), Theme.t1)
                note("until you choose, this Mac evaluates its own version. no fields are merged.", Theme.t4)
                if store.intelSyncState.conflicts.count > 1 { note("+\(store.intelSyncState.conflicts.count - 1) more after this one", Theme.t4) }
            }
            buttons {
                BracketButton("later esc", color: Theme.t2) { store.syncSheet = nil }
                Spacer()
                BracketButton("keep this Mac" + (otherNewer ? "" : " ⌘↵"), color: otherNewer ? Theme.t1 : Theme.acc) { store.resolveIntelConflict(c, keepOther: false) }
                BracketButton("keep \(other)" + (otherNewer ? " ⌘↵" : ""), color: otherNewer ? Theme.acc : Theme.t1) { store.resolveIntelConflict(c, keepOther: true) }
            }
        } else {
            note("no conflicts left", Theme.t3)
            buttons { Spacer(); BracketButton("close", color: Theme.t2) { store.syncSheet = nil } }
        }
    }

    private func note(_ s: String, _ c: Color) -> some View {
        Text(s).font(Theme.mono(12)).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.top, 14)
    }
}

/// Screen header, right slot, watchlist / alerts / scenarios only (design §28). Clicking opens
/// Settings › data + sync, or the conflict.
struct IntelSyncBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let i = store.intelSyncIndicator {
            TermButton(action: i.action) { TT(i.text, 11, i.color).fixedSize() }
                .help("watchlist · alerts · scenarios sync with iCloud · click for details")
                .accessibilityIdentifier("intel-sync-badge")
        }
    }
}
