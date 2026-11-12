"""In-app updates for the Android app.

GitHub Actions builds a signed APK on every master push and publishes it as a
GitHub Release tagged ``v<version>-build.<number>``. The repository is
private, so this server fetches the latest release with a read-only token and
hands it to signed-in users.
"""

import asyncio
import logging
import os
import re
import time
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from config import settings
from dependencies import get_current_user
from models import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/app/update", tags=["app-update"])

_GITHUB_API = "https://api.github.com"
_TAG_RE = re.compile(r"^v(?P<version>.+)-build\.(?P<build>\d+)$")
_INFO_TTL = 300  # seconds between checks against GitHub

_info_cache: dict | None = None
_info_cached_at = 0.0
_download_lock = asyncio.Lock()


def _configured() -> bool:
    return bool(settings.update_github_repo)


def _client(timeout: float, accept: str = "application/vnd.github+json") -> httpx.AsyncClient:
    headers = {"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"}
    if settings.update_github_token:
        headers["Authorization"] = f"Bearer {settings.update_github_token}"
    # Asset downloads redirect to a storage host; httpx drops the
    # Authorization header when a redirect leaves api.github.com.
    return httpx.AsyncClient(timeout=timeout, headers=headers, follow_redirects=True)


async def _latest_info() -> dict | None:
    global _info_cache, _info_cached_at
    if _info_cache is not None and time.monotonic() - _info_cached_at < _INFO_TTL:
        return _info_cache
    url = f"{_GITHUB_API}/repos/{settings.update_github_repo}/releases/latest"
    try:
        async with _client(15) as client:
            resp = await client.get(url)
        if resp.status_code != 200:
            logger.warning("Update check: GitHub returned %s", resp.status_code)
            return _info_cache
        release = resp.json()
        m = _TAG_RE.match(release.get("tag_name", ""))
        apk = next(
            (a for a in release.get("assets", []) if a.get("name", "").endswith(".apk")),
            None,
        )
        if m is None or apk is None:
            logger.warning("Update check: latest release has no APK or unknown tag")
            return _info_cache
        body = (release.get("body") or "").strip()
        info = {
            "version": m["version"],
            "build": int(m["build"]),
            "notes": body.splitlines()[0] if body else "",
            "asset_url": apk["url"],
        }
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
        "version": info["version"],
        "build": info["build"],
        "notes": info["notes"],
    }


@router.get("/android/apk")
async def android_update_apk(_: User = Depends(get_current_user)):
    """The newest APK. Downloaded from GitHub once, then served from disk."""
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
                async with _client(300, accept="application/octet-stream") as client:
                    async with client.stream("GET", info["asset_url"]) as resp:
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
        filename=f"LoomChat-{info['version']}-build.{info['build']}.apk",
    )
