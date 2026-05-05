#!/usr/bin/env python3
"""
LoomChat backend management CLI.

Usage:
    python manage.py create_user [<username>]
    python manage.py list_users

Run inside the Docker container:
    docker exec -it loomchat-backend python manage.py create_user
"""
import asyncio
import getpass
import sys
import uuid


async def _create_user(username: str, password: str) -> None:
    from database import AsyncSessionLocal, init_db
    from models import User
    from auth import hash_password
    from sqlalchemy import select

    await init_db()
    async with AsyncSessionLocal() as db:
        existing = await db.scalar(select(User).where(User.username == username))
        if existing:
            print(f"Error: user '{username}' already exists.")
            sys.exit(1)
        user = User(
            id=str(uuid.uuid4()),
            username=username,
            hashed_password=hash_password(password),
        )
        db.add(user)
        await db.commit()
        print(f"✓ User '{username}' created successfully.")


async def _list_users() -> None:
    from database import AsyncSessionLocal, init_db
    from models import User
    from sqlalchemy import select

    await init_db()
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(User).order_by(User.created_at))
        users = result.scalars().all()
        if not users:
            print("No users found.")
            return
        print(f"{'Username':<30} {'2FA':<5} {'Created'}")
        print("-" * 60)
        for u in users:
            fa = "yes" if u.totp_enabled else "no"
            print(f"{u.username:<30} {fa:<5} {u.created_at.strftime('%Y-%m-%d %H:%M')}")


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "create_user":
        username = sys.argv[2] if len(sys.argv) > 2 else input("Username: ").strip()
        if not username:
            print("Error: username cannot be empty.")
            sys.exit(1)
        password = getpass.getpass("Password: ")
        confirm = getpass.getpass("Confirm password: ")
        if password != confirm:
            print("Error: passwords do not match.")
            sys.exit(1)
        if len(password) < 8:
            print("Error: password must be at least 8 characters.")
            sys.exit(1)
        asyncio.run(_create_user(username, password))

    elif cmd == "list_users":
        asyncio.run(_list_users())

    else:
        print(f"Unknown command: {cmd}")
        print("Available commands: create_user, list_users")
        sys.exit(1)


if __name__ == "__main__":
    main()
