import Foundation

/// JSON-RPC 2.0 server over stdio, implementing the subset of the
/// Model Context Protocol (MCP) that exposes tools.
///
/// Wire format is newline-delimited JSON — one message per line on
/// stdin, one per line written to stdout. Requests with no `id` are
/// notifications and produce no response.
final class MCPServer {
    let config: MCPConfig

    init(config: MCPConfig) { self.config = config }

    func run() {
        while let line = readLine() {
            if line.isEmpty { continue }
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            writeError(id: nil, code: -32700, message: "Parse error")
            return
        }
        let id = msg["id"]
        let isNotification = id == nil
        let method = (msg["method"] as? String) ?? ""
        let params = (msg["params"] as? [String: Any]) ?? [:]

        do {
            let result = try dispatch(method: method, params: params)
            if !isNotification {
                writeResult(id: id, result: result)
            }
        } catch let error as MCPError {
            if !isNotification {
                writeError(id: id, code: error.code, message: error.message)
            }
        } catch {
            if !isNotification {
                writeError(id: id, code: -32603, message: error.localizedDescription)
            }
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "todarchy-mcp",
                    "version": "0.1.0"
                ]
            ]
        case "notifications/initialized", "initialized":
            // Notifications — handler returns a placeholder; the
            // caller drops the response for null-id messages.
            return [String: Any]()
        case "tools/list":
            return ["tools": MCPTools.all.map { $0.descriptor }]
        case "tools/call":
            return try MCPTools.call(params: params, config: config)
        default:
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - JSON-RPC framing

    private func writeResult(id: Any?, result: Any) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        emit(msg)
    }

    private func writeError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { msg["id"] = id }
        emit(msg)
    }

    private func emit(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: []) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))   // '\n'
    }
}

struct MCPError: Error {
    let code: Int
    let message: String
}
