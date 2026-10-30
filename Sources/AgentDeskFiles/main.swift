import Foundation
import AgentDeskCore

// AgentDesk's files MCP server, started by a provider CLI for one
// conversation: agentdesk-files --data <dir> --session <uuid> --token <t>
// [--no-files] [--project <folder>] (adds memory_propose for that project)
let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
guard let data = value("--data"), let session = value("--session").flatMap(UUID.init(uuidString:)), let token = value("--token") else {
    FileHandle.standardError.write(Data("usage: agentdesk-files --data <dir> --session <uuid> --token <token>\n".utf8))
    exit(2)
}
// --home is for tests only: the folder that stands in for the user's home.
let home = value("--home").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
FolderAccessServer(exchange: FolderAccessExchange(root: URL(fileURLWithPath: data, isDirectory: true)), sessionID: session, token: token, home: home,
                   files: !args.contains("--no-files"), project: value("--project").map { URL(fileURLWithPath: $0, isDirectory: true) }).run()
