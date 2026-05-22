import uuid
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import select, update
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
from limiter import limiter
from models import RefreshToken, User
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

_AUTH_EXC = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Invalid or expired token",
)


async def _store_refresh_token(
    db: AsyncSession,
    user_id: str,
    jti: str,
    family_id: str,
) -> None:
    """Persist a newly-issued refresh token row."""
    rt = RefreshToken(
        jti=jti,
        user_id=user_id,
        family_id=family_id,
        expires_at=datetime.now(timezone.utc)
        + timedelta(days=settings.refresh_token_expire_days),
    )
    db.add(rt)
    await db.commit()


@router.post("/register", response_model=TokenResponse, status_code=201)
@limiter.limit("5/minute")
async def register(
    request: Request,
    req: RegisterRequest,
    db: AsyncSession = Depends(get_db),
):
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
        # Generic message — avoids confirming whether a username exists.
        raise HTTPException(
            status_code=400,
            detail="Registration failed. Try a different username.",
        )

    user = User(
        id=str(uuid.uuid4()),
        username=req.username,
        hashed_password=hash_password(req.password),
    )
    db.add(user)
    await db.flush()  # assign ID before creating refresh token

    rt_token, jti, family_id = create_refresh_token(user.id)
    await db.commit()
    await _store_refresh_token(db, user.id, jti, family_id)

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=rt_token,
    )


@router.post("/login", response_model=LoginResponse)
@limiter.limit("10/minute")
async def login(
    request: Request,
    req: LoginRequest,
    db: AsyncSession = Depends(get_db),
):
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

    rt_token, jti, family_id = create_refresh_token(user.id)
    await _store_refresh_token(db, user.id, jti, family_id)

    return LoginResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=rt_token,
    )


@router.post("/2fa/complete", response_model=TokenResponse)
@limiter.limit("5/minute")
async def complete_2fa(
    request: Request,
    req: TotpCompleteRequest,
    db: AsyncSession = Depends(get_db),
):
    """Exchange a partial token + valid TOTP code for a full access token."""
    try:
        user_id = decode_partial_token(req.partial_token)
    except (jwt.InvalidTokenError, ValueError):
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

    rt_token, jti, family_id = create_refresh_token(user.id)
    await _store_refresh_token(db, user.id, jti, family_id)

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=rt_token,
    )


@router.post("/refresh", response_model=TokenResponse)
@limiter.limit("20/minute")
async def refresh_token(
    request: Request,
    req: RefreshRequest,
    db: AsyncSession = Depends(get_db),
):
    """
    Exchange a valid refresh token for a fresh access + refresh token pair.

    Implements stateful rotation: the presented token is revoked and a new one
    is issued in the same rotation family.  Presenting an already-revoked token
    (re-use attack) revokes the entire family, forcing all devices to re-login.
    """
    try:
        user_id, jti, family_id = decode_refresh_token(req.refresh_token)
    except Exception:
        raise _AUTH_EXC

    if jti:
        # New-style token: verify against the DB.
        rt = await db.get(RefreshToken, jti)
        if rt is None:
            # Token was already rotated (row consumed).  Could be a re-use attack
            # or a lost network response.  Revoke the whole family to be safe.
            if family_id:
                await db.execute(
                    update(RefreshToken)
                    .where(RefreshToken.family_id == family_id)
                    .values(revoked=True)
                )
                await db.commit()
            raise _AUTH_EXC
        if rt.revoked:
            # Explicit re-use attack — revoke entire family.
            await db.execute(
                update(RefreshToken)
                .where(RefreshToken.family_id == family_id)
                .values(revoked=True)
            )
            await db.commit()
            raise _AUTH_EXC
        # Consume current token.
        rt.revoked = True
        await db.flush()

    user = await db.get(User, user_id)
    if user is None:
        await db.commit()
        raise _AUTH_EXC

    # Issue new pair in same rotation family (or a fresh family for legacy tokens).
    new_rt_token, new_jti, new_family_id = create_refresh_token(user.id, family_id)
    new_rt = RefreshToken(
        jti=new_jti,
        user_id=user.id,
        family_id=new_family_id,
        expires_at=datetime.now(timezone.utc)
        + timedelta(days=settings.refresh_token_expire_days),
    )
    db.add(new_rt)
    await db.commit()

    return TokenResponse(
        access_token=create_access_token({"sub": user.id}),
        refresh_token=new_rt_token,
    )


@router.post("/logout", status_code=204)
async def logout(
    req: RefreshRequest,
    db: AsyncSession = Depends(get_db),
):
    """
    Revoke the provided refresh token server-side.

    The client should discard its stored tokens after calling this endpoint.
    Errors are silently ignored so that clients can always log out cleanly
    even with an already-expired or malformed token.
    """
    try:
        _, jti, _ = decode_refresh_token(req.refresh_token)
        if jti:
            rt = await db.get(RefreshToken, jti)
            if rt and not rt.revoked:
                rt.revoked = True
                await db.commit()
    except Exception:
        pass  # Best-effort — never block a logout
    return Response(status_code=204)


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
