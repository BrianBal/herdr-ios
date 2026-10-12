import Foundation
import Testing
@testable import HerdrKit

@Suite struct ANSIParserTests {
    @Test func plainLinesAndCRLF() {
        let lines = ANSIParser.parse("hello\r\nworld   \r\n\r\n")
        #expect(lines.map(\.plainText) == ["hello", "world"])
    }

    @Test func basicAndBrightColors() {
        let lines = ANSIParser.parse("\u{1B}[31mred\u{1B}[0m \u{1B}[1;94mblue\u{1B}[39m")
        let runs = lines[0].runs
        #expect(runs[0] == StyledRun(text: "red", style: { var s = TermStyle(); s.fg = .indexed(1); return s }()))
        #expect(runs[1].text == " ")
        #expect(runs[2].style.fg == .indexed(12))
        #expect(runs[2].style.bold)
    }

    @Test func truecolorAnd256() {
        let lines = ANSIParser.parse("\u{1B}[38;2;10;20;30;48;5;214mx")
        #expect(lines[0].runs[0].style.fg == .rgb(10, 20, 30))
        #expect(lines[0].runs[0].style.bg == .indexed(214))
    }

    @Test func colonTruecolorAndUnderlineColorIgnored() {
        let lines = ANSIParser.parse("\u{1B}[38:2::1:2:3mA\u{1B}[58;5;205;4mB")
        #expect(lines[0].runs[0].style.fg == .rgb(1, 2, 3))
        #expect(lines[0].runs[1].style.underline)
        #expect(lines[0].runs[1].style.fg == .rgb(1, 2, 3))
    }

    @Test func dimResetBy22() {
        let lines = ANSIParser.parse("\u{1B}[2mdim\u{1B}[22mnormal")
        #expect(lines[0].runs[0].style.dim)
        #expect(!lines[0].runs[1].style.dim)
    }

    @Test func keepsTrailingSpacesWithBackground() {
        let lines = ANSIParser.parse("\u{1B}[48;2;74;77;84m› prompt   \u{1B}[0m   ")
        #expect(lines[0].plainText == "› prompt   ")
    }

    @Test func mergesAdjacentRunsWithSameStyle() {
        let lines = ANSIParser.parse("a\u{1B}[0mb\u{1B}[mc")
        #expect(lines[0].runs.count == 1)
        #expect(lines[0].runs[0].text == "abc")
    }

    @Test func clipsOnlyRuleLinesWhenFitting() {
        let rule = String(repeating: "─", count: 180)
        let lines = ANSIParser.parse("\u{1B}[2m\(rule)\u{1B}[0m\r\nkeep \(rule)\r\n── ──")
        let fitted = lines.fittingRules(to: 40)
        #expect(fitted[0].plainText.count == 40)
        #expect(fitted[0].runs[0].style.dim)
        #expect(fitted[1].plainText.count == 185)  // has text: untouched
        #expect(fitted[2].plainText == "── ──")       // already fits
        #expect(lines.fittingRules(to: nil) == lines)
    }

    @Test func palette() {
        let p = TerminalPalette.gruvboxDark
        #expect(p.resolve(.default) == nil)
        #expect(p.resolve(.indexed(1)) == RGB(hex: 0xCC241D))
        #expect(p.resolve(.indexed(16)) == RGB(0, 0, 0))
        #expect(p.resolve(.indexed(231)) == RGB(255, 255, 255))
        #expect(p.resolve(.indexed(232)) == RGB(8, 8, 8))
    }
}

@Suite struct PairingTests {
    @Test func parsesPairingLink() throws {
        let link = "herdr-ios://pair?url=wss%3A%2F%2Ftaco.ts.net%3A8443%2Fws&token=abc_DEF-123"
        let e = try GatewayEndpoint(pairingLink: link)
        #expect(e.url.absoluteString == "wss://taco.ts.net:8443/ws")
        #expect(e.token == "abc_DEF-123")
        #expect(e.displayHost == "taco.ts.net:8443")
    }

    @Test func rejectsBadLinks() {
        #expect(throws: GatewayEndpoint.ParseError.notAPairingLink) { try GatewayEndpoint(pairingLink: "https://x") }
        #expect(throws: GatewayEndpoint.ParseError.missingToken) {
            try GatewayEndpoint(pairingLink: "herdr-ios://pair?url=wss%3A%2F%2Fh%2Fws")
        }
        #expect(throws: GatewayEndpoint.ParseError.invalidURL("https://h/ws")) {
            try GatewayEndpoint(urlString: "https://h/ws", token: "t")
        }
    }
}

