"""
LLM generation service.

run_generation() is the core loop:
  1. Loads the conversation history from the DB.
  2. Streams tokens from the configured LLM backend.
  3. Pushes each token to all connected WebSocket clients via the hub.
  4. If the LLM requests tool calls, sends tool_call events to the Flutter
     client, waits for tool_result responses (via the hub relay), persists the
     tool messages, then iterates back to step 1.
  5. On completion (or cancellation) saves the full assistant message to the DB.

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


def _build_messages(
    history: list[Message],
    settings: dict,
    tools_enabled: bool | None = None,
) -> list[dict]:
    """Convert ORM message list to OpenAI chat/completions payload."""
    messages: list[dict] = []

    system_prompt: str = settings.get("systemPrompt", "")
    if settings.get("injectDateTime"):
        system_prompt += f"\n\nCurrent date and time: {_dt_string()}"
    if system_prompt.strip():
        messages.append({"role": "system", "content": system_prompt.strip()})

    # When tools_enabled is not explicitly supplied, fall back to the old
    # heuristic (mcpServers configured in settings).
    if tools_enabled is None:
        tools_enabled = bool(settings.get("mcpServers"))

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
    tools: list[dict] | None = None,
) -> None:
    """
    Background task: stream LLM response and persist the result.
    Designed to survive client disconnects — the task runs to completion
    regardless of WebSocket state.

    When `tools` is non-empty the function implements a tool-call relay loop:
    the LLM may request tool calls which are forwarded to the Flutter client
    for execution; results flow back via the WebSocket hub and the loop
    continues until the LLM produces a final text response.
    """
    MAX_TOOL_ITERATIONS = 10

    # Track for CancelledError / Exception handlers
    assistant_msg: Message | None = None
    content_buf: list[str] = []
    in_thinking = False
    thinking_closed = False
    conv: Conversation | None = None

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

        # ── Build LLM config ──────────────────────────────────────────────────
        # The app syncs the LLM endpoint as "baseUrlHome" (Away URL is irrelevant
        # for the backend — it lives on the same network as the LLM server).
        # Fall back to legacy "baseUrl" key for older settings payloads.
        base_url = (
            settings.get("baseUrlHome")
            or settings.get("baseUrl")
            or "http://localhost:11434/v1"
        ).rstrip("/")
        model = settings.get("selectedModel", "")
        temperature = float(settings.get("temperature", 0.7))
        max_tokens = int(settings.get("maxTokens", 4096))
        api_key = settings.get("apiKey", "")

        headers: dict[str, str] = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

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

        # ── Tool-call agentic loop ────────────────────────────────────────────
        for _iteration in range(MAX_TOOL_ITERATIONS):
            content_buf = []
            tool_call_accum: dict[int, dict] = {}
            in_thinking = False
            thinking_closed = False

            # Load current history, excluding the empty placeholder
            result = await db.execute(
                select(Message)
                .where(Message.conversation_id == conversation_id)
                .where(Message.id != assistant_msg.id)
                .order_by(Message.created_at)
            )
            history = list(result.scalars().all())

            payload: dict = {
                "model": model,
                "messages": _build_messages(
                    history, settings, tools_enabled=bool(tools)
                ),
                "stream": True,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
            if tools:
                payload["tools"] = tools
                payload["tool_choice"] = "auto"

            # ── Stream from LLM ───────────────────────────────────────────────
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

                            # Accumulate tool call deltas (OpenAI streaming format)
                            for tc in delta.get("tool_calls", []):
                                idx = tc.get("index", 0)
                                if idx not in tool_call_accum:
                                    tool_call_accum[idx] = {
                                        "id": "",
                                        "name": "",
                                        "arguments": "",
                                    }
                                if tc.get("id"):
                                    tool_call_accum[idx]["id"] = tc["id"]
                                fn = tc.get("function", {})
                                if fn.get("name"):
                                    tool_call_accum[idx]["name"] += fn["name"]
                                if fn.get("arguments"):
                                    tool_call_accum[idx]["arguments"] += fn["arguments"]

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

            # ── Handle tool calls ─────────────────────────────────────────────
            if tool_call_accum and tools:
                # Build tool_calls in canonical OpenAI format, ordered by index
                tool_calls_list = [
                    {
                        "id": tool_call_accum[i]["id"],
                        "type": "function",
                        "function": {
                            "name": tool_call_accum[i]["name"],
                            "arguments": tool_call_accum[i]["arguments"],
                        },
                    }
                    for i in sorted(tool_call_accum.keys())
                ]

                # Persist assistant message with tool_calls (and any thinking content)
                assistant_msg.content = "".join(content_buf)
                assistant_msg.tool_calls = tool_calls_list
                conv.updated_at = datetime.now(timezone.utc)
                await db.commit()

                # Register futures for ALL tool calls BEFORE sending any events
                # so that the client can return results in any order.
                futures: dict[str, asyncio.Future] = {
                    tc["id"]: hub.create_tool_result_future(
                        conversation_id, tc["id"]
                    )
                    for tc in tool_calls_list
                }

                # Notify the client of each tool call
                for tc in tool_calls_list:
                    await _send({
                        "type": "tool_call",
                        "conversation_id": conversation_id,
                        "message_id": assistant_msg.id,
                        "call_id": tc["id"],
                        "name": tc["function"]["name"],
                        "arguments": tc["function"]["arguments"],
                    })

                # Await results and persist tool-result messages
                for tc in tool_calls_list:
                    try:
                        tool_result = await asyncio.wait_for(
                            futures[tc["id"]], timeout=120.0
                        )
                        result_content: str = tool_result.get("content", "")
                    except asyncio.TimeoutError:
                        result_content = "Tool execution timed out"
                    except asyncio.CancelledError:
                        hub.cancel_tool_futures(conversation_id)
                        raise

                    db.add(Message(
                        id=str(uuid.uuid4()),
                        conversation_id=conversation_id,
                        role="tool",
                        tool_call_id=tc["id"],
                        content=result_content,
                        created_at=datetime.now(timezone.utc),
                    ))
                await db.commit()

                # Create new assistant placeholder for the next iteration
                assistant_msg = Message(
                    id=str(uuid.uuid4()),
                    conversation_id=conversation_id,
                    role="assistant",
                    content="",
                    created_at=datetime.now(timezone.utc),
                )
                db.add(assistant_msg)
                await db.commit()

                # Tell the client to expect a new streaming message
                await _send({
                    "type": "generation_start",
                    "conversation_id": conversation_id,
                    "message_id": assistant_msg.id,
                })
                continue  # next iteration of the tool-call loop

            # ── No tool calls — final response ────────────────────────────────
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
            return  # done

        # ── Max iterations reached ────────────────────────────────────────────
        final_content = "".join(content_buf)
        if assistant_msg is not None:
            assistant_msg.content = final_content
            conv.updated_at = datetime.now(timezone.utc)
            await db.commit()
        await _send({
            "type": "message_complete",
            "conversation_id": conversation_id,
            "message": {
                "id": assistant_msg.id if assistant_msg else "",
                "role": "assistant",
                "content": final_content,
                "images": [],
                "created_at": datetime.now(timezone.utc).isoformat(),
            },
        })

    except asyncio.CancelledError:
        hub.cancel_tool_futures(conversation_id)
        # Save whatever was streamed so far
        if assistant_msg is not None and content_buf:
            partial = "".join(content_buf)
            if in_thinking and not thinking_closed:
                partial += "</think>"
            try:
                assistant_msg.content = partial
                if conv is not None:
                    conv.updated_at = datetime.now(timezone.utc)
                await db.commit()
            except Exception:
                pass
        raise

    except Exception as e:
        hub.cancel_tool_futures(conversation_id)
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
