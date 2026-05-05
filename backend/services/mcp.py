"""
Async MCP client for the LoomChat backend.

Supports two transports:
  • Streamable-HTTP  (POST /mcp, Mcp-Session-Id header)  — modern default
  • HTTP+SSE         (GET /sse persistent stream + POST to session endpoint)

Use ``build_mcp_client()`` to get an auto-detecting client.
"""
import asyncio
import json
from dataclasses import dataclass, field
from typing import Any

import httpx


@dataclass
class McpTool:
    name: str
    description: str = ""
    input_schema: dict = field(default_factory=dict)

    def to_openai(self) -> dict:
        """Return an OpenAI-format function tool definition."""
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.input_schema or {
                    "type": "object",
                    "properties": {},
                },
            },
        }


class McpHttpError(Exception):
    def __init__(self, status_code: int, message: str = ""):
        self.status_code = status_code
        super().__init__(f"MCP HTTP {status_code}: {message}")


# ── Content helpers ───────────────────────────────────────────────────────────

def _parse_tools(result: Any) -> list[McpTool]:
    if not isinstance(result, dict):
        return []
    return [
        McpTool(
            name=t["name"],
            description=t.get("description", ""),
            input_schema=t.get("inputSchema") or {},
        )
        for t in result.get("tools", [])
    ]


def _parse_content(result: Any) -> str:
    """Convert a tools/call result to plain text."""
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    content = result.get("content") if isinstance(result, dict) else []
    if not content:
        return json.dumps(result) if result else ""
    parts: list[str] = []
    for item in content:
        t = item.get("type", "")
        if t == "text":
            parts.append(item.get("text", ""))
        elif t == "resource":
            r = item.get("resource", {})
            parts.append(r.get("text") or json.dumps(r))
        else:
            parts.append(json.dumps(item))
    return "\n".join(parts)


# ── Streamable-HTTP transport ─────────────────────────────────────────────────

class StreamableHttpClient:
    """MCP client using the Streamable-HTTP transport (POST /mcp)."""

    def __init__(self, base_url: str, extra_headers: dict[str, str] | None = None):
        base = base_url.rstrip("/")
        self._endpoint = base if base.endswith("/mcp") else f"{base}/mcp"
        self._extra: dict[str, str] = extra_headers or {}
        self._session_id: str | None = None

    def _headers(self) -> dict[str, str]:
        h: dict[str, str] = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            **self._extra,
        }
        if self._session_id:
            h["Mcp-Session-Id"] = self._session_id
        return h

    async def _ensure_session(self, client: httpx.AsyncClient) -> None:
        if self._session_id:
            return
        resp = await client.post(
            self._endpoint,
            headers=self._headers(),
            json={
                "jsonrpc": "2.0",
                "id": 0,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "LoomChat", "version": "1.0"},
                },
            },
            timeout=15,
        )
        if resp.status_code in (404, 405):
            raise McpHttpError(resp.status_code, "not a Streamable-HTTP endpoint")
        resp.raise_for_status()
        self._session_id = resp.headers.get("mcp-session-id")
        try:
            await client.post(
                self._endpoint,
                headers=self._headers(),
                json={"jsonrpc": "2.0", "method": "notifications/initialized"},
                timeout=5,
            )
        except Exception:
            pass

    async def _rpc(self, client: httpx.AsyncClient, method: str, params: dict) -> Any:
        await self._ensure_session(client)
        resp = await client.post(
            self._endpoint,
            headers=self._headers(),
            json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
            timeout=httpx.Timeout(connect=10, read=60, write=10, pool=5),
        )
        # Session expired — reset and retry once.
        if resp.status_code == 400 and "session" in resp.text.lower():
            self._session_id = None
            await self._ensure_session(client)
            return await self._rpc(client, method, params)
        resp.raise_for_status()
        text = resp.text
        if "text/event-stream" in resp.headers.get("content-type", ""):
            for line in text.split("\n"):
                line = line.strip()
                if line.startswith("data:") and len(line) > 5:
                    text = line[5:].strip()
                    break
        data = json.loads(text)
        if data.get("error"):
            raise Exception(f"MCP JSON-RPC error: {data['error']}")
        return data.get("result")

    async def list_tools(self) -> list[McpTool]:
        async with httpx.AsyncClient() as client:
            result = await self._rpc(client, "tools/list", {})
        return _parse_tools(result)

    async def call_tool(self, name: str, arguments: dict) -> str:
        async with httpx.AsyncClient() as client:
            result = await self._rpc(
                client, "tools/call", {"name": name, "arguments": arguments}
            )
        return _parse_content(result)


