from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from database import init_db
from routers import auth, conversations, models_router, settings, ws


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="LocalLLMChat Backend", version="0.1.0", lifespan=lifespan)

# Allow the Flutter app to connect from any LAN origin.
# Tighten this if you expose the backend beyond your LAN.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(conversations.router)
app.include_router(settings.router)
app.include_router(models_router.router)
app.include_router(ws.router)


@app.get("/health", tags=["health"])
async def health():
    return {"status": "ok"}
