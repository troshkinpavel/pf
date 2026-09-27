import Foundation
import Testing
@testable import PFTerminal

private struct StubChecker: UpdateChecking {
    var result: Result<[ReleaseInfo], Error>
    func releases() async throws -> [ReleaseInfo] { try result.get() }
}

private func rel(_ tag: String, pre: Bool = false, draft: Bool = false) -> ReleaseInfo {
    ReleaseInfo(tag: tag, name: "PF Terminal \(tag)", publishedAt: nil, isDraft: draft, isPrerelease: pre)
}

struct SemanticVersionTests {
    @Test func parses() {
        #expect(SemanticVersion("v0.4.0") == SemanticVersion(0, 4, 0))
        #expect(SemanticVersion("0.4") == SemanticVersion(0, 4, 0))
        #expect(SemanticVersion("1.2.3-beta.1")?.prerelease == ["beta", "1"])
        #expect(SemanticVersion("1.2.3+build.7") == SemanticVersion(1, 2, 3))
    }

    @Test func rejectsMalformed() {
        for s in ["", "abc", "1.2.3.4", "1..2", "-1.0.0", "1.2.x", "v", "1.2.3-", "٣.0.0"] {
            #expect(SemanticVersion(s) == nil, "\(s)")
        }
    }

    @Test func comparesNumericallyNotLexically() {
        #expect(SemanticVersion("0.10.0")! > SemanticVersion("0.9.0")!)
        #expect(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        #expect(SemanticVersion("1.0.0-rc.1")! < SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("1.0.0-beta.2")! < SemanticVersion("1.0.0-beta.11")!)
        #expect(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0-beta")!)
        #expect(SemanticVersion("v0.4.0")! == SemanticVersion("0.4.0")!)
    }
}

struct UpdateCheckTests {
    @Test func installedVersionComesFromBundleMetadata() {
        let v = InstalledVersion(info: ["CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "2"])
        #expect(v.display == "0.5.0 (2)" && v.semantic == SemanticVersion(0, 5, 0))
        #expect(InstalledVersion(info: nil).display == "0.0.0 (0)")
        #expect(InstalledVersion.current.marketing == Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    @Test func newerStableReleaseIsOffered() {
        let s = Updates.evaluate(installed: "0.4.0", releases: [rel("v0.5.0"), rel("v0.4.0")])
        guard case let .updateAvailable(u) = s else { Issue.record("\(s)"); return }
        #expect(u.version == SemanticVersion(0, 5, 0))
        #expect(u.releaseURL.absoluteString == "https://github.com/troshkinpavel/pf/releases/tag/v0.5.0")
    }

    @Test func sameOrOlderIsUpToDate() {
        guard case .upToDate = Updates.evaluate(installed: "0.4.0", releases: [rel("v0.4.0")]) else { Issue.record("same"); return }
        guard case .upToDate = Updates.evaluate(installed: "0.5.0", releases: [rel("v0.4.0")]) else { Issue.record("older"); return }
        guard case .upToDate = Updates.evaluate(installed: "0.4.0", releases: []) else { Issue.record("none"); return }
    }

    @Test func newerLocalBuildIsNeverOfferedADowngrade() {
        // A 0.4.1 release candidate while the latest public release is still 0.4.0.
        let rs = [rel("v0.4.0"), rel("v0.3.9"), rel("v0.4.1-rc.1", pre: true)]
        guard case .upToDate = Updates.evaluate(installed: "0.4.1", releases: rs) else { Issue.record("downgrade offered"); return }
        guard case .upToDate = Updates.evaluate(installed: "0.4.1", releases: rs + [rel("v0.4.1")]) else { Issue.record("same version after publishing"); return }
    }

    @Test func prereleasesAndDraftsAreNotStableUpdates() {
        let rs = [rel("v0.6.0-beta.1"), rel("v0.7.0", pre: true), rel("v0.8.0", draft: true), rel("v0.4.0")]
        guard case .upToDate = Updates.evaluate(installed: "0.4.0", releases: rs) else { Issue.record("prerelease offered"); return }
        guard case .updateAvailable = Updates.evaluate(installed: "0.4.0", releases: rs, includePrereleases: true) else { Issue.record("opt-in channel"); return }
    }

    @Test func malformedOrUnsafeTagsAreIgnored() {
        let rs = [rel("latest"), rel("v9.9.9/../../evil"), rel("v1.0.0?x=https://evil.example"), rel("v0.4.1")]
        guard case let .updateAvailable(u) = Updates.evaluate(installed: "0.4.0", releases: rs) else { Issue.record("expected 0.4.1"); return }
        #expect(u.tag == "v0.4.1")
        #expect(Updates.releaseURL(tag: "v1.0.0/../x") == nil)
    }

    @Test func unparseableInstalledVersionFailsSafely() {
        guard case .failed = Updates.evaluate(installed: "dev", releases: [rel("v0.5.0")]) else { Issue.record("expected failed"); return }
    }

    @Test func networkFailureIsReportedNotThrown() async {
        let offline = await Updates.check(installed: "0.4.0", using: StubChecker(result: .failure(UpdateError.offline)))
        #expect(offline == .failed(UpdateError.offline.description))
        let other = await Updates.check(installed: "0.4.0", using: StubChecker(result: .failure(URLError(.badServerResponse))))
        guard case .failed = other else { Issue.record("\(other)"); return }
        let ok = await Updates.check(installed: "0.4.0", using: StubChecker(result: .success([rel("v0.4.0")])))
        guard case .upToDate = ok else { Issue.record("\(ok)"); return }
    }

    @Test func parsesGitHubReleasesJSON() throws {
        let json = """
        [{"tag_name":"v0.5.0","name":"PF Terminal v0.5.0","draft":false,"prerelease":false,"published_at":"2026-10-01T10:00:00Z","html_url":"https://example.com/ignored"},
         {"tag_name":"v0.6.0-rc.1","name":null,"draft":false,"prerelease":true,"published_at":null}]
        """
        let rs = try GitHubReleaseChecker.parse(Data(json.utf8))
        #expect(rs.count == 2 && rs[0].tag == "v0.5.0" && rs[0].publishedAt != nil && rs[1].isPrerelease)
        #expect(throws: UpdateError.malformed) { try GitHubReleaseChecker.parse(Data("{\"message\":\"Not Found\"}".utf8)) }
    }
}

struct DockPreferenceTests {
    @Test func keepInDockPersistsAndDefaultsOff() {
        let d = UserDefaults(suiteName: "pf-dock-\(UUID().uuidString)")!
        #expect(AppSettings.load(d).keepInDock == false)
        var s = AppSettings.load(d)
        s.keepInDock = true
        s.save(d)
        #expect(AppSettings.load(d).keepInDock == true)
        // Settings saved by older versions (no key) keep the default.
        d.set(Data(#"{"currency":"EUR"}"#.utf8), forKey: "pf.settings.v1")
        #expect(AppSettings.load(d).keepInDock == false && AppSettings.load(d).currency == "EUR")
    }
}
