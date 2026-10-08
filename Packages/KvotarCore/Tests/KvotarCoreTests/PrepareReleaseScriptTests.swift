import XCTest

/// `scripts/prepare_release.sh` writes and pushes the release bump (docs/releasing.md, step 1).
/// Each test runs the script in a temporary git repository holding copies of the four files it
/// edits, with the `0.3.0 beta.11 (20)` values, whose `origin` is a second temporary bare
/// repository: nothing here reaches GitHub, and the `make check` the script runs is a stub
/// Makefile in that repository. The script is copied in, because it finds its repository from its
/// own location.
///
/// Ungated: it needs git and python3, which every Mac that builds Kvotar has.
final class PrepareReleaseScriptTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var origin: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-release-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs/spec"),
                                                withIntermediateDirectories: true)
        try write("project.yml", Fixture.project)
        try write("CHANGELOG.md", Fixture.changelog)
        try write("docs/spec/updates-and-releases.md", Fixture.spec)
        try write("Makefile", "check:\n\t@echo stub check\n")
        let script = Self.repoRoot.appendingPathComponent("scripts/prepare_release.sh")
        try FileManager.default.copyItem(at: script, to: repo.appendingPathComponent("scripts/prepare_release.sh"))

        _ = try git(["init", "-q", "--bare", "--initial-branch=main", origin.path], in: root)
        _ = try git(["init", "-q", "--initial-branch=main"], in: repo)
        _ = try git(["add", "-A"], in: repo)
        _ = try git(["commit", "-q", "-m", "Start"], in: repo)
        _ = try git(["remote", "add", "origin", origin.path], in: repo)
        _ = try git(["push", "-q", "-u", "origin", "main"], in: repo)
    }

    override func tearDownWithError() throws {
        if root != nil { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - The bump

    func testBumpsTheSevenLinesAndOpensTheChangelogSection() throws {
        // An untracked file is not a dirty tree.
        try write("docs/research-note.md", "scratch\n")

        let run = try prepareRelease()

        XCTAssertEqual(run.status, 0, run.stderr)
        let head = try git(["rev-parse", "HEAD"], in: repo)
        XCTAssertTrue(run.stdout.contains("Bumped to 0.3.0 beta.12 (21): \(head)"), run.stdout)
        XCTAssertTrue(run.stdout.contains("build this commit with the private tooling"), run.stdout)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: repo), "Bump to 0.3.0 beta.12 (21)")
        XCTAssertEqual(try git(["rev-parse", "main"], in: origin), head, "the bump was not pushed")

        let changed = try git(["diff", "HEAD~1", "HEAD", "--unified=0", "--format="], in: repo)
            .split(separator: "\n")
            .filter { ($0.hasPrefix("-") || $0.hasPrefix("+")) && !$0.hasPrefix("---") && !$0.hasPrefix("+++") }
            .map(String.init)
        XCTAssertEqual(changed, [
            "+## [0.3.0 beta.12 (21)](https://github.com/vladamarkov/kvotar/releases/tag/v0.3.0-beta.12) — \(Self.today)",
            "+",
            "-| `CURRENT_PROJECT_VERSION` | `20` | The build number |",
            "-| `KVOTAR_PRERELEASE_LABEL` | `beta.11` | The beta label, for release file names only; it never reaches `Info.plist` |",
            "+| `CURRENT_PROJECT_VERSION` | `21` | The build number |",
            "+| `KVOTAR_PRERELEASE_LABEL` | `beta.12` | The beta label, for release file names only; it never reaches `Info.plist` |",
            "-- **It is not the beta label.** The `beta.11` in a release's name is `KVOTAR_PRERELEASE_LABEL`,",
            "+- **It is not the beta label.** The `beta.12` in a release's name is `KVOTAR_PRERELEASE_LABEL`,",
            "-  public beta build so far is `0.3.0`, from `0.3.0 beta.2 (11)` to `0.3.0 beta.11 (20)`.",
            "+  public beta build so far is `0.3.0`, from `0.3.0 beta.2 (11)` to `0.3.0 beta.12 (21)`.",
            "-        CURRENT_PROJECT_VERSION: \"20\"",
            "+        CURRENT_PROJECT_VERSION: \"21\"",
            "-        KVOTAR_PRERELEASE_LABEL: \"beta.11\"",
            "+        KVOTAR_PRERELEASE_LABEL: \"beta.12\"",
        ])
        XCTAssertEqual(try read("CHANGELOG.md"), Fixture.changelogAfterBump(on: Self.today),
                       "Unreleased stays, empty, above the new section")
        XCTAssertTrue(try read("project.yml").contains("MARKETING_VERSION: \"0.3.0\""), "the version is not touched")
    }

    // MARK: - Refusals: one line on stderr, no commit, no change

    func testRefusesOffMain() throws {
        _ = try git(["checkout", "-q", "-b", "feature"], in: repo)
        try assertRefusal(reason: "not on main")
    }

    func testRefusesADirtyTree() throws {
        try write("project.yml", Fixture.project + "# edited\n")
        let run = try prepareRelease()
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                       "prepare_release: the tree is not clean")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: repo), "Start")
        XCTAssertEqual(try read("project.yml"), Fixture.project + "# edited\n", "the edit was left alone")
    }

    func testRefusesAnEmptyUnreleased() throws {
        try write("CHANGELOG.md", Fixture.changelogWithEmptyUnreleased)
        _ = try git(["commit", "-q", "-am", "Release everything"], in: repo)
        _ = try git(["push", "-q", "origin", "main"], in: repo)
        try assertRefusal(reason: "Unreleased has no lines in CHANGELOG.md")
    }

    func testRefusesWhenMainIsBehindOrigin() throws {
        let first = try prepareRelease()
        XCTAssertEqual(first.status, 0, first.stderr)
        _ = try git(["reset", "-q", "--hard", "HEAD~1"], in: repo)
        try assertRefusal(reason: "main is behind origin/main")
    }

    func testRevertsTheFilesWhenTheCheckFails() throws {
        try write("Makefile", "check:\n\t@echo the check says no; exit 1\n")
        _ = try git(["commit", "-q", "-am", "Break the check"], in: repo)
        _ = try git(["push", "-q", "origin", "main"], in: repo)
        try assertRefusal(reason: "make check failed; the bump was not written")
    }

    /// Runs the script and asserts it exited 1 with the one-line reason as its last word, committed
    /// nothing, pushed nothing and left the tree clean and unchanged.
    private func assertRefusal(reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let head = try git(["rev-parse", "HEAD"], in: repo)
        let originHead = try git(["rev-parse", "main"], in: origin)
        let before = try (read("project.yml"), read("CHANGELOG.md"), read("docs/spec/updates-and-releases.md"))

        let run = try prepareRelease()

        XCTAssertEqual(run.status, 1, run.stdout, file: file, line: line)
        XCTAssertEqual(run.stderr.split(separator: "\n").last.map(String.init), "prepare_release: \(reason)",
                       run.stderr, file: file, line: line)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: repo), head, "a commit was made", file: file, line: line)
        XCTAssertEqual(try git(["rev-parse", "main"], in: origin), originHead, "a push was made", file: file, line: line)
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=no"], in: repo), "",
                       "the tree is no longer clean", file: file, line: line)
        let after = try (read("project.yml"), read("CHANGELOG.md"), read("docs/spec/updates-and-releases.md"))
        XCTAssertEqual(before.0, after.0, file: file, line: line)
        XCTAssertEqual(before.1, after.1, file: file, line: line)
        XCTAssertEqual(before.2, after.2, file: file, line: line)
    }

    // MARK: - Running things

    private struct Run { let status: Int32; let stdout: String; let stderr: String }

    private func prepareRelease() throws -> Run {
        try run("/bin/bash", [repo.appendingPathComponent("scripts/prepare_release.sh").path], in: repo)
    }

    /// Fails the test on a non-zero exit; returns trimmed standard output.
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = try run("/usr/bin/git", arguments, in: directory)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(result.stderr)"])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A hermetic environment: no user or system git configuration (so no signing hook or template
    /// of this Mac's reaches the fake repository), a fixed author, and the stock tool paths.
    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Kvotar test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Kvotar test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: stdout, as: UTF8.self),
                   stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// …/KvotarCoreTests/Tests/KvotarCore/Packages/<repo root>, as `ShippedPricingTableTests` walks it.
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// The script writes `date +%Y-%m-%d`: the local calendar day.
    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - The four files, as they stand at 0.3.0 beta.11 (20)

    private enum Fixture {
        static let project = """
            name: Kvotar
            targets:
              Kvotar:
                settings:
                  base:
                    MARKETING_VERSION: "0.3.0"
                    CURRENT_PROJECT_VERSION: "20"
                    # The release scripts read version, build and label from here — one place to bump.
                    KVOTAR_PRERELEASE_LABEL: "beta.11"
                    KVOTAR_CHANNEL: release

            """

        static let spec = """
            # Updates and releases

            In `project.yml` (target `Kvotar`, `settings.base`):

            | Setting | Today | What it is |
            |---|---|---|
            | `MARKETING_VERSION` | `0.3.0` | The version |
            | `CURRENT_PROJECT_VERSION` | `20` | The build number |
            | `KVOTAR_PRERELEASE_LABEL` | `beta.11` | The beta label, for release file names only; it never reaches `Info.plist` |
            | `KVOTAR_CHANNEL` | `release` | The build channel |

            ## The build channel

            - **It is not the beta label.** The `beta.11` in a release's name is `KVOTAR_PRERELEASE_LABEL`,
              which only names release files.

            ## Version and build numbers

            - **The version** (`MARKETING_VERSION`) changes with who the build is for, not with features. Every
              public beta build so far is `0.3.0`, from `0.3.0 beta.2 (11)` to `0.3.0 beta.11 (20)`.

            """

        static let changelogHead = """
            # Changelog

            User-facing changes per release. Build numbers are in brackets.

            ## Unreleased

            """

        static let unreleasedLines = """
            - Kvotar can be installed with Homebrew.
            - A session is listed under the folder it started in.

            """

        static let changelogTail = """
            ## [0.3.0 beta.11 (20)](https://github.com/vladamarkov/kvotar/releases/tag/v0.3.0-beta.11) — 2026-10-08

            - Source published under the Apache License 2.0.

            """

        static let changelog = changelogHead + unreleasedLines + changelogTail
        static let changelogWithEmptyUnreleased = changelogHead + changelogTail

        static func changelogAfterBump(on date: String) -> String {
            changelogHead
                + "## [0.3.0 beta.12 (21)](https://github.com/vladamarkov/kvotar/releases/tag/v0.3.0-beta.12) — \(date)\n\n"
                + unreleasedLines + changelogTail
        }
    }
}
