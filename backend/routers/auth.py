import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from auth import create_access_token, hash_password, verify_password
from dependencies import get_db
from models import User
from schemas import LoginRequest, RegisterRequest, TokenResponse

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=201)
async def register(req: RegisterRequest, db: AsyncSession = Depends(get_db)):
    """
    Create the first user account.  After the first account exists,
    registration is closed — add users manually or extend with invite codes.
    """
    count = await db.scalar(select(func.count()).select_from(User))
    if count and count > 0:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Registration is closed. The first account already exists.",
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

    return TokenResponse(access_token=create_access_token({"sub": user.id}))


@router.post("/login", response_model=TokenResponse)
async def login(req: LoginRequest, db: AsyncSession = Depends(get_db)):
    user = await db.scalar(select(User).where(User.username == req.username))
    if not user or not verify_password(req.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )
    return TokenResponse(access_token=create_access_token({"sub": user.id}))
