from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from dependencies import get_current_user, get_db
from models import User, UserSettings
from schemas import SettingsOut, SettingsUpdate

router = APIRouter(prefix="/api/settings", tags=["settings"])


@router.get("", response_model=SettingsOut)
async def get_settings(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    us = await db.get(UserSettings, user.id)
    return SettingsOut(data=us.data if us else {})


@router.put("", response_model=SettingsOut)
async def update_settings(
    req: SettingsUpdate,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    us = await db.get(UserSettings, user.id)
    if us is None:
        us = UserSettings(user_id=user.id, data=req.data)
        db.add(us)
    else:
        us.data = req.data
    await db.commit()
    return SettingsOut(data=us.data)
