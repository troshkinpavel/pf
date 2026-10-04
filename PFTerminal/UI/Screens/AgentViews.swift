import PFCore
import PFCoreUI
import SwiftUI

/// An agent asks to change something (docs/PLAN-0.8.md §6). The frozen operation, nothing editable:
/// deny or confirm. Never shown while locked (the lock screen says a request waits, without details).
struct AgentConfirmSheet: View {
    @Environment(AppStore.self) private var store
    let c: AgentConfirmation

    var body: some View {
        let left = max(0, Int(c.expiresAt.timeIntervalSince(store.now)))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TT("AGENT REQUEST", 12, Theme.t1, tracking: 0.72)
                TT(c.client.lowercased(), 11, Theme.t3)
                Spacer()
                TT(store.agent.pending.count > 1 ? "1 of \(store.agent.pending.count) · " : "", 11, Theme.t4)
                TT("expires in \(left)s", 11, left < 20 ? Theme.warning : Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TT(c.tier == .destructive ? "▲" : "›", 12, c.tier == .destructive ? Theme.neg : Theme.acc)
                    TT("wants to " + c.title.components(separatedBy: " · ").first!, 13, Theme.t1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(c.lines.enumerated()), id: \.offset) { i, l in
                        TT(l, 12, i == 0 ? Theme.t1 : Theme.t2).textSelection(.enabled)
                    }
                }
                .padding(.leading, 20)
                TT(c.tier == .destructive ? "removes or replaces data · " + (c.tool.hasSuffix("transaction") ? "a recovery snapshot is taken first" : "confirm only if you asked for this")
                   : "runs exactly as shown · nothing else", 11, Theme.t3)
                    .padding(.top, 4)
            }
            .padding(16)
            HStack(spacing: 10) {
                TT("esc deny · ⌘↵ confirm", 11, Theme.t4)
                Spacer()
                BracketButton("deny", color: Theme.t2) { store.agentResolve(c.id, confirm: false) }
                    .accessibilityIdentifier("agent-deny")
                BracketButton("confirm", color: c.tier == .destructive ? Theme.neg : Theme.acc) { store.agentResolve(c.id, confirm: true) }
                    .accessibilityIdentifier("agent-confirm")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 560)
    }
}

/// Settings → agents → activity: the local audit log, newest first.
struct AgentActivityView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = Array(store.agent.audit.entries.reversed().prefix(200))
        VStack(spacing: 0) {
            HStack {
                TT("AGENT ACTIVITY", 12, Theme.t1, tracking: 0.72)
                TT("\(store.agent.audit.entries.count) entries · local · no amounts or notes", 11, Theme.t3)
                Spacer()
                TT("esc close", 11, Theme.t4)
            }
            .padding(.horizontal, 16).frame(height: 34)
            .overlay(alignment: .bottom) { Hairline() }
            Columns([.fixed(132), .fixed(150), .fr(1), .fixed(84), .fixed(190)]) {
                HeadCell("TIME", align: .leading); HeadCell("CLIENT", align: .leading); HeadCell("TOOL", align: .leading); HeadCell("TIER", align: .leading); HeadCell("RESULT", align: .leading)
            }
            .padding(.horizontal, 16).frame(height: 24)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { e in
                        Columns([.fixed(132), .fixed(150), .fr(1), .fixed(84), .fixed(190)]) {
                            TT(String(DateFmt.ymd(e.at).dropFirst(5)) + " " + DateFmt.hms(e.at), 11, Theme.t3)
                            TT("#\(e.connection) " + e.client.lowercased(), 11, Theme.t2).lineLimit(1)
                            TT(e.tool + (e.portfolio.map { " · " + $0 } ?? ""), 11, Theme.t1).lineLimit(1)
                            TT(e.tier, 11, e.tier == "destructive" ? Theme.neg : Theme.t3)
                            TT(e.result + (e.error.map { " · " + $0 } ?? ""), 11, e.result == "error" || e.result == "denied" || e.result == "failed" ? Theme.neg : e.result == "ok" || e.result == "confirmed" ? Theme.t2 : Theme.acc).lineLimit(1)
                        }
                        .padding(.horizontal, 16).frame(height: 22)
                    }
                    if rows.isEmpty { TT("no agent activity yet", 11, Theme.t4).padding(16) }
                }
            }
            .frame(height: 380)
            HStack {
                TT(store.agent.settings.keepAudit ? "kept in agent-audit.json · newest 500" : "this session only", 11, Theme.t4)
                Spacer()
                BracketButton("clear", color: Theme.t2) { store.agent.audit.clear() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: 860)
    }
}