# ── HTTP+SSE transport ────────────────────────────────────────────────────────

class SseClient:
    """
    MCP client using the HTTP+SSE transport.

    Each ``list_tools`` / ``call_tool`` call opens a fresh SSE connection,
    performs initialize + the RPC, then tears it down.  This is stateless
    (no persistent connection maintained between calls) which keeps the
    implementation simple and avoids background tasks.
    """

    def __init__(self, base_url: str, extra_headers: dict[str, str] | None = None):
        base = base_url.rstrip("/")
        self._sse_url = base if base.endswith("/sse") else f"{base}/sse"
        self._base_url = base
        self._extra: dict[str, str] = extra_headers or {}

    def _resolve(self, path: str) -> str:
        if path.startswith("http://") or path.startswith("https://"):
            return path
        return f"{self._base_url}/{path.lstrip('/')}"

    async def _rpc(self, method: str, params: dict) -> Any:
        """Open a fresh SSE session, do initialize + one RPC call, return result."""
        loop = asyncio.get_event_loop()
        endpoint_future: asyncio.Future[str] = loop.create_future()
        init_future: asyncio.Future[Any] = loop.create_future()
        result_future: asyncio.Future[Any] = loop.create_future()
        id_to_future: dict[int, asyncio.Future] = {
            1: init_future,
            2: result_future,
        }

        async def sse_reader() -> None:
            async with httpx.AsyncClient() as cli:
                async with cli.stream(
                    "GET",
                    self._sse_url,
                    headers={
                        "Accept": "text/event-stream",
                        "Cache-Control": "no-cache",
                        **self._extra,
                    },
                    timeout=httpx.Timeout(connect=10, read=120, write=10, pool=5),
                ) as resp:
                    if resp.status_code != 200:
                        exc = McpHttpError(resp.status_code, "SSE connect failed")
                        if not endpoint_future.done():
                            endpoint_future.set_exception(exc)
                        return
                    event_type = ""
                    async for line in resp.aiter_lines():
                        line = line.strip()
                        if line.startswith("event:"):
                            event_type = line[6:].strip()
                        elif line.startswith("data:"):
                            data_str = line[5:].strip()
                            if event_type == "endpoint" and not endpoint_future.done():
                                endpoint_future.set_result(data_str)
                            elif event_type in ("message", ""):
                                try:
                                    msg = json.loads(data_str)
                                    fid = msg.get("id")
                                    if isinstance(fid, int) and fid in id_to_future:
                                        fut = id_to_future[fid]
                                        if not fut.done():
                                            if msg.get("error"):
                                                fut.set_exception(
                                                    Exception(f"MCP: {msg['error']}")
                                                )
                                            else:
                                                fut.set_result(msg.get("result"))
                                except Exception:
                                    pass
                            event_type = ""
                            if result_future.done():
                                return  # all done — exit reader

        reader_task = asyncio.create_task(sse_reader())
        try:
            ep_raw = await asyncio.wait_for(endpoint_future, timeout=10)
            post_url = self._resolve(ep_raw)
            post_h = {"Content-Type": "application/json", **self._extra}

            async with httpx.AsyncClient() as cli:
                # 1. Initialize
                await cli.post(
                    post_url,
                    headers=post_h,
                    json={
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "clientInfo": {"name": "LoomChat", "version": "1.0"},
                        },
                    },
                    timeout=10,
                )
                await asyncio.wait_for(init_future, timeout=10)

                # 2. notifications/initialized (fire-and-forget)
                asyncio.create_task(
                    cli.post(
                        post_url,
                        headers=post_h,
                        json={"jsonrpc": "2.0", "method": "notifications/initialized"},
                    )
                )

                # 3. Actual RPC
                await cli.post(
                    post_url,
                    headers=post_h,
                    json={
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": method,
                        "params": params,
                    },
                    timeout=10,
                )

            return await asyncio.wait_for(result_future, timeout=60)
        finally:
            reader_task.cancel()
            try:
                await reader_task
            except (asyncio.CancelledError, Exception):
                pass

    async def list_tools(self) -> list[McpTool]:
        result = await self._rpc("tools/list", {})
        return _parse_tools(result)

    async def call_tool(self, name: str, arguments: dict) -> str:
        result = await self._rpc("tools/call", {"name": name, "arguments": arguments})
        return _parse_content(result)


