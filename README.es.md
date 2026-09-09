# mORMot2 MCP Server

[🇬🇧 Read in English](README.md)

Implementación de alto rendimiento del [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) usando el framework [mORMot2](https://github.com/synopse/mORMot2).

**Implementa la especificación MCP 2026-07-28** (modelo sin estado por petición, `server/discover`, `subscriptions/listen`) con compatibilidad completa hacia atrás con clientes basados en initialize (2024-11-05 a 2025-11-25) y notificaciones bidireccionales vía SSE.

## Características

### Core
- **Implementación pura mORMot2** - Sin dependencias externas más allá de mORMot2
- **Soporte dual de transporte** - stdio y HTTP con SSE
- **JSON-RPC 2.0** - Soporte completo del protocolo usando `TDocVariant`
- **Arquitectura modular** - Fácil de extender con tools, resources y prompts personalizados
- **Multiplataforma** - Compila con Delphi y Free Pascal

### Capacidades MCP
- **Tools** - Registra tools personalizados con validación JSON Schema y notificaciones `listChanged`
- **Resources** - List, read, templates y subscriptions con acceso basado en URI
- **Prompts** - List y get con múltiples tipos de contenido (text, image, audio, resource)
- **Logging** - Método `setLevel` con niveles de log RFC 5424
- **Completion** - Auto-completado de argumentos para prompts y resources

### Capa de Transporte
- **Transporte stdio** - JSON-RPC delimitado por newline, logs a stderr
- **Transporte HTTP** - API REST con Server-Sent Events (SSE) y soporte CORS
- **Gestión de sesiones** - IDs de sesión criptográficos (128-bit)
- **Notificaciones SSE** - Comunicación bidireccional en tiempo real
- **Keepalive** - SSE keepalive configurable (por defecto 30s)
- **Graceful shutdown** - Manejo de SIGTERM/SIGINT con timeout de 5s
- **Event bus** - Pub/sub thread-safe para enrutamiento interno de notificaciones

### Notificaciones
- `notifications/tools/list_changed` - Cambios en registro de tools
- `notifications/resources/list_changed` - Cambios en resources
- `notifications/resources/updated` - Actualizaciones de resources suscritos
- `notifications/prompts/list_changed` - Cambios en prompts
- `notifications/message` - Mensajes de log
- `notifications/progress` - Actualizaciones de progreso
- `notifications/cancelled` - Cancelación de requests

## Requisitos

- Framework [mORMot2](https://github.com/synopse/mORMot2)
- Delphi 10.3+ (probado) o Free Pascal 3.2+ (no probado aún)

## Estructura del Proyecto

```
mORMot-MCP-Server/
├── MCPServer.dpr           # Proyecto Delphi
├── MCPServer.lpr           # Proyecto Free Pascal
├── MCPServer.lpi           # Proyecto Lazarus
├── src/
│   ├── Core/
│   │   ├── MCP.Manager.Registry.pas   # Registro de managers
│   │   └── MCP.Events.pas             # Event bus (pub/sub)
│   ├── Protocol/
│   │   └── MCP.Types.pas              # Tipos y configuración
│   ├── Transport/
│   │   ├── MCP.Transport.Base.pas     # Abstracción de transporte
│   │   ├── MCP.Transport.Stdio.pas    # Transporte stdio
│   │   └── MCP.Transport.Http.pas     # Transporte HTTP + SSE
│   ├── Server/
│   │   └── MCP.Server.pas             # Servidor HTTP legacy
│   ├── Managers/
│   │   ├── MCP.Manager.Core.pas       # initialize, ping
│   │   ├── MCP.Manager.Tools.pas      # tools/list, tools/call
│   │   ├── MCP.Manager.Resources.pas  # resources/*, subscriptions
│   │   ├── MCP.Manager.Prompts.pas    # prompts/list, prompts/get
│   │   ├── MCP.Manager.Logging.pas    # logging/setLevel
│   │   └── MCP.Manager.Completion.pas # completion/complete
│   ├── Tools/
│   │   ├── MCP.Tool.Base.pas          # Clase base de tool
│   │   ├── MCP.Tool.Echo.pas          # Ejemplo Echo
│   │   └── MCP.Tool.GetTime.pas       # Ejemplo GetTime
│   ├── Resources/
│   │   └── MCP.Resource.Base.pas      # Clase base de resource
│   └── Prompts/
│       └── MCP.Prompt.Base.pas        # Clase base de prompt
```

## Compilación

### Con Delphi

Abre `MCPServer.dproj` en el IDE de Delphi. Asegúrate de que las rutas de mORMot2 estén configuradas.

```bash
# O desde línea de comandos
msbuild MCPServer.dproj /p:Config=Release /p:Platform=Win64
```

### Con Free Pascal / Lazarus

```bash
lazbuild MCPServer.lpi
```

## Uso

### Transporte stdio (para Claude Desktop)

```bash
MCPServer.exe --transport=stdio
```

Configura en Claude Desktop (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "mormot-server": {
      "command": "C:\\ruta\\a\\MCPServer.exe",
      "args": ["--transport=stdio"]
    }
  }
}
```

### Transporte HTTP (para clientes web)

```bash
# Puerto por defecto 3000
MCPServer.exe --transport=http

# Puerto personalizado
MCPServer.exe --transport=http --port=8080
```

### Conexión SSE

```bash
# Abrir stream SSE para notificaciones
curl -N -H "Accept: text/event-stream" http://localhost:3000/mcp
```

## Ejemplos de API

### Petición sin estado (2026-07-28, sin handshake)

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/list" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list",
    "params": {
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
```

Usa `server/discover` (misma forma, `Mcp-Method: server/discover`) para
obtener por adelantado las versiones soportadas y las capabilities.

### Inicializar Sesión

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

### Listar Tools

```bash
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### Llamar Tool

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
      "arguments": {"message": "¡Hola, Mundo!"}
    }
  }'
```

## Añadir Tools Personalizados

```pascal
unit MCP.Tool.MiTool;

{$I mormot.defines.inc}

interface

uses
  mormot.core.base,
  mormot.core.variants,
  MCP.Tool.Base;

type
  TMCPToolMiTool = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

constructor TMCPToolMiTool.Create;
begin
  inherited;
  fName := 'mi_tool';
  fDescription := 'Mi tool personalizado';
end;

function TMCPToolMiTool.BuildInputSchema: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
  // Añadir propiedades...
end;

function TMCPToolMiTool.Execute(const Arguments: Variant): Variant;
begin
  // Retornar éxito
  Result := ToolResultText('¡Hecho!');

  // O retornar error
  // Result := ToolResultText('Mensaje de error', True);
end;

end.
```

Registrar en `MCPServer.dpr`:
```pascal
ToolsManager.RegisterTool(TMCPToolMiTool.Create);
```

## Configuración

Configuración en `MCP.Types.pas`:

```pascal
Settings.ServerName := 'mORMot-MCP-Server';
Settings.ServerVersion := '1.0.0';
Settings.Port := 3000;
Settings.Host := '0.0.0.0';
Settings.Endpoint := '/mcp';
Settings.SSEKeepaliveIntervalMs := 30000;  // 30 segundos
```

## Rendimiento

| Aspecto | mORMot2 MCP Server |
|---------|-------------------|
| Servidor HTTP | `THttpAsyncServer` (async I/O) |
| JSON | `TDocVariant` (zero-copy) |
| Memoria | Asignación mínima |
| Threading | Pool de threads |
| SSE | Implementación nativa |

## Licencia

Licencia MIT - Ver archivo [LICENSE](LICENSE).

## Ver También

- [Documentación mORMot2](https://synopse.info/files/doc/mORMot2.html)
- [Especificación MCP](https://spec.modelcontextprotocol.io/)
- [MCP Protocol Version 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28)
