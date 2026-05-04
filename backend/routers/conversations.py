import re
import uuid
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from dependencies import get_current_user, get_db
from models import Conversation, Message, User, UserSettings
from schemas import (
    ConversationDetail,
    ConversationSummary,
    CreateConversationRequest,
    MessageOut,
    RenameConversationRequest,
    UpdateConversationRequest,
)

router = APIRouter(prefix="/api/conversations", tags=["conversations"])


def _own_or_404(conv: Conversation | None, user: User) -> Conversation:
    if conv is None or conv.user_id != user.id:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conv


# ── CRUD ──────────────────────────────────────────────────────────────────────

@router.get("", response_model=list[ConversationSummary])
async def list_conversations(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Conversation)
        .where(Conversation.user_id == user.id)
        .order_by(Conversation.updated_at.desc())
    )
    return result.scalars().all()


@router.post("", response_model=ConversationSummary, status_code=201)
async def create_conversation(
    req: CreateConversationRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = Conversation(
        id=req.id or str(uuid.uuid4()),
        user_id=user.id,
        title=req.title,
        is_secret=req.is_secret,
        user_bubble_color=req.user_bubble_color,
        assistant_bubble_color=req.assistant_bubble_color,
    )
    db.add(conv)
    await db.commit()
    await db.refresh(conv)
    return conv


@router.get("/{conv_id}", response_model=ConversationDetail)
async def get_conversation(
    conv_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)
    # Eagerly load messages
    await db.refresh(conv, ["messages"])
    return conv


@router.patch("/{conv_id}", response_model=ConversationSummary)
async def update_conversation(
    conv_id: str,
    req: UpdateConversationRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)
    if req.title is not None:
        conv.title = req.title
    if req.is_secret is not None:
        conv.is_secret = req.is_secret
    # Bubble colours use a sentinel: passing None means "clear", so we always
    # apply them when the key is present in the body.  The client sends all
    # fields it wants to update, omitting ones it doesn't.
    if req.user_bubble_color is not None or "user_bubble_color" in req.model_fields_set:
        conv.user_bubble_color = req.user_bubble_color
    if req.assistant_bubble_color is not None or "assistant_bubble_color" in req.model_fields_set:
        conv.assistant_bubble_color = req.assistant_bubble_color
    conv.updated_at = datetime.now(timezone.utc)
    await db.commit()
    return conv


@router.delete("/{conv_id}", status_code=204)
async def delete_conversation(
    conv_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)
    await db.delete(conv)
    await db.commit()


# ── Messages ──────────────────────────────────────────────────────────────────

@router.post("/{conv_id}/messages", response_model=MessageOut, status_code=201)
async def add_message(
    conv_id: str,
    body: dict,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """
    Persist a message directly (e.g. for migration / importing history).
    Normal generation flow goes through the WebSocket endpoint.
    """
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)

    msg = Message(
        id=body.get("id") or str(uuid.uuid4()),
        conversation_id=conv_id,
        role=body["role"],
        content=body.get("content", ""),
        images=body.get("images", []),
        tool_calls=body.get("tool_calls"),
        tool_call_id=body.get("tool_call_id"),
    )
    db.add(msg)
    conv.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(msg)
    return msg


@router.delete("/{conv_id}/messages/{msg_id}", status_code=204)
async def delete_message(
    conv_id: str,
    msg_id: str,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)

    msg = await db.get(Message, msg_id)
    if not msg or msg.conversation_id != conv_id:
        raise HTTPException(status_code=404, detail="Message not found")

    await db.delete(msg)
    await db.commit()


# ── Auto-title ────────────────────────────────────────────────────────────────

class GenerateTitleRequest(BaseModel):
    first_message: str


@router.post("/{conv_id}/generate-title")
async def generate_title(
    conv_id: str,
    req: GenerateTitleRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Ask the LLM for a short title, persist it, and return it."""
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)

    us = await db.get(UserSettings, user.id)
    settings: dict = dict(us.data) if us else {}

    # Mirror llm.py's resolution order so the same LLM is always used.
    base_url = (
        settings.get("baseUrlHome")
        or settings.get("baseUrl")
        or "http://localhost:11434/v1"
    ).rstrip("/")
    model = settings.get("selectedModel") or ""
    api_key = settings.get("apiKey") or ""

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    prompt = (
        "Generate a short conversation title (max 6 words) for a chat that "
        f"starts with: {req.first_message}"
    )

    async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:
        resp = await client.post(
            f"{base_url}/chat/completions",
            headers=headers,
            json={
                "model": model,
                "messages": [
                    # Strong system instruction to suppress thinking/reasoning.
                    {
                        "role": "system",
                        "content": (
                            "You output only a single short title, nothing else. "
                            "No thinking, no reasoning steps, no explanation, no quotes."
                        ),
                    },
                    {"role": "user", "content": prompt},
                ],
                "stream": False,
                "max_tokens": 20,
                # Disable thinking mode for models that support this flag
                # (e.g. Qwen3 on vLLM). Ignored by other backends.
                "enable_thinking": False,
                "chat_template_kwargs": {"enable_thinking": False},
            },
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"LLM error: {resp.status_code}")

    try:
        msg = resp.json()["choices"][0]["message"]
        # Prefer content; fall back to reasoning_content for models that emit
        # their final answer there (e.g. some Qwen3 configs).
        raw: str = msg.get("content") or msg.get("reasoning_content") or ""
    except (KeyError, IndexError, ValueError):
        raise HTTPException(status_code=502, detail="Unexpected LLM response")

    # Strip any <think>…</think> blocks the model may have emitted.
    raw = re.sub(r"<think>[\s\S]*?</think>", "", raw)
    raw = re.sub(r"<think>[\s\S]*", "", raw)  # unclosed block

    title = raw.strip().strip("\"'`")
    if not title:
        raise HTTPException(status_code=502, detail="LLM returned empty title")
    if len(title) > 60:
        title = title[:60].rstrip() + "…"

    conv.title = title
    conv.updated_at = datetime.now(timezone.utc)
    await db.commit()

    return {"title": title}
