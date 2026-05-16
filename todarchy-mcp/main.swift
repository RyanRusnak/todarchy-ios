import Foundation

let config = MCPConfig.load()
let server = MCPServer(config: config)
server.run()
