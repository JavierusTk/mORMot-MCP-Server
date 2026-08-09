# Changelog

## Unreleased

### Added (MCP 2026-07-28)
- **MCP specification 2026-07-28 support** (latest revision), keeping full
  backward compatibility with initialize-based clients (2024-11-05 through
  2025-11-25). The server implements a dual-era model, resolved per request
  from `_meta['io.modelcontextprotocol/protocolVersion']` (and the
  `MCP-Protocol-Version` header on HTTP):
  - `server/discover` RPC advertising supported versions, capabilities and
    instructions (answered for any requested version, so clients can probe).
  - Stateless modern era: no `initialize` handshake, no sessions; every
    modern result carries the required `resultType` field, the server
    identity in `_meta['io.modelcontextprotocol/serverInfo']`, and the
    `CacheableResult` hints (`ttlMs`, `cacheScope`) on `tools/list`,
    `prompts/list`, `resources/list`, `resources/templates/list`,
    `resources/read` and `server/discover` (SEP-2549).
  - `subscriptions/listen` on both transports, replacing the HTTP GET stream
    and `resources/subscribe`/`unsubscribe` for modern clients: opt-in
    filters (`toolsListChanged`, `promptsListChanged`, `resourcesListChanged`,
    `resourceSubscriptions`), `notifications/subscriptions/acknowledged` as
    first stream message, notifications tagged with
    `_meta['io.modelcontextprotocol/subscriptionId']`, graceful-teardown
    final response, and client-side cancel via `notifications/cancelled` on
    stdio.
  - Streamable HTTP request-metadata validation (SEP-2243): required
    `MCP-Protocol-Version`, `Mcp-Method` and (for `tools/call`,
    `prompts/get`, `resources/read`) `Mcp-Name` headers matched against the
    body, including the `=?base64?...?=` sentinel encoding; failures return
    `400` + `HeaderMismatch` (-32020).
  - Spec error codes: `-32020` HeaderMismatch, `-32021`
    MissingRequiredClientCapability, `-32022` UnsupportedProtocolVersion
    (returned with `{supported, requested}` data and HTTP 400); unknown
    methods return HTTP 404; resource-not-found maps to `-32602` for modern
    clients (legacy clients keep `-32002`).
  - Modern GET/DELETE requests are rejected with `405` (sessions and the GET
    stream no longer exist in 2026-07-28); legacy clients keep the previous
    behavior of their negotiated revision.
  - Methods removed by 2026-07-28 (`initialize`, `ping`, `logging/setLevel`,
    `resources/subscribe`, `resources/unsubscribe`) stay available to legacy
    clients but return method-not-found to modern ones.
- New shared unit `src/Core/MCP.RequestProcessor.pas`: the JSON-RPC dispatch
  previously duplicated in `MCPServer.dpr` and `MCPServer.lpr`, extracted and
  extended with the era logic (`TMCPRequestContext`, `HandleRequestEx`).
- Legacy HTTP GET SSE streams are now actually registered for event-bus
  broadcast (the connection tracking existed but was never wired), and the
  stdio transport now forwards `notifications/resources/updated`.

### Changed
- `MCP_PROTOCOL_VERSION` is now `2026-07-28`; supported versions:
  `2026-07-28, 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05`.
- An unsupported `MCP-Protocol-Version` header now returns HTTP 400 with the
  spec error `-32022` (was HTTP 200 with a generic `-32000` error).
- JSON-RPC notifications no longer produce a spurious `{"jsonrpc":"2.0"}`
  response line (notifications must never be answered).
- `--port=N` (equals form, as documented in the README) is now parsed; only
  `--port N` and the bare-number form worked before.

### Fixed
- The stdio transport now decodes stdin as UTF-8 and writes `RawUtf8` bytes
  directly to stdout. Previously the Windows console code page could corrupt
  incoming Unicode and emit invalid JSONL bytes such as CP1252 `$97`.

### Added
- **TLS/HTTPS support** for HTTP transport
  - `--tls` flag to enable TLS with certificate files
  - `--cert=path` and `--key=path` to specify certificate and private key
  - `--key-password=pass` for encrypted private keys
  - `--tls-self-signed` for zero-config development HTTPS (auto-generated certificate)
  - Console and log output reflect `https://` when TLS is active
  - Uses mORMot2's native TLS support (SChannel on Windows, OpenSSL on Linux)
