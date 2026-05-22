import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.middleware.base import BaseHTTPMiddleware

from config import settings
from database import init_db
from limiter import limiter
from routers import auth, conversations, models_router, settings as settings_router, ws

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Refuse to start with the insecure default secret key.
    settings.validate_secret_key()
    await init_db()
    yield


app = FastAPI(
    title="LocalLLMChat Backend",
    version="0.1.0",
    lifespan=lifespan,
    docs_url=None,     # disable Swagger UI  (/docs)
    redoc_url=None,    # disable ReDoc       (/redoc)
    openapi_url=None,  # disable OpenAPI schema (/openapi.json)
)

# ── Rate limiter ──────────────────────────────────────────────────────────────
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── CORS ──────────────────────────────────────────────────────────────────────
# Flutter mobile/desktop clients do NOT send an Origin header, so CORS does not
# affect them at all.  This allowlist only matters for browser-based (PWA/web)
# clients.  Setting allow_credentials=False is correct because the Flutter app
# uses Bearer tokens in the Authorization header, not cookies.
#
# Override the allowed origins at deploy time via the CORS_ORIGINS env var
# (comma-separated, e.g. "https://app.example.com").  An empty value means no
# browser origin is permitted — safe for a mobile-only deployment.
import os as _os
_raw_origins = _os.getenv("CORS_ORIGINS", "")
ALLOWED_ORIGINS = [o.strip() for o in _raw_origins.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,           # Bearer-header auth — no cookies needed
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
    max_age=600,
)


# ── Request body size limit ───────────────────────────────────────────────────
class _BodySizeLimitMiddleware(BaseHTTPMiddleware):
    """Reject requests whose Content-Length exceeds MAX_BODY (10 MB)."""
    MAX_BODY = 10 * 1024 * 1024  # 10 MB

    async def dispatch(self, request: Request, call_next):
        cl = request.headers.get("content-length")
        if cl is not None and int(cl) > self.MAX_BODY:
            return Response(
                status_code=413,
                content='{"detail": "Request body too large (max 10 MB)"}',
                media_type="application/json",
            )
        return await call_next(request)


app.add_middleware(_BodySizeLimitMiddleware)


# ── Security response headers ─────────────────────────────────────────────────
class _SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """Add security headers to every response."""

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault(
            "Permissions-Policy", "geolocation=(), camera=(), microphone=()"
        )
        # HSTS: tell browsers to always use HTTPS for the next year.
        # Only meaningful when the server is behind TLS — harmless otherwise.
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
        )
        return response


app.add_middleware(_SecurityHeadersMiddleware)

# ── Routers ───────────────────────────────────────────────────────────────────
app.include_router(auth.router)
app.include_router(conversations.router)
app.include_router(settings_router.router)
app.include_router(models_router.router)
app.include_router(ws.router)


@app.get("/health", tags=["health"])
async def health():
    return {"status": "ok"}
