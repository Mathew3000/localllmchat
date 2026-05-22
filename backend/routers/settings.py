from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from auth import decrypt_value, encrypt_value
from dependencies import get_current_user, get_db
from models import User, UserSettings
from schemas import SettingsOut, SettingsUpdate

router = APIRouter(prefix="/api/settings", tags=["settings"])

# Settings fields that contain secrets and must be encrypted at rest.
_ENCRYPTED_FIELDS = {"apiKey"}
_ENC_FLAG = "_encryptedFields"


def _encrypt_settings(data: dict) -> dict:
    """Encrypt sensitive fields before storing. Returns a new dict."""
    out = dict(data)
    encrypted: list[str] = []
    for field in _ENCRYPTED_FIELDS:
        if field in out and out[field]:
            out[field] = encrypt_value(str(out[field]))
            encrypted.append(field)
    if encrypted:
        out[_ENC_FLAG] = encrypted
    else:
        out.pop(_ENC_FLAG, None)
    return out


def _decrypt_settings(data: dict) -> dict:
    """Decrypt sensitive fields after reading. Returns a new dict."""
    out = dict(data)
    for field in out.pop(_ENC_FLAG, []):
        if field in out and out[field]:
            out[field] = decrypt_value(out[field])
    return out


@router.get("", response_model=SettingsOut)
async def get_settings(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    us = await db.get(UserSettings, user.id)
    raw = us.data if us else {}
    return SettingsOut(data=_decrypt_settings(raw))


@router.put("", response_model=SettingsOut)
async def update_settings(
    req: SettingsUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    stored = _encrypt_settings(req.data)
    us = await db.get(UserSettings, user.id)
    if us is None:
        us = UserSettings(user_id=user.id, data=stored)
        db.add(us)
    else:
        us.data = stored
    await db.commit()
    # Return the decrypted view so the client always receives plaintext.
    return SettingsOut(data=_decrypt_settings(stored))
