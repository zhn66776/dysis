import Foundation
import XCTest
@testable import AgentDeskCore

final class MultimodalAdapterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-multimodal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testValidationRejectsUnsupportedImageAndOversizedInput() throws {
        let text = directory.appendingPathComponent("not-image.txt")
        try Data("fixture".utf8).write(to: text)
        XCTAssertThrowsError(try MultimodalInputSupport.validate([AgentImageInput(localURL: text, mediaType: "text/plain")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("图片类型"))
        }
    }

    func testClaudeStreamJSONContainsImageContentBlock() async throws {
        let image = directory.appendingPathComponent("fixture.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: image)
        let executable = try makeFixture(source: Self.claudeFixture)
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "请描述图片", workingDirectory: directory, modelID: "sonnet", executableURL: executable, reasoningEffort: "high", images: [AgentImageInput(localURL: image, mediaType: "image/png")])
        var reply = ""
        for try await event in ClaudeBackend().stream(request) {
            if case .textDelta(let value) = event { reply += value }
            if case .replaceText(let value) = event { reply = value }
        }
        XCTAssertEqual(reply, "IMAGE_OK")
    }

    func testClaudeImageResumePreservesSessionAndEffort() async throws {
        let image = directory.appendingPathComponent("resume.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: image)
        let executable = try makeFixture(source: Self.claudeResumeFixture)
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: "remote-image-session", prompt: "继续看图", workingDirectory: directory, modelID: "opus", executableURL: executable, reasoningEffort: "xhigh", images: [AgentImageInput(localURL: image, mediaType: "image/png")])
        var reply = ""
        for try await event in ClaudeBackend().stream(request) {
            if case .textDelta(let value) = event { reply += value }
            if case .replaceText(let value) = event { reply = value }
        }
        XCTAssertEqual(reply, "RESUMED_IMAGE_OK")
    }

    func testCodexTurnUsesLocalImageInput() async throws {
        let image = directory.appendingPathComponent("fixture.jpg")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: image)
        let executable = try makeFixture(source: Self.codexFixture)
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "检查图片", workingDirectory: directory, modelID: "gpt-6.1-sol", executableURL: executable, reasoningEffort: "high", images: [AgentImageInput(localURL: image, mediaType: "image/jpeg")])
        var reply = ""
        for try await event in CodexBackend(executableURL: executable).stream(request) {
            if case .textDelta(let value) = event { reply += value }
        }
        XCTAssertEqual(reply, "IMAGE_OK")
    }

    func testCursorImageInputFailsExplicitlyInsteadOfDroppingAttachment() async throws {
        let image = directory.appendingPathComponent("fixture.png")
        try Data([1, 2, 3]).write(to: image)
        let executable = try makeFixture(source: "#!/usr/bin/python3\nimport sys\nif sys.argv[1:]==['status']: print('logged in')\n")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "图片", workingDirectory: directory, modelID: "grok-4.7-medium", executableURL: executable, images: [AgentImageInput(localURL: image, mediaType: "image/png")])
        do {
            for try await _ in CursorBackend().stream(request) { }
            XCTFail("expected explicit unsupported image error")
        } catch let error as AgentError {
            XCTAssertTrue(error.localizedDescription.contains("图片输入"))
        }
    }

    private func makeFixture(source: String) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).py")
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let claudeFixture = #"""
#!/usr/bin/python3
import json,sys
a=sys.argv[1:]
if 'auth' in a and 'status' in a:
 print(json.dumps({'authMethod':'claude.ai','apiProvider':'firstParty','subscriptionType':'pro'})); sys.exit(0)
assert '--input-format' in a and a[a.index('--input-format')+1]=='stream-json'
line=json.loads(sys.stdin.readline())
content=line['message']['content']
assert content[1]['type']=='image'
assert content[1]['source']['type']=='base64'
assert content[1]['source']['media_type']=='image/png'
sid=a[a.index('--session-id')+1]
print(json.dumps({'type':'system','subtype':'init','session_id':sid}),flush=True)
print(json.dumps({'type':'result','subtype':'success','session_id':sid,'result':'IMAGE_OK'}),flush=True)
"""#

    private static let codexFixture = #"""
#!/usr/bin/python3
import json,sys
for line in sys.stdin:
 m=json.loads(line); method=m.get('method'); ident=m.get('id')
 if method=='initialize': print(json.dumps({'id':ident,'result':{}}),flush=True)
 elif method=='config/read': print(json.dumps({'id':ident,'result':{'config':{'mcp_servers':{}}}}),flush=True)
 elif method=='account/read': print(json.dumps({'id':ident,'result':{'account':{'type':'chatgpt'}}}),flush=True)
 elif method=='model/list': print(json.dumps({'id':ident,'result':{'data':[{'id':'gpt-6.1-sol','isDefault':True,'defaultReasoningEffort':'high','supportedReasoningEfforts':[{'reasoningEffort':'high'}],'inputModalities':['text','image']}]}}),flush=True)
 elif method=='thread/start': print(json.dumps({'id':ident,'result':{'thread':{'id':'thread-image'}}}),flush=True)
 elif method=='turn/start':
  inputs=m['params']['input']; assert inputs[1]['type']=='localImage'; assert inputs[1]['path'].endswith('fixture.jpg')
  print(json.dumps({'id':ident,'result':{'turn':{'id':'turn-image'}}}),flush=True)
  print(json.dumps({'method':'item/agentMessage/delta','params':{'delta':'IMAGE_OK'}}),flush=True)
  print(json.dumps({'method':'turn/completed','params':{'turn':{'status':'completed'}}}),flush=True)
 elif method=='initialized': pass
"""#

    private static let claudeResumeFixture = #"""
#!/usr/bin/python3
import json,sys
a=sys.argv[1:]
if 'auth' in a and 'status' in a:
 print(json.dumps({'authMethod':'claude.ai','apiProvider':'firstParty','subscriptionType':'pro'})); sys.exit(0)
assert a[a.index('--effort')+1]=='xhigh'
assert a[a.index('--resume')+1]=='remote-image-session'
assert '--input-format' in a
line=json.loads(sys.stdin.readline())
assert line['session_id']=='remote-image-session'
assert line['message']['content'][1]['source']['media_type']=='image/png'
print(json.dumps({'type':'system','subtype':'init','session_id':'remote-image-session'}),flush=True)
print(json.dumps({'type':'result','subtype':'success','session_id':'remote-image-session','result':'RESUMED_IMAGE_OK'}),flush=True)
"""#
}
