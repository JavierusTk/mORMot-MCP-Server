# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This folder contains the two foundational infrastructure units that all other MCP server layers depend on. Nothing in `src/core/` depends on Managers, Tools, Resources, Prompts, or Transports — the dependency arrow points strictly inward.

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

**Consumers**: All managers in `src/Managers/` publish events. `TMCPHttpTransport` subscribes to broadcast them as SSE. `EmitProgress()` is a convenience wrapper for tool implementations to report progress via `MCP_EVENT_PROGRESS`.

## Dependencies

Both units depend only on mORMot2 core units and `MCP.Types` (from `src/Protocol/`). They have no cross-dependency on each other.
