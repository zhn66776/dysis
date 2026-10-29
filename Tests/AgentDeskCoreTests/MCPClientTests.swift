import Foundation
import XCTest
@testable import AgentDeskCore

final class MCPClientTests: XCTestCase {
    func testConfigurationNeverStoresEnvironmentValues() throws {
        let configuration = MCPServerConfiguration(name: "Fixture", transport: .stdio(command: "/usr/bin/python3", arguments: []), environmentVariableNames: ["FIXTURE_TOKEN", "not valid"])
        XCTAssertEqual(configuration.environmentVariableNames, ["FIXTURE_TOKEN"])
        let data = try JSONEncoder().encode(configuration)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertTrue(encoded.contains("FIXTURE_TOKEN"))
    }

    func testJSONValueRoundTripsNestedValues() throws {
        let value = try MCPJSONValue(any: ["enabled": true, "items": [1, "x"], "none": NSNull()])
        let restored = try MCPJSONValue(jsonData: value.jsonData())
        XCTAssertEqual(value, restored)
    }

    func testJSONValueDistinguishesNSNumberOneFromBoolean() throws {
        XCTAssertEqual(try MCPJSONValue(any: NSNumber(value: 1)), .number(1))
        XCTAssertEqual(try MCPJSONValue(any: NSNumber(value: true)), .bool(true))
    }

