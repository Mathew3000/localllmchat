"""
WebSocket endpoint: /ws?token=<JWT>

Client → Server messages:
  {"type": "ping"}
  {"type": "send_message", "conversation_id": "...", "content": "...", "images": [...],
                           "message_id": "...", "tools": [...]}
  {"type": "tool_result",  "conversation_id": "...", "call_id": "...", "content": "...",
                           "is_error": false}
  {"type": "cancel", "conversation_id": "..."}

Server → Client messages:
  {"type": "pong"}
  {"type": "generation_start",  "conversation_id": "...", "message_id": "..."}
  {"type": "token",             "conversation_id": "...", "message_id": "...", "content": "..."}
  {"type": "tool_call",         "conversation_id": "...", "message_id": "...",
                                "call_id": "...", "name": "...", "arguments": "..."}
  {"type": "message_complete",  "conversation_id": "...", "message": {...}}
  {"type": "cancelled",         "conversation_id": "..."}
  {"type": "error",             "conversation_id": "...", "detail": "..."}
"""

import asyncio
import json
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from jose import JWTError
from sqlalchemy.ext.asyncio import AsyncSession

from auth import decode_token
from database import AsyncSessionLocal
from models import Conversation, Message, User, UserSettings
from services.llm import run_generation
from services.ws_hub import hub

router = APIRouter(tags=["websocket"])


async def _auth(token: str) -> tuple[User, AsyncSession]:
    """Validate JWT and return the user + a fresh DB session."""
    db = AsyncSessionLocal()
    try:
        payload = decode_token(token)
        user_id: str | None = payload.get("sub")
        if not user_id:
            raise ValueError("missing sub")
        user = await db.get(User, user_id)
        if not user:
            raise ValueError("user not found")
        return user, db
    except (JWTError, ValueError):
        await db.close()
        raise


@router.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    token: str = Query(...),
):
    try:
        user, db = await _auth(token)
    except Exception:
        await websocket.close(code=1008)  # Policy violation — bad token
        return

    await hub.connect(user.id, websocket)

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = msg.get("type")

            # ── Ping / keepalive ──────────────────────────────────────────────
            if msg_type == "ping":
                await websocket.send_json({"type": "pong"})

            # ── Send message + trigger generation ─────────────────────────────
            elif msg_type == "send_message":
                conv_id: str | None = msg.get("conversation_id")
                content: str = msg.get("content", "")
                images: list[str] = msg.get("images", [])
                client_msg_id: str | None = msg.get("message_id")
                # OpenAI-format tools array sent by the Flutter client.
                tools: list[dict] = msg.get("tools", [])
                # Optional user-memory context pre-fetched by the client.
                memory_context: str | None = msg.get("memory_context") or None
                # Client's local datetime string (avoids UTC bias on the server).
                client_datetime: str | None = msg.get("client_datetime") or None

                if not conv_id:
                    await websocket.send_json(
                        {"type": "error", "detail": "conversation_id required"}
                    )
                    continue

                conv = await db.get(Conversation, conv_id)
                if conv is None or conv.user_id != user.id:
                    await websocket.send_json(
                        {"type": "error", "detail": "Conversation not found"}
                    )
                    continue

                # Persist the user message
                user_msg = Message(
                    id=client_msg_id or str(uuid.uuid4()),
                    conversation_id=conv_id,
                    role="user",
                    content=content,
                    images=images,
                    created_at=datetime.now(timezone.utc),
                )
                db.add(user_msg)
                conv.updated_at = datetime.now(timezone.utc)
                await db.commit()

                # Load settings for this user
                us = await db.get(UserSettings, user.id)
                settings_data = dict(us.data) if us else {}

                # Cancel any in-flight generation for this conversation
                hub.cancel_task(conv_id)

                # Spawn background generation task with its own DB session
                async def _generate(
                    cid: str = conv_id,
                    uid: str = user.id,
                    s: dict = settings_data,
                    t: list[dict] = tools,
                    mc: str | None = memory_context,
                    cdt: str | None = client_datetime,
                ) -> None:
                    task_db = AsyncSessionLocal()
                    try:
                        await run_generation(
                            task_db, uid, cid, s, tools=t, memory_context=mc,
                            client_datetime=cdt,
                        )
                    finally:
                        await task_db.close()
                        hub.unregister_task(cid)

                task = asyncio.create_task(_generate())
                hub.register_task(conv_id, task, user.id)

            # ── Tool result from client (MCP relay) ───────────────────────────
            elif msg_type == "tool_result":
                call_id: str | None = msg.get("call_id")
                conv_id = msg.get("conversation_id")
                tool_content: str = msg.get("content", "")
                is_error: bool = bool(msg.get("is_error", False))
                if call_id and conv_id:
                    hub.resolve_tool_result(
                        conv_id,
                        call_id,
                        {"content": tool_content, "is_error": is_error},
                    )

            # ── Cancel in-flight generation ───────────────────────────────────
            elif msg_type == "cancel":
                conv_id = msg.get("conversation_id")
                if conv_id:
                    hub.cancel_task(conv_id)
                    await websocket.send_json(
                        {"type": "cancelled", "conversation_id": conv_id}
                    )

    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect(user.id, websocket)
        await db.close()
