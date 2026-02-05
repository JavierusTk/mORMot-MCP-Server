# mORMot2 MCP Server

[🇪🇸 Leer en español](README.es.md)

High-performance [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server implementation using the [mORMot2](https://github.com/synopse/mORMot2) framework.

**Implements MCP Specification 2025-06-18** with full support for bidirectional notifications via SSE.

## Features

### Core
- **Pure mORMot2 implementation** - No external dependencies beyond mORMot2
- **Dual transport support** - stdio and HTTP with SSE
- **JSON-RPC 2.0** - Full protocol support using `TDocVariant`
- **Modular architecture** - Easy to extend with custom tools, resources, and prompts
- **Cross-platform** - Compiles with Delphi and Free Pascal

### MCP Capabilities
- **Tools** - Register custom tools with JSON Schema validation and `listChanged` notifications
- **Resources** - List, read, templates, and subscriptions with URI-based access
- **Prompts** - List and get with multiple content types (text, image, audio, resource)
- **Logging** - `setLevel` method with RFC 5424 log levels
- **Completion** - Argument auto-completion for prompts and resources

### Transport Layer
- **stdio transport** - JSON-RPC newline-delimited, logs to stderr
- **HTTP transport** - REST API with Server-Sent Events (SSE) and CORS support
- **Session management** - Cryptographic session IDs (128-bit)
- **SSE notifications** - Real-time bidirectional communication
- **Keepalive** - Configurable SSE keepalive (default 30s)
- **Graceful shutdown** - SIGTERM/SIGINT handling with 5s timeout
- **Event bus** - Thread-safe pub/sub for internal notification routing

### Notifications
- `notifications/tools/list_changed` - Tool registration changes
- `notifications/resources/list_changed` - Resource changes
- `notifications/resources/updated` - Subscribed resource updates
- `notifications/prompts/list_changed` - Prompt changes
- `notifications/message` - Log messages
- `notifications/progress` - Progress updates
- `notifications/cancelled` - Request cancellation

## Requirements

- [mORMot2](https://github.com/synopse/mORMot2) framework
- Delphi 10.3+ (tested) or Free Pascal 3.2+ (not yet tested)

## Project Structure

```
mORMot-MCP-Server/
├── MCPServer.dpr           # Delphi project
├── MCPServer.lpr           # Free Pascal project
├── MCPServer.lpi           # Lazarus project
├── src/
│   ├── Core/
│   │   ├── MCP.Manager.Registry.pas   # Manager registration
│   │   └── MCP.Events.pas             # Event bus (pub/sub)
│   ├── Protocol/
│   │   └── MCP.Types.pas              # Core types and settings
│   ├── Transport/
│   │   ├── MCP.Transport.Base.pas     # Transport abstraction
│   │   ├── MCP.Transport.Stdio.pas    # stdio transport
│   │   └── MCP.Transport.Http.pas     # HTTP + SSE transport
│   ├── Server/
│   │   └── MCP.Server.pas             # Legacy HTTP server
│   ├── Managers/
│   │   ├── MCP.Manager.Core.pas       # initialize, ping
│   │   ├── MCP.Manager.Tools.pas      # tools/list, tools/call
│   │   ├── MCP.Manager.Resources.pas  # resources/*, subscriptions
│   │   ├── MCP.Manager.Prompts.pas    # prompts/list, prompts/get
│   │   ├── MCP.Manager.Logging.pas    # logging/setLevel
│   │   └── MCP.Manager.Completion.pas # completion/complete
│   ├── Tools/
│   │   ├── MCP.Tool.Base.pas          # Base tool class
│   │   ├── MCP.Tool.Echo.pas          # Echo example
│   │   └── MCP.Tool.GetTime.pas       # GetTime example
│   ├── Resources/
│   │   └── MCP.Resource.Base.pas      # Base resource class
│   └── Prompts/
│       └── MCP.Prompt.Base.pas        # Base prompt class
```

## Building

### With Delphi

Open `MCPServer.dproj` in Delphi IDE. Ensure mORMot2 source paths are configured.

```bash
# Or from command line
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64
```

### With Free Pascal / Lazarus

```bash
lazbuild MCPServer.lpi
```

## Usage

### stdio Transport (for Claude Desktop)

```bash
MCPServer.exe --transport=stdio
```

Configure in Claude Desktop (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "mormot-server": {
      "command": "C:\\path\\to\\MCPServer.exe",
      "args": ["--transport=stdio"]
    }
  }
}
```

### HTTP Transport (for web clients)

```bash
# Default port 3000
MCPServer.exe --transport=http

# Custom port
MCPServer.exe --transport=http --port=8080
```

### SSE Connection

```bash
# Open SSE stream for notifications
curl -N -H "Accept: text/event-stream" http://localhost:3000/mcp
```

## API Examples

### Initialize Session

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Protocol-Version: 2025-06-18" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": {"name": "test", "version": "1.0"}
    }
  }'
```

### List Tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### Call Tool

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {"message": "Hello, World!"}
    }
  }'
```

## Adding Custom Tools

```pascal
unit MCP.Tool.MyTool;

{$I mormot.defines.inc}

interface

uses
  mormot.core.base,
  mormot.core.variants,
  MCP.Tool.Base;

type
  TMCPToolMyTool = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

constructor TMCPToolMyTool.Create;
begin
  inherited;
  fName := 'my_tool';
  fDescription := 'My custom tool';
end;

function TMCPToolMyTool.BuildInputSchema: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  // Add properties...
end;

function TMCPToolMyTool.Execute(const Arguments: Variant): Variant;
begin
  // Return success
  Result := ToolResultText('Done!');

  // Or return error
  // Result := ToolResultText('Error message', True);
end;

end.
```

Register in `MCPServer.dpr`:
```pascal
ToolsManager.RegisterTool(TMCPToolMyTool.Create);
```

## Configuration

Settings in `MCP.Types.pas`:

```pascal
Settings.ServerName := 'mORMot-MCP-Server';
Settings.ServerVersion := '1.0.0';
Settings.Port := 3000;
Settings.Host := '0.0.0.0';
Settings.Endpoint := '/mcp';
Settings.SSEKeepaliveIntervalMs := 30000;  // 30 seconds
```

## Performance

| Aspect | mORMot2 MCP Server |
|--------|-------------------|
| HTTP Server | `THttpAsyncServer` (async I/O) |
| JSON | `TDocVariant` (zero-copy) |
| Memory | Minimal allocation |
| Threading | Thread pool |
| SSE | Native implementation |

## License

MIT License - See [LICENSE](LICENSE) file.

## See Also

- [mORMot2 Documentation](https://synopse.info/files/doc/mORMot2.html)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP Protocol Version 2025-06-18](https://modelcontextprotocol.io/docs/concepts/transports)
