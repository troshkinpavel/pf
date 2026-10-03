import PFCore
import PFCoreUI
import SwiftUI

/// DATA RECOVERY → restore: pick a local snapshot, see what changes, confirm.
struct RestoreSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let r = store.restore ?? RestoreState(), list = store.snapshotList
        VStack(spacing: 0) {
            header("RESTORE A RECOVERY SNAPSHOT", "click to choose · esc cancel")
            VStack(alignment: .leading, spacing: 12) {
                if list.isEmpty {
                    TT("no local snapshots yet · they are taken automatically after ledger changes", 12, Theme.t3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(list.prefix(12).enumerated()), id: \.element.id) { i, s in
                            TermButton(action: { store.restore?.sel = i; store.loadRestorePreview() }, hoverBg: Theme.selected) {
                                Columns([.fixed(22), .fixed(150), .fixed(170), .fr(1)]) {
                                    RowMark(on: i == r.sel)
                                    TT(DateFmt.ymd(s.createdAt) + " " + DateFmt.hm(s.createdAt), 12, i == r.sel ? Theme.t1 : Theme.t2)
                                    TT(DiagnosticReport.age(s.createdAt, now: Date()) + " · " + s.reason, 12, s.isSafety ? Theme.acc : Theme.t3)
                                    TT("\(s.portfolios) portfolio\(s.portfolios == 1 ? "" : "s") · \(s.transactions) tx", 12, Theme.t3)
                                }
                                .frame(height: 24)
                            }
                        }
                    }
                }
                if let e = r.error { TT("✗ this snapshot can't be restored · \(e)", 12, Theme.neg) }
                if let d = r.doc {
                    let diff = store.restoreDiff(d)
                    VStack(alignment: .leading, spacing: 5) {
                        TT("restores \(d.portfolios.count) portfolio\(d.portfolios.count == 1 ? "" : "s") · \(d.transactions.count) transactions", 12, Theme.t1)
                        TT("compared with now: +\(diff.added) added back · −\(diff.removed) removed · \(diff.changed) changed", 12, Theme.t2)
                        TT("a snapshot of the current ledger is saved first, so this can be undone the same way.", 11, Theme.t3)
                        if store.syncEnabled { TT("iCloud sync is on: the restored ledger syncs to your other devices.", 11, Theme.acc) }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.overlayBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
            .padding(16)
            HStack {
                BracketButton("cancel", color: Theme.t2) { store.restore = nil }
                Spacer()
                BracketButton("restore this snapshot", color: r.doc == nil ? Theme.faint : Theme.acc) { store.confirmRestore() }
                    .disabled(r.doc == nil)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .frame(width: 640)
    }
}

/// Import into one portfolio: what is ready, what looks duplicated, what needs a look.
struct ImportPreviewSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let p = store.importPreview {
            let plan = p.plan, f = Fmt.current
            VStack(spacing: 0) {
                header("IMPORT PREVIEW · \(store.doc.portfolio(p.portfolioID)?.name ?? "")", "nothing is added until you confirm · esc cancel")
                VStack(alignment: .leading, spacing: 12) {
                    Columns([.fr(1), .fr(1), .fr(1), .fr(1), .fr(1)]) {
                        count("TRANSACTIONS", plan.items.count, Theme.t1)
                        count("READY", plan.count(.ready), Theme.pos)
                        count("DUPLICATES", plan.count(.duplicate), Theme.t3)
                        count("NEED REVIEW", plan.count(.review), Theme.acc)
                        count("INVALID", plan.count(.invalid), Theme.neg)
                    }
                    let flagged = plan.items.filter { $0.status != .ready }
                    if !flagged.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(flagged.prefix(10)) { i in
                                HStack(spacing: 10) {
                                    TT(i.status.rawValue.uppercased(), 11, i.status == .invalid ? Theme.neg : i.status == .review ? Theme.acc : Theme.t3).frame(width: 78, alignment: .leading)
                                    TT("\(DateFmt.ymd(i.tx.timestamp)) \(i.tx.type.short) \(f.amount(i.tx.quantity)) \(symbol(i.tx.assetID, p)) @ \(f.price(i.tx.price))", 12, Theme.t2)
                                    Spacer()
                                    TT(i.reason, 11, Theme.t4)
                                }
                            }
                            if flagged.count > 10 { TT("+\(flagged.count - 10) more", 11, Theme.t4) }
                        }
                    }
                    TT("duplicates and invalid rows are never imported · rows that need review are imported only if you include them", 11, Theme.t3)
                }
                .padding(16)
                HStack {
                    BracketButton("cancel", color: Theme.t2) { store.importPreview = nil }
                    Spacer()
                    if plan.count(.review) > 0 {
                        BracketButton("import \(plan.count(.ready) + plan.count(.review)) incl. review", color: Theme.t1) { store.applyImportPreview(includeReview: true) }
                    }
                    BracketButton("import \(plan.count(.ready)) ready", color: plan.count(.ready) > 0 ? Theme.acc : Theme.faint) { store.applyImportPreview(includeReview: false) }
                        .disabled(plan.count(.ready) == 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
            .frame(width: 720)
        }
    }

    private func symbol(_ id: AssetID, _ p: ImportPreviewState) -> String {
        store.asset(id)?.symbol ?? p.assets.first { $0.id == id }?.symbol ?? id
    }

    private func count(_ k: String, _ n: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) { CapsLabel(k); TT("\(n)", 18, n == 0 ? Theme.t4 : c, weight: .medium) }
    }
}

private func header(_ title: String, _ hint: String) -> some View {
    HStack {
        TT(title, 12, Theme.t1, tracking: 0.72)
        Spacer()
        TT(hint, 11, Theme.t4)
    }
    .padding(.horizontal, 16).frame(height: 34)
    .overlay(alignment: .bottom) { Hairline() }
}
