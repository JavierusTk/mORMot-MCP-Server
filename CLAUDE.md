# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mORMot2 MCP Server: a high-performance Model Context Protocol (MCP) server implementing the **2026-07-28 specification** (stateless per-request model) with full backward compatibility down to **2024-11-05** (initialize/session model), built on the [mORMot2](https://github.com/synopse/mORMot2) framework. Pure Pascal, no external dependencies beyond mORMot2. Dual-compiler: Delphi 10.3+ and Free Pascal 3.2+.

**Dual-era model**: each request's protocol era is resolved from `_meta['io.modelcontextprotocol/protocolVersion']` (authoritative) and/or the `MCP-Protocol-Version` HTTP header. Versions >= 2026-07-28 follow the *modern* stateless path (no initialize, no sessions, `resultType` + `serverInfo` + cache hints on results, `server/discover`, `subscriptions/listen`); older versions follow the *legacy* path unchanged (initialize handshake, `Mcp-Session-Id`, GET SSE stream, `ping`, `logging/setLevel`, `resources/subscribe`). The era logic lives in `src/Core/MCP.RequestProcessor.pas`.

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
    → TMCPRequestProcessor.HandleRequestEx()   [era resolution + validation]
      → TMCPManagerRegistry.GetManagerForMethod()
        → IMCPCapabilityManager.ExecuteMethod()
          → modern-era decoration (resultType, _meta.serverInfo, ttlMs/cacheScope)
            → Response (JSON-RPC 2.0)
