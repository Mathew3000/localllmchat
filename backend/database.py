from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from config import settings

engine = create_async_engine(settings.database_url, echo=False)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


# Columns added after initial release — ALTER TABLE is idempotent (errors ignored).
_MIGRATIONS = [
    "ALTER TABLE conversations ADD COLUMN is_secret BOOLEAN NOT NULL DEFAULT 0",
    "ALTER TABLE conversations ADD COLUMN user_bubble_color INTEGER",
    "ALTER TABLE conversations ADD COLUMN assistant_bubble_color INTEGER",
    "ALTER TABLE users ADD COLUMN totp_secret TEXT",
    "ALTER TABLE users ADD COLUMN totp_enabled BOOLEAN NOT NULL DEFAULT 0",
]


async def init_db() -> None:
    """Create all tables on startup, then apply lightweight column migrations."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        for stmt in _MIGRATIONS:
            try:
                await conn.execute(text(stmt))
            except Exception:
                pass  # Column already exists — safe to ignore