@Suite struct ModelTests {
    static let snapshotJSON = """
    {"snapshot":{"version":"0.9.3","protocol":22,"focused_workspace_id":"w2","focused_tab_id":"w2:t1","focused_pane_id":"w2:p2",
     "workspaces":[{"workspace_id":"w2","number":2,"label":"api","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"blocked"},
                   {"workspace_id":"w1","number":1,"label":"web","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"idle","tokens":{"x":"y"}}],
     "tabs":[{"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"1","focused":true,"pane_count":2,"agent_status":"blocked"}],
     "panes":[{"pane_id":"w2:p2","terminal_id":"t2","workspace_id":"w2","tab_id":"w2:t1","focused":true,"agent_status":"unknown","revision":1,"cwd":"/x/api"},
              {"pane_id":"w2:p1","terminal_id":"t1","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"blocked","revision":5,
               "agent":"claude","terminal_title_stripped":"Fix login bug","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":10,"viewport_rows":40}}],
     "layouts":[{"workspace_id":"w2","tab_id":"w2:t1","zoomed":false,"area":{"x":0,"y":0,"width":200,"height":50},"focused_pane_id":"w2:p2",
                 "panes":[{"pane_id":"w2:p2","focused":true,"rect":{"x":100,"y":0,"width":100,"height":50}},
                          {"pane_id":"w2:p1","focused":false,"rect":{"x":0,"y":0,"width":100,"height":50}}],"splits":[]}],
     "agents":[{"pane_id":"w2:p1","terminal_id":"t1","workspace_id":"w2","tab_id":"w2:t1","agent_status":"blocked","focused":false,"revision":5,"agent":"claude","future_field":1}]}}
    """

    @Test func decodesSnapshot() throws {
        let r = try GatewayClient.modelDecoder.decode(SessionSnapshotResult.self, from: Data(Self.snapshotJSON.utf8))
        let s = r.snapshot
        #expect(s.protocol == 22)
        #expect(s.sortedWorkspaces.map(\.label) == ["web", "api"])
        #expect(s.panes(in: "w2:t1").map(\.paneId) == ["w2:p1", "w2:p2"])  // left pane first
        #expect(s.pane("w2:p1")?.displayTitle == "Fix login bug")
        #expect(s.pane("w2:p2")?.displayTitle == "api")
        #expect(s.agents.first?.agentStatus == .blocked)
    }

    @Test func unknownStatusFallsBack() throws {
        let s = try JSONDecoder().decode([AgentStatus].self, from: Data(#"["working","sleeping"]"#.utf8))
        #expect(s == [.working, .unknown])
    }

    @Test func eventAccessorsUseRawKeys() throws {
        let e = try GatewayClient.plainDecoder.decode(
            HerdrEvent.self,
            from: Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"done"}}"#.utf8))
        #expect(e.paneId == "w1:p1")
        #expect(e.agentStatus == .done)
    }
}

/// Runs against a live gateway when HERDR_GATEWAY_URL and HERDR_GATEWAY_TOKEN are set.
@Suite struct LiveGatewayTests {
    static var endpoint: GatewayEndpoint? {
        let env = ProcessInfo.processInfo.environment
        guard let u = env["HERDR_GATEWAY_URL"], let t = env["HERDR_GATEWAY_TOKEN"] else { return nil }
        return try? GatewayEndpoint(urlString: u, token: t)
    }

    /// Creates, renames and closes a scratch workspace; opt in with HERDR_LIVE_MUTATE=1.
    @Test(.enabled(if: endpoint != nil && ProcessInfo.processInfo.environment["HERDR_LIVE_MUTATE"] == "1"))
    func workspaceLifecycle() async throws {
        let e = try #require(Self.endpoint)
        let client = GatewayClient(url: e.url, token: e.token)
        _ = try await client.connect()
        let (id, _) = try await client.createWorkspace(label: "ios-test", cwd: "/tmp")
        var ws = try #require(try await client.snapshot().workspace(id))
        #expect(ws.label == "ios-test")
        #expect(!ws.focused)
        try await client.send("workspace.rename", params: ["workspace_id": .string(id), "label": "ios-test-renamed"])
        ws = try #require(try await client.snapshot().workspace(id))
        #expect(ws.label == "ios-test-renamed")
        try await client.send("workspace.close", params: ["workspace_id": .string(id), "close_group": false])
        #expect(try await client.snapshot().workspace(id) == nil)
    }

