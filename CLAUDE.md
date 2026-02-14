# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mORMot2 MCP Server: a high-performance Model Context Protocol (MCP) server implementing the **2025-06-18 specification**, built on the [mORMot2](https://github.com/synopse/mORMot2) framework. Pure Pascal, no external dependencies beyond mORMot2. Dual-compiler: Delphi 10.3+ and Free Pascal 3.2+.

## Building

```bash
# Delphi (command line)
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64

# Free Pascal / Lazarus
lazbuild MCPServer.lpi
```

**mORMot2 dependency**: Source expected at `W:\mORMot2\` (Windows) / `../mORMot2/` (Lazarus relative path). Subfolders used: `src/core`, `src/lib`, `src/net`, `src/crypt`.

**Output**: `bin/MCPServer.exe` (DCU intermediates: `$(Platform)/$(Config)/`)

## Running

```bash
MCPServer.exe --transport=stdio          # For Claude Desktop / CLI integration
MCPServer.exe --transport=http           # HTTP + SSE on port 3000
MCPServer.exe --transport=http --port=8080
MCPServer.exe --transport=http --daemon   # Daemon mode (Ctrl+C to stop)
```

## Architecture

### Request Flow

```
Client (JSON-RPC 2.0)
  → Transport (stdio or HTTP+SSE)
    → TMCPRequestProcessor.HandleRequest()
      → TMCPManagerRegistry.GetManagerForMethod()
        → IMCPCapabilityManager.ExecuteMethod()
          → Response (JSON-RPC 2.0)
```

### Layer Responsibilities

| Layer | Location | Purpose |
|-------|----------|---------|
| **Protocol** | `src/Protocol/MCP.Types.pas` | Core types, settings record, JSON-RPC helpers, error codes, cancelled request tracking |
| **Transport** | `src/Transport/` | Pluggable I/O: `TMCPStdioTransport` (stdin/stdout) and `TMCPHttpTransport` (async HTTP + SSE via `THttpAsyncServer`) |
| **Core** | `src/Core/` | `TMCPManagerRegistry` (method→manager dispatch) and `TMCPEventBus` (thread-safe pub/sub singleton) |
| **Managers** | `src/Managers/` | One per MCP capability namespace: Core, Tools, Resources, Prompts, Logging, Completion |
| **Extensions** | `src/Tools/`, `src/Resources/`, `src/Prompts/` | Base classes + example implementations for each extensible capability |
| **Server** | `src/Server/MCP.Server.pas` | Legacy HTTP server (superseded by transport layer) |
| **Entry** | `MCPServer.dpr` / `.lpr` | Wiring: creates registry, managers, tools, transport; contains `TMCPRequestProcessor` |

### Key Design Patterns

**Manager Registry**: Each manager implements `IMCPCapabilityManager` (from `MCP.Types.pas`) with `HandlesMethod()` and `ExecuteMethod()`. The registry iterates managers to find one that handles the incoming method string.

**Event Bus**: `TMCPEventBus.GetInstance` singleton. Managers publish events (`MCP_EVENT_TOOLS_LIST_CHANGED`, `MCP_EVENT_RESOURCES_UPDATED`, etc.), transports subscribe to broadcast SSE notifications. Thread-safe with critical sections; queues events when no subscribers exist.

**Transport Abstraction**: `IMCPTransport` interface + `TMCPTransportBase` base class providing graceful shutdown (5s timeout), pending request tracking, and signal handling. `TMCPTransportFactory` creates the appropriate transport from config.

### Extending the Server

**Adding a Tool**: Create a unit with a class inheriting `TMCPToolBase` (from `MCP.Tool.Base.pas`). Override `Create` (set `fName`, `fDescription`), `BuildInputSchema` (return JSON Schema as `TDocVariant`), and `Execute` (return via `ToolResultText()` or `ToolResultJson()`). Register in `MCPServer.dpr`: `ToolsManager.RegisterTool(TMCPToolMyTool.Create)`. Also add the unit to the `.dpr` uses clause and `.dproj` file list.

**Adding a Resource**: Inherit `TMCPResourceBase` or use `TMCPTextResource`/`TMCPBlobResource` (from `MCP.Resource.Base.pas`). Register via `ResourcesManager.RegisterResource()`.

**Adding a Prompt**: Inherit `TMCPPromptBase` (from `MCP.Prompt.Base.pas`). Use `AddArgument()` in constructor, implement `BuildMessages()`. Register via `PromptsManager.RegisterPrompt()`.

### JSON Handling Convention

All JSON is handled through mORMot2's `TDocVariant` — no record-based serialization. Pattern:
```pascal
TDocVariantData(Result).InitFast;
TDocVariantData(Result).U['field'] := 'value';  // RawUtf8
TDocVariantData(Result).I['count'] := 42;        // Integer
TDocVariantData(Result).B['flag'] := True;        // Boolean
TDocVariantData(Result).AddValue('obj', SubVariant);
```

### String Type

The codebase uses `RawUtf8` (mORMot2's UTF-8 string type) everywhere, not `string`. Use `StringToUtf8()` / `Utf8ToString()` for conversion at boundaries.

### MCP Protocol Constants

- Protocol version: `MCP_PROTOCOL_VERSION = '2025-06-18'` (also supports `'2025-03-26'`)
- JSON-RPC errors: `JSONRPC_PARSE_ERROR` (-32700), `JSONRPC_METHOD_NOT_FOUND` (-32601), `JSONRPC_REQUEST_CANCELLED` (-32800), `JSONRPC_RESOURCE_NOT_FOUND` (-32002)

### HTTP Transport Details

- Endpoint: `GET /mcp` (SSE stream), `POST /mcp` (JSON-RPC requests), `DELETE /mcp` (session termination)
- 128-bit cryptographic session IDs (via `TAesPrng`)
- SSE keepalive comments every 30s (configurable)
- CORS enabled by default (all origins)

### Initialization Order (in MCPServer.dpr)

1. Logging (`TSynLog` with 10MB rotation, 5 files)
2. Default settings (`InitDefaultSettings`)
3. Command-line parsing
4. Registry → CoreManager → LoggingManager → ToolsManager → ResourcesManager → PromptsManager → CompletionManager
5. Register built-in tools (Echo, GetTime)
6. Create transport → `RunWithTransport()` (blocks)
