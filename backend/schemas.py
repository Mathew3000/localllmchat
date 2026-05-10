from datetime import datetime
from typing import Any

from pydantic import BaseModel


# ── Auth ──────────────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class RegisterRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class LoginResponse(BaseModel):
    access_token: str | None = None
    token_type: str = "bearer"
    requires_2fa: bool = False
    partial_token: str | None = None


class TotpSetupResponse(BaseModel):
    secret: str
    uri: str


class TotpCompleteRequest(BaseModel):
    partial_token: str
    code: str


class TotpVerifyRequest(BaseModel):
    code: str


# ── Messages ──────────────────────────────────────────────────────────────────

class MessageOut(BaseModel):
    id: str
    role: str
    content: str
    images: list[str] = []
    tool_calls: list[dict] | None = None
    tool_call_id: str | None = None
    created_at: datetime

    model_config = {"from_attributes": True}


# ── Conversations ─────────────────────────────────────────────────────────────

class ConversationSummary(BaseModel):
    id: str
    title: str
    is_secret: bool = False
    user_bubble_color: int | None = None
    assistant_bubble_color: int | None = None
    last_prompt_tokens: int | None = None
    # Runtime flag injected by the conversations router — True while the backend
    # LLM task is actively streaming a response for this conversation.
    # Never stored in the DB; always False when read from DB directly.
    is_generating: bool = False
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ConversationDetail(ConversationSummary):
    messages: list[MessageOut] = []


class CreateConversationRequest(BaseModel):
    title: str = "New Conversation"
    # Allow client to supply its own ID (useful for migrating existing local convs)
    id: str | None = None
    is_secret: bool = False
    user_bubble_color: int | None = None
    assistant_bubble_color: int | None = None


class RenameConversationRequest(BaseModel):
    title: str


class UpdateConversationRequest(BaseModel):
    title: str | None = None
    is_secret: bool | None = None
    user_bubble_color: int | None = None
    assistant_bubble_color: int | None = None
    last_prompt_tokens: int | None = None


# ── Settings ──────────────────────────────────────────────────────────────────

class SettingsOut(BaseModel):
    data: dict[str, Any] = {}


class SettingsUpdate(BaseModel):
    data: dict[str, Any]