    @Test(.enabled(if: endpoint != nil)) func snapshotSubscribeAndWatch() async throws {
        let e = try #require(Self.endpoint)
        let client = GatewayClient(url: e.url, token: e.token)
        let info = try await client.connect()
        #expect(info.herdr?.protocol ?? 0 > 0)
        let snap = try await client.snapshot()
        #expect(!snap.workspaces.isEmpty)

        let pane = try #require(snap.panes.first)
        let frames = try await client.watchPane(pane.paneId)
        var it = frames.makeAsyncIterator()
        let first = try await it.next()
        #expect(first?.paneId == pane.paneId)

        let (_, events) = try await client.subscribe([["type": "pane.focused"]])
        _ = events  // subscription accepted
        await client.disconnect()
        #expect(await client.waitUntilClosed() == "client closed")
    }

    @Test(.enabled(if: endpoint != nil)) func badTokenIsUnauthorized() async throws {
        let e = try #require(Self.endpoint)
        let client = GatewayClient(url: e.url, token: "wrong-token-value")
        await #expect(throws: GatewayError.unauthorized(status: 401)) { _ = try await client.connect() }
    }
}

@Suite struct SegmenterTests {
    static let esc = "\u{1B}"
    static func lav(_ s: String) -> String { "\(esc)[38;2;177;185;249m\(s)\(esc)[0m" }

    // Claude Code at 60 columns: a wrapped message with a list and a colored
    // command, a tool call, the spinner, and the input box fenced by rules.
    static let claude = [
        "\(esc)[38;2;255;255;255m⏺\(esc)[0m jim9 is trained and draws real dashboards. On your",
        "  example its page has every number bound.",
        "  See it:",
        "  - https://example.ts.net/page.html",
        "  " + lav("! cd /labs/tw1 && python3 scripts/examples.py"),
        "  " + lav("--max 800"),
        "  Next steps, in order:",
        "  1. Real examples into training and test.",
        "",
        "⏺ Bash(ls -la)",
        "  ⎿  total 8",
        "",
        "✻ Canoodling… (12m 3s)",
        String(repeating: "─", count: 60),
        "❯ a draft prompt that should not be a message",
        String(repeating: "─", count: 60),
    ].joined(separator: "\r\n")

