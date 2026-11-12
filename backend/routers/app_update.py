"""In-app updates for the Android app.

GitLab CI builds a signed APK on every master commit and stores it as a job
artifact next to an ``update.json`` ({"version", "build", "commit", "notes"}).
The git server sits behind an htaccess (anti-crawler) login, so the app can't
fetch it directly. This server fetches the newest build with those
credentials and hands it to signed-in users.
"""

import asyncio
import logging
import os
import time
from pathlib import Path
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from config import settings
from dependencies import get_current_user
from models import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/app/update", tags=["app-update"])

_APK_PATH = "build/app/outputs/flutter-apk/app-release.apk"
_INFO_TTL = 300  # seconds between checks against GitLab

_info_cache: dict | None = None
_info_cached_at = 0.0
_download_lock = asyncio.Lock()


def _configured() -> bool:
    return bool(settings.update_gitlab_url and settings.update_project)


def _artifact_url(path: str) -> str:
    base = settings.update_gitlab_url.rstrip("/")
    project = quote(settings.update_project, safe="")
    ref = quote(settings.update_ref, safe="")
    return (
        f"{base}/api/v4/projects/{project}/jobs/artifacts/{ref}/raw/{path}"
        f"?job={quote(settings.update_job, safe='')}"
    )


def _client(timeout: float) -> httpx.AsyncClient:
    headers = {}
    if settings.update_gitlab_token:
        headers["PRIVATE-TOKEN"] = settings.update_gitlab_token
    auth = None
    if settings.update_basic_user:
        auth = (settings.update_basic_user, settings.update_basic_password)
    return httpx.AsyncClient(
        timeout=timeout, headers=headers, auth=auth, follow_redirects=True
    )


async def _latest_info() -> dict | None:
    global _info_cache, _info_cached_at
    if _info_cache is not None and time.monotonic() - _info_cached_at < _INFO_TTL:
        return _info_cache
    try:
        async with _client(15) as client:
            resp = await client.get(_artifact_url("update.json"))
        if resp.status_code != 200:
            logger.warning("Update check: GitLab returned %s", resp.status_code)
            return _info_cache
        info = resp.json()
        info["build"] = int(info["build"])
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        logger.warning("Update check failed: %s", exc)
        return _info_cache
    _info_cache, _info_cached_at = info, time.monotonic()
    return info


def _apk_file(build: int) -> Path:
    return Path(settings.update_cache_dir) / f"loomchat-{build}.apk"


@router.get("/android")
async def android_update_info(_: User = Depends(get_current_user)):
    """Newest Android build: {"available", "version", "build", "notes"}."""
    if not _configured():
        return {"available": False}
    info = await _latest_info()
    if info is None:
        return {"available": False}
    return {
        "available": True,
        "version": info.get("version", ""),
        "build": info["build"],
        "commit": info.get("commit", ""),
        "notes": info.get("notes", ""),
    }


@router.get("/android/apk")
async def android_update_apk(_: User = Depends(get_current_user)):
    """The newest APK. Downloaded from GitLab once, then served from disk."""
    if not _configured():
        raise HTTPException(status_code=404, detail="Updates are not set up")
    info = await _latest_info()
    if info is None:
        raise HTTPException(status_code=503, detail="Update server unreachable")

    target = _apk_file(info["build"])
    async with _download_lock:
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_suffix(".part")
            try:
                async with _client(300) as client:
                    async with client.stream("GET", _artifact_url(_APK_PATH)) as resp:
                        if resp.status_code != 200:
                            raise HTTPException(
                                status_code=502,
                                detail=f"Update download failed ({resp.status_code})",
                            )
                        with open(tmp, "wb") as f:
                            async for chunk in resp.aiter_bytes():
                                f.write(chunk)
                os.replace(tmp, target)
            except httpx.HTTPError as exc:
                tmp.unlink(missing_ok=True)
                raise HTTPException(status_code=502, detail=f"Update download failed: {exc}")
            # Keep only the newest APK.
            for old in target.parent.glob("loomchat-*.apk"):
                if old != target:
                    old.unlink(missing_ok=True)

    return FileResponse(
        target,
        media_type="application/vnd.android.package-archive",
        filename=f"LoomChat-{info.get('version', '')}+{info['build']}.apk",
    )
