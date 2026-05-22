import base64
import os
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
import pyotp
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from passlib.context import CryptContext

from config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def create_access_token(data: dict[str, Any]) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    to_encode["exp"] = expire
    return jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)


def decode_token(token: str) -> dict[str, Any]:
    """Decode and verify a JWT. Raises jwt.InvalidTokenError on failure."""
    return jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])


def generate_totp_secret() -> str:
    return pyotp.random_base32()


def get_totp_uri(secret: str, username: str) -> str:
    return pyotp.TOTP(secret).provisioning_uri(
        name=username, issuer_name="LoomChat"
    )


def verify_totp(secret: str, code: str) -> bool:
    return pyotp.TOTP(secret).verify(code, valid_window=1)


def create_refresh_token(
    user_id: str, family_id: str | None = None
) -> tuple[str, str, str]:
    """Create a refresh token with rotation-tracking claims.

    Returns:
        (token_str, jti, family_id)

    ``jti`` uniquely identifies this token in the ``refresh_tokens`` table.
    ``family_id`` groups all tokens issued in the same rotation chain so that
    a re-use attack (presenting an already-consumed token) can revoke the
    entire family.
    """
    jti = str(uuid.uuid4())
    if family_id is None:
        family_id = str(uuid.uuid4())
    to_encode = {
        "sub": user_id,
        "jti": jti,
        "fam": family_id,
        "type": "refresh",
        "exp": datetime.now(timezone.utc) + timedelta(
            days=settings.refresh_token_expire_days
        ),
    }
    token = jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)
    return token, jti, family_id


def decode_refresh_token(token: str) -> tuple[str, str | None, str | None]:
    """Decode a refresh token and return (user_id, jti, family_id).

    ``jti`` and ``family_id`` are None for legacy tokens issued before the
    rotation system was added — those tokens are still accepted but cannot be
    revoked individually.

    Raises ``jwt.InvalidTokenError`` or ``ValueError`` on invalid / expired tokens.
    """
    payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    if payload.get("type") != "refresh":
        raise ValueError("Not a refresh token")
    user_id: str | None = payload.get("sub")
    if not user_id:
        raise ValueError("Missing sub in refresh token")
    return user_id, payload.get("jti"), payload.get("fam")


def create_partial_token(user_id: str) -> str:
    """Short-lived token indicating password auth passed but 2FA is pending."""
    to_encode = {
        "sub": user_id,
        "type": "partial",
        "exp": datetime.now(timezone.utc) + timedelta(minutes=5),
    }
    return jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)


def decode_partial_token(token: str) -> str:
    """Decode a partial token and return the user_id. Raises on invalid/expired."""
    payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    if payload.get("type") != "partial":
        raise ValueError("Not a partial token")
    user_id: str | None = payload.get("sub")
    if not user_id:
        raise ValueError("Missing sub in partial token")
    return user_id


# ── Settings field encryption ──────────────────────────────────────────────────
# Sensitive settings fields (e.g. apiKey) are encrypted with AES-256-GCM before
# storage so a database dump alone is not sufficient to recover them — the
# SECRET_KEY env var is also required.

def _settings_enc_key() -> bytes:
    """Derive a 256-bit AES key from SECRET_KEY via HKDF-SHA256."""
    hkdf = HKDF(
        algorithm=SHA256(),
        length=32,
        salt=b"loomchat_settings_enc_v1",
        info=b"",
    )
    return hkdf.derive(settings.secret_key.encode("utf-8"))


def encrypt_value(plaintext: str) -> str:
    """AES-256-GCM encrypt *plaintext*. Returns base64(nonce || ciphertext)."""
    if not plaintext:
        return ""
    key = _settings_enc_key()
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    ct = aesgcm.encrypt(nonce, plaintext.encode("utf-8"), None)
    return base64.b64encode(nonce + ct).decode("ascii")


def decrypt_value(ciphertext: str) -> str:
    """Decrypt a value produced by encrypt_value. Returns '' on any error."""
    if not ciphertext:
        return ""
    try:
        raw = base64.b64decode(ciphertext)
        nonce, ct = raw[:12], raw[12:]
        aesgcm = AESGCM(_settings_enc_key())
        return aesgcm.decrypt(nonce, ct, None).decode("utf-8")
    except Exception:
        return ""