    @Test func claudeMessagesCodeAndChrome() {
        let segs = TerminalSegmenter.segment(ANSIParser.parse(Self.claude), columns: 60)
        let kinds = segs.map(\.kind)
        #expect(kinds == [.message, .code, .message, .plain])

        // Whole message on its last prose part: marker stripped, prose re-joined, code kept.
        #expect(segs[0].copyText == nil)
        #expect(segs[2].copyText == """
            jim9 is trained and draws real dashboards. On your example its page has every number bound.
            See it:
            - https://example.ts.net/page.html
            ! cd /labs/tw1 && python3 scripts/examples.py
            --max 800
            Next steps, in order:
            1. Real examples into training and test.
            """)
        #expect(segs[1].copyText == "! cd /labs/tw1 && python3 scripts/examples.py\n--max 800")
        // Tool call, spinner, and input box stay plain with no button.
        #expect(segs[3].copyText == nil)
        #expect(segs[3].lines.map(\.plainText).contains("❯ a draft prompt that should not be a message"))
    }

    // Codex: bullets, a tool call with └ output, a syntax-colored CSS block,
    // inline code inside prose (partially colored: not a code line).
    static let codex = [
        "\(esc)[1m\(esc)[2m\(esc)[48;2;74;77;84m› rules that we need to follow\(esc)[0m",
        "",
        "• Ran cat apps/AGENTS.md",
        "  └ - Four pre-existing warnings remain.",
        "• Added these to AGENTS.md. Use \(esc)[38;2;166;227;161mtrux/atoms\(esc)[0m imports.",
        "  For CSS, the intended pattern is:",
        "  \(esc)[38;2;249;226;175m.FancyButton\(esc)[38;2;205;214;244m { }\(esc)[0m",
        "  \(esc)[38;2;249;226;175m.FancyButton:hover\(esc)[38;2;205;214;244m { }\(esc)[0m",
        "  Every selector must be scoped.",
        "  Worked for 1m 11s • 7:57 AM",
    ].joined(separator: "\r\n")

    @Test func codexBulletsToolCallsAndCode() {
        let segs = TerminalSegmenter.segment(ANSIParser.parse(Self.codex), columns: 60)
        #expect(segs.map(\.kind) == [.plain, .message, .code, .message, .plain])
        #expect(segs[0].copyText == nil)  // user prompt + tool call
        #expect(segs[1].copyText == nil)
        #expect(segs[2].copyText == ".FancyButton { }\n.FancyButton:hover { }")
        #expect(segs[3].copyText?.hasPrefix("Added these to AGENTS.md. Use trux/atoms imports.\nFor CSS") == true)
        #expect(segs[3].copyText?.contains("Worked for") == false)
        #expect(segs[4].lines[0].plainText.contains("Worked for"))  // Codex footer
    }

    @Test func messageThatIsOnlyCodeOffersCodeCopy() {
        let text = "⏺ ok\r\n  " + Self.lav("make build")
        let segs = TerminalSegmenter.segment(ANSIParser.parse(text))
        #expect(segs.map(\.kind) == [.message, .code])
        #expect(segs[0].copyText == "ok\nmake build")
        #expect(segs[1].copyText == "make build")
    }

    @Test func shellOutputIsAllPlain() {
        let segs = TerminalSegmenter.segment(ANSIParser.parse("TraceBot (main) $ ls\r\nREADME.md\r\n"))
        #expect(segs.map(\.kind) == [.plain])
        #expect(segs[0].copyText == nil)
    }

    @Test func wrappedInlineCodeNoticesAndHeadingsAreNotCode() {
        let text = [
            "⏺ It runs from a command: python",
            "  " + Self.lav("tw1.dashboard_jim data.json -o page.html"),
            "  Then wait for the following command:",
            "  " + Self.lav("make deploy"),
            "  \(Self.esc)[1;38;2;200;200;200mMeasure     What it tells us\(Self.esc)[0m",
            String(repeating: " ", count: 30) + "\(Self.esc)[32m✔ Update installed\(Self.esc)[0m",
        ].joined(separator: "\r\n")
        let segs = TerminalSegmenter.segment(ANSIParser.parse(text), columns: 40)
        #expect(segs.map(\.kind) == [.message, .code, .message, .plain])
        #expect(segs[0].lines.count == 3)                // wrapped inline code stays prose
        #expect(segs[1].copyText == "make deploy")      // after a colon it's a real block
        #expect(segs[0].copyText == nil)
        #expect(segs[2].copyText?.hasPrefix("It runs from a command") == true)
        #expect(segs[2].lines[0].plainText.contains("Measure"))  // bold header isn't code
        #expect(segs[3].lines[0].plainText.contains("Update installed"))
    }

    @Test func messageTailWhoseMarkerScrolledOff() {
        let text = [
            "  the end of a long paragraph that started",
            "  above the screen.",
            "  \(Self.esc)[38;2;99;104;117m──────────    ──────\(Self.esc)[0m",  // indented, colored table border: inside, not code
            "  Count time spent fixing errors.",
            "",
            "  Worked for 18s • 12:51 PM",
            "› Ask Codex to do anything",
        ].joined(separator: "\r\n")
        let lines = ANSIParser.parse(text)
        let segs = TerminalSegmenter.segment(lines, columns: 46, agentPane: true)
        #expect(segs.map(\.kind) == [.message, .plain])
        #expect(segs[0].copyText == """
            the end of a long paragraph that started above the screen.
            ──────────    ──────
            Count time spent fixing errors.
            """)
        // Shell panes don't guess: indented output is just output.
        #expect(TerminalSegmenter.segment(lines, columns: 46).map(\.kind) == [.plain])
    }
}

@Suite struct LinkDetectorTests {
    @Test func singleLineWithTrailingPunctuation() {
        let links = LinkDetector.links(in: ["see https://example.com/a?b=1. next", "(at https://x.dev/p_(1))"])
        #expect(links.map(\.url.absoluteString) == ["https://example.com/a?b=1", "https://x.dev/p_(1)"])
        #expect(links[0].pieces == [.init(line: 0, range: 4..<29)])
    }

    @Test func agentBrokeURLAtHyphen() {
        let lines = [
            "   - https://macmini01.tailnet01.ts.net:8082/product-health-",
            "jim9.html",
            "   - https://macmini01.tailnet01.ts.net:8082/product-health-",
            "jim9-dark.html",
        ]
        let links = LinkDetector.links(in: lines)
        #expect(links.map(\.url.absoluteString) == [
            "https://macmini01.tailnet01.ts.net:8082/product-health-jim9.html",
            "https://macmini01.tailnet01.ts.net:8082/product-health-jim9-dark.html",
        ])
        #expect(links[0].pieces == [.init(line: 0, range: 5..<60), .init(line: 1, range: 0..<9)])
    }

    @Test func terminalWidthWrap() {
        let links = LinkDetector.links(in: ["go https://example.com/abcdefgh", "ijk/lmn then"], columns: 31)
        #expect(links.map(\.url.absoluteString) == ["https://example.com/abcdefghijk/lmn"])
    }

    @Test func doesNotJoinOrdinaryNextLine() {
        let links = LinkDetector.links(in: ["docs at https://example.com/", "Then run the tests."], columns: 80)
        #expect(links.map(\.url.absoluteString) == ["https://example.com/"])
        #expect(links[0].pieces.count == 1)
    }

    @Test func ignoresNonURLs() {
        #expect(LinkDetector.links(in: ["http:// nothing", "ftp://x", "plain text"]).isEmpty)
    }
}

@Suite struct MessageLinkTests {
    @Test func copyRejoinsURLBrokenAcrossLines() {
        let lines = ANSIParser.parse([
            "⏺ Pages are live at https://macmini01.tailnet01.ts.net/product-",
            "  health-jim9.html for you.",
        ].joined(separator: "\n"))
        let segs = TerminalSegmenter.segment(lines, columns: 64)
        #expect(segs.first?.copyText == "Pages are live at https://macmini01.tailnet01.ts.net/product-health-jim9.html for you.")
    }
}

@Suite struct ReflowTests {
    @Test func rejoinsWrappedProseKeepingStyle() {
        let segs = TerminalSegmenter.segment(ANSIParser.parse(SegmenterTests.claude), columns: 60)
        let lines = TerminalSegmenter.reflowed(segs[0].lines, columns: 60)
        #expect(lines.map(\.plainText) == [
            "⏺ jim9 is trained and draws real dashboards. On your example its page has every number bound.",
            "  See it:",
            "  - https://example.ts.net/page.html",
        ])
        // The marker keeps its color.
        #expect(lines[0].runs[0].style.fg != .default)
    }

    @Test func listItemsAndBrokenURLs() {
        let lines = ANSIParser.parse([
            "⏺ Short intro line.",
            "  - Done: jim9 is committed and all the",
            "    tests pass.",
            "  - Next: https://example.com/product-",
            "    health.html",
            "",
            "  Bye.",
        ].joined(separator: "\n"))
        #expect(TerminalSegmenter.reflowed(lines, columns: 40).map(\.plainText) == [
            "⏺ Short intro line.",
            "  - Done: jim9 is committed and all the tests pass.",
            "  - Next: https://example.com/product-health.html",
            "",
            "  Bye.",
        ])
    }

    @Test func shortLinesAreLeftAlone() {
        let lines = ANSIParser.parse("⏺ One.\n  Two.\n  Three.")
        #expect(TerminalSegmenter.reflowed(lines, columns: 80).map(\.plainText) == ["⏺ One.", "  Two.", "  Three."])
    }
}

@Suite struct ScrollbackTests {
    static func lines(_ s: [String]) -> [StyledLine] { s.map { StyledLine(runs: [StyledRun(text: $0, style: TermStyle())]) } }

    @Test func keepsWhatComesBeforeTheScreen() {
        let recent = Self.lines(["old 1", "old 2", "", "$ ls", "a b c", "$ pwd", "/tmp", "$ "])
        let visible = Self.lines(["$ ls", "a b c", "$ pwd", "/tmp", "$ "])
        #expect(Scrollback.earlier(recent, visible: visible).map(\.plainText) == ["old 1", "old 2"])
    }

    @Test func screenStartingWithBlankLinesAndRepeatedText() {
        // "$ ls" appears twice; the match must be the one followed by the rest of the screen.
        let recent = Self.lines(["$ ls", "x", "", "$ ls", "a b c", "$ "])
        let visible = Self.lines(["", "$ ls", "a b c", "$ "])
        #expect(Scrollback.earlier(recent, visible: visible).map(\.plainText) == ["$ ls", "x"])
    }

    @Test func fallsBackToDroppingAScreen() {
        let recent = Self.lines(["1", "2", "3", "4"])
        let visible = Self.lines(["changed", "since"])
        #expect(Scrollback.earlier(recent, visible: visible).map(\.plainText) == ["1", "2"])
    }
}

extension ScrollbackTests {
    @Test func agentTranscriptWithDifferentLineBreaks() {
        // The screen shows a long prompt on one line; the transcript breaks it.
        let recent = Self.lines([
            "• Earlier answer.",
            "",
            "› ok we also have a pretty good CLAUDE.md file read that then",
            "update them",
            "Worked for 5m",
            "› Ask Codex to do anything",
        ])
        let visible = Self.lines([
            "› ok we also have a pretty good CLAUDE.md file read that then update them",
            "Worked for 5m",
            "",
            "› Ask Codex to do anything",
        ])
        #expect(Scrollback.earlier(recent, visible: visible).map(\.plainText) == ["• Earlier answer."])
    }
}
