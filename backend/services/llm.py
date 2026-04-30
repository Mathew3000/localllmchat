"""
LLM generation service.

run_generation() is the core loop:
  1. Loads the conversation history from the DB.
  2. Streams tokens from the configured LLM backend.
  3. Pushes each token to all connected WebSocket clients via the hub.
  4. On completion (or cancellation) saves the full assistant message to the DB.

If the client disconnects mid-stream the task keeps running and stores the
result so the device receives the completed message on next load.
"""

import asyncio
import json
import uuid
from datetime import datetime, timezone

import httpx
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models import Conversation, Message, UserSettings
from services.ws_hub import hub


# ── Helpers ───────────────────────────────────────────────────────────────────

def _dt_string() -> str:
    """Human-readable datetime without platform-specific format codes."""
    now = datetime.now()
    return f"{now.strftime('%A')}, {now.day} {now.strftime('%B %Y, %H:%M')}"


def _build_messages(history: list[Message], settings: dict) -> list[dict]:
    """Convert ORM message list to OpenAI chat/completions payload."""
    messages: list[dict] = []

    system_prompt: str = settings.get("systemPrompt", "")
    if settings.get("injectDateTime"):
        system_prompt += f"\n\nCurrent date and time: {_dt_string()}"
    if system_prompt.strip():
        messages.append({"role": "system", "content": system_prompt.strip()})

    tools_enabled: bool = bool(settings.get("mcpServers"))  # rough heuristic

    for msg in history:
        if msg.role == "system":
            continue

        # Skip tool-related messages when tools are not enabled
        if not tools_enabled and (msg.tool_calls or msg.tool_call_id):
            continue

        m: dict = {"role": msg.role}

        if msg.tool_calls:
            # Assistant message that triggered tool calls
            m["content"] = msg.content or None
            m["tool_calls"] = msg.tool_calls
        elif msg.tool_call_id:
            # Tool result message
            m["role"] = "tool"
            m["tool_call_id"] = msg.tool_call_id
            m["content"] = msg.content
        elif msg.images and msg.role == "user":
            # Multimodal user message
            content: list[dict] = [
                {"type": "image_url", "image_url": {"url": img}}
                for img in msg.images
            ]
            if msg.content:
                content.append({"type": "text", "text": msg.content})
            m["content"] = content
        else:
            m["content"] = msg.content

        messages.append(m)

    return messages


# ── Core generation loop ──────────────────────────────────────────────────────

