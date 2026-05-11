import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from jose import JWTError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from auth import (
    create_access_token,
    create_partial_token,
    create_refresh_token,
    decode_partial_token,
    decode_refresh_token,
    generate_totp_secret,
    get_totp_uri,
    hash_password,
    verify_password,
    verify_totp,
)
from config import settings
from dependencies import get_current_user, get_db
from models import User
from schemas import (
    LoginRequest,
    LoginResponse,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
    TotpCompleteRequest,
    TotpSetupResponse,
    TotpVerifyRequest,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=201)
async def register(req: RegisterRequest, db: AsyncSession = Depends(get_db)):
    """
    Create a new user account.
    Controlled by the REGISTRATION_ENABLED environment variable (default: true).
    Set REGISTRATION_ENABLED=false to disable public registration.
    """
    if not settings.registration_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Registration is disabled. Ask an administrator to create an account.",
        )

    existing = await db.scalar(select(User).where(User.username == req.username))
    if existing:
        raise HTTPException(status_code=400, detail="Username already taken")

    user = User(
        id=str(uuid.uuid4()),
        username=req.username,
        hashed_password=hash_password(req.password),
    )
    db.add(user)
    await db.commit()

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/login", response_model=LoginResponse)
async def login(req: LoginRequest, db: AsyncSession = Depends(get_db)):
    user = await db.scalar(select(User).where(User.username == req.username))
    if not user or not verify_password(req.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )

    if user.totp_enabled:
        return LoginResponse(
            requires_2fa=True,
            partial_token=create_partial_token(user.id),
        )

    return LoginResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/2fa/complete", response_model=TokenResponse)
async def complete_2fa(req: TotpCompleteRequest, db: AsyncSession = Depends(get_db)):
    """Exchange a partial token + valid TOTP code for a full access token."""
    try:
        user_id = decode_partial_token(req.partial_token)
    except (JWTError, ValueError):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired 2FA session",
        )

    user = await db.get(User, user_id)
    if not user or not user.totp_enabled or not user.totp_secret:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="2FA not configured for this account",
        )

    if not verify_totp(user.totp_secret, req.code):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid TOTP code",
        )

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(req: RefreshRequest, db: AsyncSession = Depends(get_db)):
    """
    Exchange a valid refresh token for a fresh access token + refresh token.

    The old refresh token remains valid until it expires (30 days), so clients
    can retry if the response is lost.  In practice the client always stores
    the latest pair it receives.
    """
    exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired refresh token",
    )
    try:
        user_id = decode_refresh_token(req.refresh_token)
    except Exception:
        raise exc

    user = await db.get(User, user_id)
    if user is None:
        raise exc

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=create_refresh_token(user.id),
    )


@router.post("/2fa/setup", response_model=TotpSetupResponse)
async def setup_2fa(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Generate a new TOTP secret for the current user (not yet enabled)."""
    secret = generate_totp_secret()
    user.totp_secret = secret
    # totp_enabled stays False until the user confirms with a valid code
    await db.commit()
    return TotpSetupResponse(secret=secret, uri=get_totp_uri(secret, user.username))


@router.post("/2fa/confirm")
async def confirm_2fa(
    req: TotpVerifyRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Verify first TOTP code to enable 2FA on the account."""
    if not user.totp_secret:
        raise HTTPException(
            status_code=400, detail="Run /2fa/setup first to generate a secret"
        )
    if not verify_totp(user.totp_secret, req.code):
        raise HTTPException(status_code=400, detail="Invalid TOTP code")
    user.totp_enabled = True
    await db.commit()
    return {"ok": True}


@router.post("/2fa/disable")
async def disable_2fa(
    req: TotpVerifyRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Disable TOTP 2FA — requires a valid current code."""
    if not user.totp_enabled or not user.totp_secret:
        raise HTTPException(status_code=400, detail="2FA is not enabled")
    if not verify_totp(user.totp_secret, req.code):
        raise HTTPException(status_code=400, detail="Invalid TOTP code")
    user.totp_enabled = False
    user.totp_secret = None
    await db.commit()
    return {"ok": True}


@router.get("/2fa/status")
async def get_2fa_status(user: User = Depends(get_current_user)):
    """Return whether 2FA is enabled for the current user."""
    return {"totp_enabled": user.totp_enabled}
