import Foundation

// Update checking (Foundation only, reusable by a future iOS target).
//
// Today: a manual "Check for Updates…" that compares the installed version with the newest
// stable GitHub Release of the canonical repository and, if newer, links to that release page.
// Nothing is downloaded, mounted or installed by the app. A future signed updater (e.g. Sparkle,
// see docs/DEVELOPMENT.md) replaces `UpdateChecking` without touching the Settings UI, which
// only renders `UpdateState`.

/// Semantic version (`MAJOR.MINOR.PATCH[-prerelease]`, optional leading `v`, missing parts = 0).
struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    var major: Int, minor: Int, patch: Int
    var prerelease: [String] = []

    var isPrerelease: Bool { !prerelease.isEmpty }
    var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        s = String(s.split(separator: "+", maxSplits: 1).first ?? "")          // build metadata is ignored
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false)
        let ints = nums.compactMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil }
        guard (1...3).contains(nums.count), ints.count == nums.count else { return nil }
        major = ints[0]; minor = ints.count > 1 ? ints[1] : 0; patch = ints.count > 2 ? ints[2] : 0
        if parts.count == 2 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
    }

    /// SemVer precedence: numeric parts first; a prerelease sorts before its release;
    /// prerelease identifiers compare numerically when both are numbers.
    static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The running app's version, from bundle metadata (never hard-coded).
struct InstalledVersion: Equatable, Sendable {
    var marketing: String      // CFBundleShortVersionString
    var build: String          // CFBundleVersion

    init(marketing: String, build: String) { self.marketing = marketing; self.build = build }
    init(info: [String: Any]?) {
        marketing = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = info?["CFBundleVersion"] as? String ?? "0"
    }
    static var current: InstalledVersion { InstalledVersion(info: Bundle.main.infoDictionary) }

    var display: String { "\(marketing) (\(build))" }
    var semantic: SemanticVersion? { SemanticVersion(marketing) }
}

/// One published release, as reported by the release source.
struct ReleaseInfo: Equatable, Sendable {
    var tag: String
    var name: String?
    var publishedAt: Date?
    var isDraft = false
    var isPrerelease = false
}

struct AvailableUpdate: Equatable, Sendable {
    var version: SemanticVersion
    var tag: String
    var name: String?
    var publishedAt: Date?
    /// Always the canonical release page, built from the validated tag — never a URL from release metadata.
    var releaseURL: URL
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case updateAvailable(AvailableUpdate)
    case failed(String)
}

protocol UpdateChecking: Sendable {
    /// Recent releases, newest first. Throws on network/HTTP/decoding failure.
    func releases() async throws -> [ReleaseInfo]
}

enum UpdateError: Error, Equatable, CustomStringConvertible {
    case offline, http(Int), rateLimited, malformed, unknownInstalledVersion

    var description: String {
        switch self {
        case .offline: "no connection · try again when online"
        case let .http(c): "GitHub returned HTTP \(c)"
        case .rateLimited: "GitHub rate limit reached · try again later"
        case .malformed: "unexpected response from GitHub"
        case .unknownInstalledVersion: "installed version is not a release version"
        }
    }
}

enum Updates {
    static let owner = "troshkinpavel"
    static let repo = "pf"
    static var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases")! }

    /// Canonical page for a tag. Only plain version tags are accepted, so nothing from the
    /// response can steer the user to another host or path.
    static func releaseURL(tag: String) -> URL? {
        guard tag.range(of: #"^v?\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)")
    }

    /// Pure decision: newest stable, well-formed release vs the installed version.
    static func evaluate(installed: String, releases: [ReleaseInfo], includePrereleases: Bool = false, now: Date = Date()) -> UpdateState {
        guard let mine = SemanticVersion(installed) else { return .failed(UpdateError.unknownInstalledVersion.description) }
        let candidates: [(SemanticVersion, ReleaseInfo)] = releases.compactMap { r in
            guard !r.isDraft, includePrereleases || !r.isPrerelease,
                  let v = SemanticVersion(r.tag), includePrereleases || !v.isPrerelease,
                  releaseURL(tag: r.tag) != nil else { return nil }
            return (v, r)
        }
        guard let (latest, info) = candidates.max(by: { $0.0 < $1.0 }), latest > mine, let url = releaseURL(tag: info.tag) else {
            return .upToDate(checkedAt: now)
        }
        return .updateAvailable(AvailableUpdate(version: latest, tag: info.tag, name: info.name, publishedAt: info.publishedAt, releaseURL: url))
    }

    /// One manual check. Never throws: failures become `.failed` and the app carries on.
    static func check(installed: String, using checker: UpdateChecking, now: Date = Date()) async -> UpdateState {
        do { return evaluate(installed: installed, releases: try await checker.releases(), now: now) }
        catch let e as UpdateError { return .failed(e.description) }
        catch { return .failed("could not check for updates") }
    }
}

/// GitHub Releases of the canonical repository. Anonymous (no account, no token), ephemeral
/// session (no cookies/cache), and the request carries nothing about the user or portfolio.
struct GitHubReleaseChecker: UpdateChecking {
    var session: URLSession = URLSession(configuration: .ephemeral)

    func releases() async throws -> [ReleaseInfo] {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updates.owner)/\(Updates.repo)/releases?per_page=20")!,
                             timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PF-Terminal", forHTTPHeaderField: "User-Agent")   // required by GitHub; no version or identifiers
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(e.code) {
            throw UpdateError.offline
        }
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.malformed }
        if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [ReleaseInfo] {
        struct R: Decodable {
            let tag_name: String; let name: String?; let draft: Bool; let prerelease: Bool; let published_at: Date?
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let rs = try? d.decode([R].self, from: data) else { throw UpdateError.malformed }
        return rs.map { ReleaseInfo(tag: $0.tag_name, name: $0.name, publishedAt: $0.published_at, isDraft: $0.draft, isPrerelease: $0.prerelease) }
    }
}