async def run_generation(
    db: AsyncSession,
    user_id: str,
    conversation_id: str,
    settings: dict,
) -> None:
    """
    Background task: stream LLM response and persist the result.
    Designed to survive client disconnects — the task runs to completion
    regardless of WebSocket state.
    """
    assistant_msg: Message | None = None
    content_buf: list[str] = []
    in_thinking = False
    thinking_closed = False

    async def _send(data: dict) -> None:
        """Fire-and-forget send; silently swallows send errors."""
        try:
            await hub.send(user_id, data)
        except Exception:
            pass

    try:
        # ── Load conversation ─────────────────────────────────────────────────
        conv = await db.get(Conversation, conversation_id)
        if conv is None or conv.user_id != user_id:
            await _send({
                "type": "error",
                "conversation_id": conversation_id,
                "detail": "Conversation not found",
            })
            return

        result = await db.execute(
            select(Message)
            .where(Message.conversation_id == conversation_id)
            .order_by(Message.created_at)
        )
        history = list(result.scalars().all())

        # ── Build request ─────────────────────────────────────────────────────
        base_url = settings.get("baseUrl", "http://localhost:11434/v1").rstrip("/")
        model = settings.get("selectedModel", "")
        temperature = float(settings.get("temperature", 0.7))
        max_tokens = int(settings.get("maxTokens", 4096))
        api_key = settings.get("apiKey", "")

        headers: dict[str, str] = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        payload = {
            "model": model,
            "messages": _build_messages(history, settings),
            "stream": True,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }

        # ── Create placeholder assistant message ──────────────────────────────
        assistant_msg = Message(
            id=str(uuid.uuid4()),
            conversation_id=conversation_id,
            role="assistant",
            content="",
            created_at=datetime.now(timezone.utc),
        )
        db.add(assistant_msg)
        await db.commit()

        # Notify client a new message slot exists so it can show a typing indicator
        await _send({
            "type": "generation_start",
            "conversation_id": conversation_id,
            "message_id": assistant_msg.id,
        })

        # ── Stream from LLM ───────────────────────────────────────────────────
        async with httpx.AsyncClient(timeout=httpx.Timeout(None)) as client:
            async with client.stream(
                "POST",
                f"{base_url}/chat/completions",
                headers=headers,
                json=payload,
            ) as resp:
                if resp.status_code != 200:
                    body = await resp.aread()
                    await _send({
                        "type": "error",
                        "conversation_id": conversation_id,
                        "detail": f"LLM error {resp.status_code}: {body.decode()}",
                    })
                    await db.delete(assistant_msg)
                    await db.commit()
                    assistant_msg = None
                    return

                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line[6:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        choices = chunk.get("choices", [])
                        if not choices:
                            continue
                        delta = choices[0].get("delta", {})

                        # Thinking tokens (Qwen3 / reasoning models)
                        reasoning = delta.get("reasoning_content")
                        if reasoning:
                            if not in_thinking:
                                tok = "<think>"
                                content_buf.append(tok)
                                await _send({
                                    "type": "token",
                                    "conversation_id": conversation_id,
                                    "message_id": assistant_msg.id,
                                    "content": tok,
                                })
                                in_thinking = True
                            content_buf.append(reasoning)
                            await _send({
                                "type": "token",
                                "conversation_id": conversation_id,
                                "message_id": assistant_msg.id,
                                "content": reasoning,
                            })

                        # Regular content
                        content = delta.get("content")
                        if content:
                            if in_thinking and not thinking_closed:
                                tok = "</think>"
                                content_buf.append(tok)
                                await _send({
                                    "type": "token",
                                    "conversation_id": conversation_id,
                                    "message_id": assistant_msg.id,
                                    "content": tok,
                                })
                                thinking_closed = True
                            content_buf.append(content)
                            await _send({
                                "type": "token",
                                "conversation_id": conversation_id,
                                "message_id": assistant_msg.id,
                                "content": content,
                            })
                    except Exception:
                        pass  # malformed SSE chunk — skip

        # Close any still-open think block
        if in_thinking and not thinking_closed:
            tok = "</think>"
            content_buf.append(tok)
            await _send({
                "type": "token",
                "conversation_id": conversation_id,
                "message_id": assistant_msg.id,
                "content": tok,
            })

        # ── Persist final message ─────────────────────────────────────────────
        final_content = "".join(content_buf)
        assistant_msg.content = final_content
        conv.updated_at = datetime.now(timezone.utc)
        await db.commit()

        await _send({
            "type": "message_complete",
            "conversation_id": conversation_id,
            "message": {
                "id": assistant_msg.id,
                "role": "assistant",
                "content": final_content,
                "images": [],
                "created_at": assistant_msg.created_at.isoformat(),
            },
        })

    except asyncio.CancelledError:
        # Save whatever was streamed so far
        if assistant_msg is not None and content_buf:
            partial = "".join(content_buf)
            if in_thinking and not thinking_closed:
                partial += "</think>"
            try:
                assistant_msg.content = partial
                conv = await db.get(Conversation, conversation_id)
                if conv:
                    conv.updated_at = datetime.now(timezone.utc)
                await db.commit()
            except Exception:
                pass
        raise

    except Exception as e:
        await _send({
            "type": "error",
            "conversation_id": conversation_id,
            "detail": str(e),
        })
        # Clean up the empty placeholder if we never got any content
        if assistant_msg is not None and not content_buf:
            try:
                await db.delete(assistant_msg)
                await db.commit()
            except Exception:
                pass