```

`subscriptions/listen` is intercepted at the transport layer (it owns the long-lived stream registry) and never reaches the processor.

### Layer Responsibilities

| Layer | Location | Purpose |
|-------|----------|---------|
| **Protocol** | `src/Protocol/MCP.Types.pas` | Core types, settings record, JSON-RPC helpers, error codes, cancelled request tracking |
| **Transport** | `src/Transport/` | Pluggable I/O: `TMCPStdioTransport` (stdin/stdout) and `TMCPHttpTransport` (async HTTP + SSE via `THttpAsyncServer`) |
| **Core** | `src/Core/` | `TMCPManagerRegistry` (method→manager dispatch), `TMCPRequestProcessor` (shared JSON-RPC dispatch + protocol-era logic for both `.dpr`/`.lpr`) and `TMCPEventBus` (thread-safe pub/sub singleton) |
| **Managers** | `src/Managers/` | One per MCP capability namespace: Core, Tools, Resources, Prompts, Logging, Completion |
| **Extensions** | `src/Tools/`, `src/Resources/`, `src/Prompts/` | Base classes + example implementations for each extensible capability |
| **Server** | `src/Server/MCP.Server.pas` | Legacy HTTP server (superseded by transport layer) |
| **Entry** | `MCPServer.dpr` / `.lpr` | Wiring: creates registry, managers, tools, transport; wires `TMCPRequestProcessor.HandleRequestEx` |

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

- Protocol version: `MCP_PROTOCOL_VERSION = '2026-07-28'`; supported: `2026-07-28, 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05` (`MCP_SUPPORTED_VERSIONS`); modern-era threshold: `MCP_PROTOCOL_VERSION_MODERN`
- JSON-RPC errors: `JSONRPC_PARSE_ERROR` (-32700), `JSONRPC_METHOD_NOT_FOUND` (-32601), `JSONRPC_REQUEST_CANCELLED` (-32800), `JSONRPC_RESOURCE_NOT_FOUND` (-32002, legacy eras only; modern uses -32602), `JSONRPC_HEADER_MISMATCH` (-32020), `JSONRPC_MISSING_CLIENT_CAPABILITY` (-32021), `JSONRPC_UNSUPPORTED_PROTOCOL_VERSION` (-32022)
- Reserved `_meta` keys: `MCP_META_PROTOCOL_VERSION`, `MCP_META_CLIENT_INFO`, `MCP_META_CLIENT_CAPABILITIES`, `MCP_META_LOG_LEVEL`, `MCP_META_SERVER_INFO`, `MCP_META_SUBSCRIPTION_ID` (all `io.modelcontextprotocol/...`)

### HTTP Transport Details

- Endpoint: `POST /mcp` (JSON-RPC requests; the only method in 2026-07-28). Legacy eras also get `GET /mcp` (SSE stream) and `DELETE /mcp` (session termination); a modern `MCP-Protocol-Version` header on GET/DELETE returns 405
- Modern POST validation (SEP-2243): `MCP-Protocol-Version` + `Mcp-Method` required on every request; `Mcp-Name` required for `tools/call`/`prompts/get` (`params.name`) and `resources/read` (`params.uri`), supporting the `=?base64?...?=` sentinel encoding; mismatch → 400 + `-32020`
- `subscriptions/listen` POST answers with a long-lived SSE stream: first event is `notifications/subscriptions/acknowledged` (with `subscriptionId` in `_meta`), then only opted-in notifications; graceful shutdown sends the final JSON-RPC response on the stream
- 128-bit cryptographic session IDs (via `TAesPrng`) — legacy eras only
- SSE keepalive comments every 30s (configurable)
- CORS enabled by default (all origins)

### Initialization Order (in MCPServer.dpr)

1. Logging (`TSynLog` with 10MB rotation, 5 files)
2. Default settings (`InitDefaultSettings`)
3. Command-line parsing
4. Registry → CoreManager → LoggingManager → ToolsManager → ResourcesManager → PromptsManager → CompletionManager
5. Register built-in tools (Echo, GetTime)
6. Create transport → `RunWithTransport()` (blocks)

## Deferred: OAuth Authorization for the HTTP Transport

Decision (2026-08-21): **deferred until the HTTP transport is actually exposed publicly**. While usage is stdio or trusted LAN there is no gap — the MCP spec makes authorization OPTIONAL, and for stdio it explicitly says NOT to use OAuth (credentials come from the environment).

**Spec status**: OAuth authorization is an official part of the MCP spec for HTTP transports (since 2025-03-26; consolidated 2025-06-18; refined 2025-11-25). A *protected* server must implement the OAuth 2.1 **resource server** role only:

- `401` + `WWW-Authenticate` header pointing at the resource metadata (header optional since 2025-11-25 / SEP-985, with fallback to the well-known URL)
- Serve `GET /.well-known/oauth-protected-resource` (RFC 9728) listing `authorization_servers`
- Validate tokens **including audience** (RFC 8707 — reject tokens issued for another resource); `403` for insufficient scopes, `400` for malformed
- The authorization server itself is OUT of the MCP spec's scope

**Current state**: zero auth. `src/Transport/MCP.Transport.Http.pas` never reads the `Authorization` header; no 401 path, no well-known route, no bearer settings; CORS open. `SPEC-tls-support.md` explicitly excludes client-cert auth.

**Agreed design for when it's implemented**:

1. Resource-server role ONLY. Do not build an authorization server — point to an **external IdP** (Keycloak, Entra ID, Auth0, ...) configurable by URL.
2. Token validation in two modes: **local JWT** via `mormot.crypt.jwt` (already in the mORMot2 dependency; RFC 9068: JWKS signature + `aud` + `exp` + `scope`) as default, plus an `OnValidateAccessToken` callback so the host decides (RFC 7662 introspection fits there when the IdP doesn't issue JWTs).
3. Settings: `RequireBearerAuth`, issuer list, canonical audience URI, required scopes.
4. Fits the modern 2026-07-28 stateless era naturally: Bearer on every POST, no sessions.
5. **Order: TLS first, OAuth second** — the spec requires HTTPS on all endpoints. Sequence: finish `SPEC-tls-support.md`, then a new `SPEC-oauth-resource-server.md`.

Estimated effort (resource-server side): 1-2 days including tests. Note: a static bearer API key scheme (`Authorization: Bearer key:secret`) only shares the header syntax with this — it is not OAuth (no issuer, no expiry/scopes/audience, no discovery) and does not satisfy the MCP authorization spec.
