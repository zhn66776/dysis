import Foundation
import XCTest
@testable import AgentDeskCore

/// AgentDesk's files MCP server: path rules, the request files, and the tools.
final class FolderAccessTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var data: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-access-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        data = root.appendingPathComponent("data")
        for dir in ["Reports/2026", ".ssh", "Library/Keychains", "Library/Mobile Documents/notes"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "NVDA 40%\nAAPL 25%".write(to: home.appendingPathComponent("Reports/holdings.txt"), atomically: true, encoding: .utf8)
        try "q3".write(to: home.appendingPathComponent("Reports/2026/q3-holdings.md"), atomically: true, encoding: .utf8)
        try "key".write(to: home.appendingPathComponent(".ssh/id_ed25519"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testPathRules() {
        let rule = { FolderAccessPolicy.refusal(FolderAccessPolicy.resolve($0, home: self.home), home: self.home) }
        XCTAssertNil(rule("Reports/holdings.txt"))
        XCTAssertNil(rule(home.appendingPathComponent("Library/Mobile Documents/notes").path))
        XCTAssertNotNil(rule(".ssh/id_ed25519"))
        XCTAssertNotNil(rule("Reports/../.ssh"), "resolved before checking")
        XCTAssertNotNil(rule("Library/Keychains"))
        XCTAssertNotNil(rule("/etc/hosts"))
        XCTAssertEqual(FolderAccessPolicy.scope(of: home.appendingPathComponent("Reports/holdings.txt")).path, home.appendingPathComponent("Reports").path)
        XCTAssertTrue(FolderAccessPolicy.covers([home.appendingPathComponent("Reports").path], home.appendingPathComponent("Reports/2026/q3-holdings.md")))
        XCTAssertFalse(FolderAccessPolicy.covers([home.appendingPathComponent("Reports").path], home.appendingPathComponent("ReportsOld/a")))
    }

    func testReaderListsReadsAndSearches() throws {
        let reports = home.appendingPathComponent("Reports")
        let listing = try FolderReader.list(reports, home: home)
        XCTAssertTrue(listing.contains("2026/"))
        XCTAssertTrue(listing.contains("holdings.txt"))
        XCTAssertTrue(try FolderReader.read(reports.appendingPathComponent("holdings.txt")).contains("NVDA 40%"))
        XCTAssertEqual(try FolderReader.read(reports.appendingPathComponent("holdings.txt"), offset: 9), "AAPL 25%")
        XCTAssertTrue(FolderReader.search(home, query: "holdings", home: home).contains("q3-holdings.md"))
        XCTAssertFalse(FolderReader.search(home, query: "id_", home: home).contains("id_ed25519"), "hidden folders are skipped")
        try Data([0, 1, 2]).write(to: reports.appendingPathComponent("blob.bin"))
        XCTAssertThrowsError(try FolderReader.read(reports.appendingPathComponent("blob.bin")))
    }

    func testExchangeRoundTripAndGrants() throws {
        let exchange = FolderAccessExchange(root: data)
        let session = UUID()
        let request = FolderAccessRequest(token: "t", sessionID: session, tool: "read_file", path: "/a/b.txt", folder: "/a", reason: "看持仓")
        try exchange.post(request)
        XCTAssertEqual(exchange.pending().map(\.id), [request.id])
        try exchange.respond(request, decision: .conversation)
        XCTAssertTrue(exchange.pending().isEmpty)
        XCTAssertEqual(exchange.waitForDecision(request.id, timeout: 1), .conversation)
        XCTAssertEqual(exchange.grantedFolders(session: session), ["/a"])
        XCTAssertEqual(exchange.allGrants(), [session: ["/a"]])
        XCTAssertEqual(exchange.waitForDecision(UUID(), timeout: 0.3, poll: 0.05), .deny, "no answer is a no")
        try exchange.setGrantedFolders([], session: session)
        XCTAssertTrue(exchange.allGrants().isEmpty)
    }

    func testServerAsksOnceAndRemembersTheConversationGrant() throws {
        let exchange = FolderAccessExchange(root: data)
        let session = UUID()
        let server = FolderAccessServer(exchange: exchange, sessionID: session, token: "tok", home: home, timeout: 5)
        var asked: [FolderAccessRequest] = []
        let responder = Thread {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                for request in exchange.pending() { asked.append(request); try? exchange.respond(request, decision: .conversation) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        responder.start()
        let first = call(server, "read_file", ["path": "~/Reports/holdings.txt", "reason": "看持仓"])
        XCTAssertEqual(first.isError, false)
        XCTAssertTrue(first.text.contains("NVDA 40%"))
        let second = call(server, "list_directory", ["path": "~/Reports/2026"])
        XCTAssertEqual(second.isError, false, "covered by the folder granted for this conversation")
        responder.cancel()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.folder, home.appendingPathComponent("Reports").path)
        XCTAssertEqual(asked.first?.token, "tok")
        XCTAssertEqual(asked.first?.reason, "看持仓")
    }

    func testServerRefusesHiddenPathsWithoutAskingAndReportsADenial() throws {
        let exchange = FolderAccessExchange(root: data)
        let server = FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", home: home, timeout: 0.4)
        let hidden = call(server, "read_file", ["path": "~/.ssh/id_ed25519"])
        XCTAssertTrue(hidden.isError)
        XCTAssertFalse(hidden.text.contains("key"))
        XCTAssertTrue(exchange.pending().isEmpty, "never asked")
        let unanswered = call(server, "search_files", ["folder": "~/Reports", "query": "q3"])
        XCTAssertTrue(unanswered.isError)
        XCTAssertTrue(unanswered.text.contains("没有允许"))
    }

    func testProtocolHandshakeAndToolList() throws {
        let server = FolderAccessServer(exchange: FolderAccessExchange(root: data), sessionID: UUID(), token: "t", home: home)
        let initialize = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        XCTAssertTrue(initialize.contains("agentdesk-files"))
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        let list = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["result"] as? [String: Any])["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["list_directory", "read_file", "search_files"])
    }

    private func call(_ server: FolderAccessServer, _ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool) {
        let result = server.call(name, arguments)
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        return (text, result["isError"] as? Bool ?? true)
    }
}
