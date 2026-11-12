from pydantic_settings import BaseSettings, SettingsConfigDict

_INSECURE_DEFAULT = "insecure-default-change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    secret_key: str = _INSECURE_DEFAULT
    algorithm: str = "HS256"
    # Short-lived access token (30 min) — auto-renewal is handled client-side
    # via the 30-day refresh token stored securely on the device.
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 30  # 30 days
    database_url: str = "sqlite+aiosqlite:////data/db.sqlite"
    registration_enabled: bool = True

    # In-app updates: where GitLab CI publishes the Android build.
    # Leave update_gitlab_url empty to turn updates off.
    update_gitlab_url: str = ""            # e.g. https://git.hacksaar.de
    update_project: str = ""               # e.g. Mathew3000/localllmchat
    update_ref: str = "master"
    update_job: str = "build:apk"
    update_gitlab_token: str = ""          # only needed for non-public projects
    update_basic_user: str = ""            # htaccess login in front of GitLab
    update_basic_password: str = ""
    update_cache_dir: str = "/data/updates"

    def validate_secret_key(self) -> None:
        """Call from lifespan — fatal if the secret key is still the insecure default."""
        if self.secret_key == _INSECURE_DEFAULT:
            raise RuntimeError(
                "SECRET_KEY is set to the insecure default value. "
                "Set SECRET_KEY to a strong random secret before starting the server. "
                "Generate one with:  openssl rand -hex 32"
            )


settings = Settings()
