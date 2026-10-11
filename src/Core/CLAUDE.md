# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This folder contains the infrastructure units the other MCP server layers depend on: the method registry, the event bus, and the JSON-RPC request processor shared by the `.dpr` and `.lpr` entry points. Only `MCP.RequestProcessor` reaches outward, and only to `MCP.Manager.Resources` (for `EMCPResourceNotFound`); nothing here depends on Tools, Prompts, or Transports.

## Units

### MCP.Manager.Registry.pas — Method Dispatch

`TMCPManagerRegistry` implements `IMCPManagerRegistry` (defined in `MCP.Types`). It holds a flat array of `IMCPCapabilityManager` and dispatches incoming JSON-RPC method strings by iterating managers and calling `HandlesMethod()` on each. First match wins.

**Consumers**: `MCPServer.dpr` creates the registry, registers all managers in order, and passes it to the transport layer. The request processor calls `GetManagerForMethod()` on every incoming request.

**Key constraint**: Managers are checked in registration order. If two managers claim the same method, the first registered wins silently.

### MCP.Events.pas — Notification Event Bus

`TMCPEventBus` is a thread-safe singleton (double-checked locking with `TRTLCriticalSection`). It provides pub/sub for MCP notification routing between managers and transports.

**Access pattern**: `TMCPEventBus.GetInstance` or the `MCPEventBus` helper function.

**Threading model**: Callbacks are collected under the lock, then invoked outside the lock to prevent deadlocks. Exceptions in callbacks are caught and logged, never propagated.

**Pending queue**: When `Publish()` is called with no subscribers for that event type, the event is queued. When a subscriber later calls `Subscribe()`, all pending events for that type are delivered immediately (still under the lock via `DeliverPendingEvents`).

**Standard event constants** (used across Managers and Transport layers):
- `MCP_EVENT_TOOLS_LIST_CHANGED`
- `MCP_EVENT_RESOURCES_LIST_CHANGED`
- `MCP_EVENT_RESOURCES_UPDATED`
- `MCP_EVENT_PROMPTS_LIST_CHANGED`
- `MCP_EVENT_MESSAGE`
- `MCP_EVENT_PROGRESS`
- `MCP_EVENT_CANCELLED`
- `MCP_EVENT_SEND_NOTIFICATION` (`'__internal/send_notification'`) — host passthrough: the stdio transport subscribes and forwards `{method, params}` verbatim, so a host application can emit any server-initiated notification without the framework knowing the method.

**Consumers**: All managers in `src/Managers/` publish events. `TMCPHttpTransport` subscribes to broadcast them as SSE. `EmitProgress()` is a convenience wrapper for tool implementations to report progress via `MCP_EVENT_PROGRESS`.

### MCP.RequestProcessor.pas — JSON-RPC Dispatch and Protocol Eras

`TMCPRequestProcessor` is the JSON-RPC dispatch shared by `MCPServer.dpr` and `MCPServer.lpr` (`HandleRequest` / `HandleRequestEx`). It resolves each request's protocol era (legacy 2024-11-05..2025-11-25: initialize handshake + sessions; modern 2026-07-28+: stateless, per-request `_meta` protocol version), validates modern Streamable-HTTP headers (`ValidateModernHttpRequest`), dispatches through the manager registry, and decorates modern results (`DecorateModernResult`: `resultType`, `serverInfo`, cache hints). `IsMethodRemovedInModern` names the methods the modern era drops.

## Dependencies

`MCP.Manager.Registry` and `MCP.Events` depend only on mORMot2 core units and `MCP.Types` (from `src/Protocol/`), with no cross-dependency on each other. `MCP.RequestProcessor` additionally uses `MCP.Manager.Resources` (for `EMCPResourceNotFound`).
