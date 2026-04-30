import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from dependencies import get_current_user, get_db
from models import Conversation, Message, User
from schemas import (
    ConversationDetail,
    ConversationSummary,
    CreateConversationRequest,
    MessageOut,
    RenameConversationRequest,
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


@router.post("", response_model=ConversationDetail, status_code=201)
async def create_conversation(
    req: CreateConversationRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = Conversation(
        id=req.id or str(uuid.uuid4()),
        user_id=user.id,
        title=req.title,
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
async def rename_conversation(
    conv_id: str,
    req: RenameConversationRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    conv = await db.get(Conversation, conv_id)
    _own_or_404(conv, user)
    conv.title = req.title
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
