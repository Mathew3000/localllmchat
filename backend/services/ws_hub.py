"""
WebSocket connection hub.

Manages all active WebSocket connections keyed by user_id, and tracks
background generation tasks keyed by conversation_id.

If a device disconnects mid-generation the task keeps running and stores
the result to the DB. When the device reconnects and asks for the
conversation it will receive the completed message.
"""

import asyncio
from collections import defaultdict

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        # user_id -> set of live WebSocket connections (multi-device)
        self._connections: dict[str, set[WebSocket]] = defaultdict(set)
        # conversation_id -> background asyncio.Task
        self._tasks: dict[str, asyncio.Task] = {}
        # "conv_id:call_id" -> asyncio.Future[dict]  (tool-result relay)
        self._tool_futures: dict[str, "asyncio.Future[dict]"] = {}

    # ── Connection lifecycle ──────────────────────────────────────────────────

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        await ws.accept()
        self._connections[user_id].add(ws)

    def disconnect(self, user_id: str, ws: WebSocket) -> None:
        self._connections[user_id].discard(ws)

    # ── Broadcast to all devices for a user ──────────────────────────────────

    async def send(self, user_id: str, data: dict) -> None:
        """Send JSON to every active connection for this user."""
        dead: set[WebSocket] = set()
        for ws in list(self._connections.get(user_id, set())):
            try:
                await ws.send_json(data)
            except Exception:
                dead.add(ws)
        self._connections[user_id] -= dead

    # ── Generation task lifecycle ─────────────────────────────────────────────

    def register_task(self, conversation_id: str, task: asyncio.Task) -> None:
        self._tasks[conversation_id] = task

    def unregister_task(self, conversation_id: str) -> None:
        self._tasks.pop(conversation_id, None)

    def cancel_task(self, conversation_id: str) -> None:
        task = self._tasks.pop(conversation_id, None)
        if task and not task.done():
            task.cancel()
        self.cancel_tool_futures(conversation_id)

    def is_generating(self, conversation_id: str) -> bool:
        task = self._tasks.get(conversation_id)
        return task is not None and not task.done()

    # ── Tool-result relay ─────────────────────────────────────────────────────

    def create_tool_result_future(
        self, conv_id: str, call_id: str
    ) -> "asyncio.Future[dict]":
        """Register a future that resolves when the client returns a tool result."""
        key = f"{conv_id}:{call_id}"
        loop = asyncio.get_event_loop()
        fut: asyncio.Future[dict] = loop.create_future()
        self._tool_futures[key] = fut
        return fut

    def resolve_tool_result(self, conv_id: str, call_id: str, result: dict) -> None:
        """Called by the WS router when the client sends a tool_result message."""
        key = f"{conv_id}:{call_id}"
        fut = self._tool_futures.pop(key, None)
        if fut and not fut.done():
            fut.set_result(result)

    def cancel_tool_futures(self, conv_id: str) -> None:
        """Cancel all pending tool futures for a conversation (on cancel / error)."""
        prefix = f"{conv_id}:"
        keys = [k for k in list(self._tool_futures) if k.startswith(prefix)]
        for key in keys:
            fut = self._tool_futures.pop(key, None)
            if fut and not fut.done():
                fut.cancel()


# Module-level singleton shared across all routers / services.
hub = ConnectionManager()