# ── Factory ───────────────────────────────────────────────────────────────────

AnyMcpClient = StreamableHttpClient | SseClient


async def build_mcp_client(
    base_url: str,
    extra_headers: dict[str, str] | None = None,
    transport: str = "auto",
) -> AnyMcpClient:
    """
    Return an MCP client for *base_url*.

    transport: 'auto' | 'streamableHttp' | 'sse'
      • auto         — try Streamable-HTTP first; fall back to SSE on 404/405.
      • streamableHttp — always use Streamable-HTTP.
      • sse          — always use HTTP+SSE.
    """
    if transport == "sse":
        return SseClient(base_url, extra_headers)
    if transport == "streamableHttp":
        return StreamableHttpClient(base_url, extra_headers)
    # auto: probe Streamable-HTTP first
    try:
        client: StreamableHttpClient = StreamableHttpClient(base_url, extra_headers)
        await client.list_tools()  # triggers session handshake — raises McpHttpError on 404/405
        return client
    except McpHttpError as e:
        if e.status_code in (404, 405):
            return SseClient(base_url, extra_headers)
        raise
    except httpx.HTTPStatusError as e:
        if e.response.status_code in (404, 405):
            return SseClient(base_url, extra_headers)
        raise


# ── Settings helpers ──────────────────────────────────────────────────────────

async def load_tools_from_settings(
    settings: dict,
) -> tuple[list[dict], dict[str, AnyMcpClient]]:
    """
    Read mcpServers from the stored settings blob, connect to each enabled
    server, and collect OpenAI-format tool definitions.

    Returns:
        (openai_tools, tool_clients)
        openai_tools  — list of OpenAI "function" tool dicts to pass to the LLM.
        tool_clients  — {tool_name: MCP client} for server-side tool execution.
    """
    servers: list[dict] = settings.get("mcpServers", [])
    openai_tools: list[dict] = []
    tool_clients: dict[str, AnyMcpClient] = {}

    for server in servers:
        if not server.get("enabled", True):
            continue
        url: str = server.get("baseUrlHome", "").strip()
        if not url:
            continue
        transport: str = server.get("transport", "auto")
        extra_headers: dict[str, str] = server.get("headers") or {}

        try:
            client = await build_mcp_client(url, extra_headers, transport)
            tools = await client.list_tools()
            for tool in tools:
                openai_tools.append(tool.to_openai())
                tool_clients[tool.name] = client
        except Exception:
            pass  # unreachable server — silently skip

    return openai_tools, tool_clients


async def fetch_memory_context(settings: dict) -> str | None:
    """
    If a memory MCP server is configured, call search_nodes("user") on it
    and return the result string.  Returns None on any failure or if no
    memory server is configured.
    """
    servers: list[dict] = settings.get("mcpServers", [])
    memory_server = next(
        (s for s in servers if s.get("isMemory") and s.get("enabled", True)),
        None,
    )
    if not memory_server:
        return None

    url: str = memory_server.get("baseUrlHome", "").strip()
    if not url:
        return None

    try:
        client = await build_mcp_client(
            url,
            memory_server.get("headers") or {},
            memory_server.get("transport", "auto"),
        )
        result = await client.call_tool("search_nodes", {"query": "user"})
        return result.strip() or None
    except Exception:
        return None
