import httpx
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from dependencies import get_current_user, get_db
from models import User, UserSettings

router = APIRouter(prefix="/api/models", tags=["models"])


@router.get("")
async def list_models(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    """Proxy the /models request to the configured LLM backend."""
    us = await db.get(UserSettings, user.id)
    s = us.data if us else {}

    base_url = s.get("baseUrl", "http://localhost:11434/v1").rstrip("/")
    api_key = s.get("apiKey", "")

    headers: dict[str, str] = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{base_url}/models", headers=headers)
    except httpx.RequestError as exc:
        raise HTTPException(status_code=503, detail=f"Cannot reach LLM server: {exc}")

    if resp.status_code != 200:
        raise HTTPException(
            status_code=resp.status_code,
            detail=f"LLM server returned {resp.status_code}",
        )
    return resp.json()