    func testStdioInitializeListAndExplicitToolCall() async throws {
        let script = #"""
import sys,json
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    m=req.get("method")
    if m=="initialize":
        out={"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}
    elif m=="tools/list":
        out={"tools":[{"name":"echo","description":"fixture echo","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}
    elif m=="tools/call":
        out={"content":[{"type":"text","text":req.get("params",{}).get("arguments",{}).get("text","missing")}],"isError":False}
    else:
        out={}
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":out}),flush=True)
"""#
        let configuration = MCPServerConfiguration(name: "Fixture", transport: .stdio(command: "/usr/bin/python3", arguments: ["-u", "-c", script]))
        let client = MCPClient(configuration: configuration, workingDirectory: FileManager.default.temporaryDirectory, limits: MCPLimits(timeout: 5))
        let info = try await client.testConnection()
        XCTAssertEqual(info.serverName, "fixture")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let result = try await client.callTool(name: "echo", argumentsJSON: #"{"text":"hello"}"#)
        XCTAssertEqual(result.displayText, "hello")
    }

    func testToolArgumentsMustBeObject() async throws {
        let configuration = MCPServerConfiguration(name: "Invalid", transport: .stdio(command: "/usr/bin/true", arguments: []))
        let client = MCPClient(configuration: configuration)
        do {
            _ = try await client.callTool(name: "x", argumentsJSON: "[]")
            XCTFail("expected JSON object validation")
        } catch let error as AgentError {
            XCTAssertTrue(error.localizedDescription.contains("JSON 对象"))
        }
    }

    func testStdioIgnoresMismatchedResponseIDAndSupportsPagination() async throws {
        let script = #"""
import sys,json
for line in sys.stdin:
    req=json.loads(line)
    if "id" not in req: continue
    ident=req["id"]
    if req.get("method")=="initialize":
        out={"protocolVersion":"2025-03-26","serverInfo":{"name":"pages"}}
    elif req.get("method")=="tools/list":
        if req.get("params",{}).get("cursor"):
            out={"tools":[{"name":"second"}]}
        else:
            print(json.dumps({"jsonrpc":"2.0","id":999,"result":{"tools":[{"name":"wrong"}]}}),flush=True)
            out={"tools":[{"name":"first"}],"nextCursor":"page-2"}
    else: out={}
    print(json.dumps({"jsonrpc":"2.0","id":ident,"result":out}),flush=True)
"""#
        let config = MCPServerConfiguration(name: "Pages", transport: .stdio(command: "/usr/bin/python3", arguments: ["-u", "-c", script]))
        let client = MCPClient(configuration: config, limits: MCPLimits(timeout: 5, maxPages: 3))
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
    }

    func testUnsupportedProtocolVersionIsRejected() async throws {
        let script = #"""
import sys,json
for line in sys.stdin:
    req=json.loads(line)
    if "id" in req:
        print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":{"protocolVersion":"2026-01-01"}}),flush=True)
"""#
        let config = MCPServerConfiguration(name: "Old", transport: .stdio(command: "/usr/bin/python3", arguments: ["-u", "-c", script]))
        do {
            _ = try await MCPClient(configuration: config, limits: MCPLimits(timeout: 5)).testConnection()
            XCTFail("old protocol must be rejected")
        } catch let error as AgentError {
            XCTAssertTrue(error.localizedDescription.contains("协议版本"))
        }
    }

    func testDisabledServerNeverStartsItsProcess() async throws {
        let config = MCPServerConfiguration(name: "Disabled", transport: .stdio(command: "/usr/bin/false", arguments: []), enabled: false)
        do {
            _ = try await MCPClient(configuration: config).testConnection()
            XCTFail("disabled server must not start")
        } catch let error as AgentError {
            XCTAssertTrue(error.localizedDescription.contains("停用"))
        }
    }

    func testStreamableHTTPJSONAndOpenSSEResponseStopAtMatchingID() async throws {
        let fixture: (process: Process, port: Int)
        do { fixture = try startHTTPFixture() }
        catch { throw XCTSkip("本机测试环境不允许绑定回环端口，跳过 HTTP fixture：\(error.localizedDescription)") }
        defer { fixture.process.terminate() }
        let config = MCPServerConfiguration(name: "HTTP", transport: .streamableHTTP(url: "http://127.0.0.1:\(fixture.port)/mcp"))
        let client = MCPClient(configuration: config, limits: MCPLimits(timeout: 2))
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["sse"])
    }

    func testIncrementalSSEParserIgnoresWrongIDAndReturnsWithoutStreamClose() throws {
        var parser = MCPHTTPResponseParser(id: 7, maxOutputBytes: 10_000)
        XCTAssertNil(try parser.consume(line: "data: {\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{}}"))
        XCTAssertNil(try parser.consume(line: ""))
        let response = try parser.consume(line: "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}")
        XCTAssertEqual(response?["id"] as? Int, 7)
    }

    func testIncrementalParserAcceptsPrettyPrintedJSONWithoutNewlineLimitByLine() throws {
        var parser = MCPHTTPResponseParser(id: 3, maxOutputBytes: 10_000)
        XCTAssertNil(try parser.consume(line: "{"))
        XCTAssertNil(try parser.consume(line: "  \"jsonrpc\": \"2.0\","))
        XCTAssertNil(try parser.consume(line: "  \"id\": 3,"))
        XCTAssertNil(try parser.consume(line: "  \"result\": {}"))
        let response = try parser.consume(line: "}")
        XCTAssertEqual(response?["id"] as? Int, 3)
    }

    func testIncrementalParserBoundsUnterminatedLine() {
        var parser = MCPHTTPResponseParser(id: 1, maxOutputBytes: 16)
        XCTAssertThrowsError(try parser.consume(line: String(repeating: "x", count: 17)))
    }

    private func startHTTPFixture() throws -> (process: Process, port: Int) {
        let script = #"""
import http.server,json,sys,time
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def do_POST(self):
        length=int(self.headers.get('Content-Length','0'))
        request=json.loads(self.rfile.read(length) or b'{}')
        method=request.get('method')
        if method=='notifications/initialized':
            self.send_response(202); self.send_header('Content-Length','0'); self.end_headers(); return
        if method=='initialize':
            body=json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'protocolVersion':'2025-03-26','serverInfo':{'name':'http-fixture'}}}).encode()
            self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Mcp-Session-Id','fixture'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
        if method=='tools/list':
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Mcp-Session-Id','fixture'); self.end_headers()
            wrong=json.dumps({'jsonrpc':'2.0','id':999,'result':{'tools':[{'name':'wrong'}]}})
            right=json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'tools':[{'name':'sse'}]}})
            self.wfile.write(('data: '+wrong+'\n\n').encode()); self.wfile.flush()
            self.wfile.write(('data: '+right+'\n\n').encode()); self.wfile.flush()
            time.sleep(60); return
        self.send_response(200); self.send_header('Content-Length','0'); self.end_headers()
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script]
        process.standardOutput = pipe
        process.standardError = errorPipe
        try process.run()
        var line = Data()
        while !line.contains(10) {
            guard let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                let error = String(decoding: (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
                throw AgentError.processFailure("HTTP fixture did not start: \(error)")
            }
            line.append(contentsOf: byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AgentError.processFailure("HTTP fixture returned invalid port") }
        return (process, port)
    }
}
