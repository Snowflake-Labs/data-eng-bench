#!/usr/bin/env python3
"""Prepare a per-task Snowflake clone for DB_TYPE=snowflake runs.

Run by the task's Harbor healthcheck (``[environment.healthcheck]``) after the
container starts and before the agent, because Harbor overrides the image
ENTRYPOINT with its own keepalive (so entrypoint-based setup never runs).

Idempotent: if ``/tmp/snowflake_env.sh`` already exists it exits immediately, so
Harbor healthcheck retries are safe.

Auth: uses SNOWFLAKE_PASSWORD when set, otherwise a base64 PKCS8 private key in
SNOWFLAKE_PRIVATE_KEY (optionally SNOWFLAKE_PRIVATE_KEY_PASSPHRASE). Matches the
dbt profile and the verifier, which both accept either.

Isolation: clones SNOWFLAKE_SOURCE_DATABASE into ``retail_clone_<random>`` owned
by the caller's role, and points SNOWFLAKE_DATABASE at the clone. The clone is
dropped by cleanup_snowflake.py when the task finishes.
"""

import os
import secrets
import sys

ENV_FILE = "/tmp/snowflake_env.sh"
CLONE_NAME_FILE = "/tmp/snowflake_clone_name.txt"


def log(msg: str) -> None:
    print(f"[snowflake_clone] {msg}", flush=True)


def _connect_kwargs() -> dict:
    account = os.environ["SNOWFLAKE_ACCOUNT"]
    kwargs = {
        "account": account,
        "user": os.environ["SNOWFLAKE_USER"],
        "warehouse": os.environ["SNOWFLAKE_WAREHOUSE"],
        "role": os.environ.get("SNOWFLAKE_ROLE") or None,
    }
    host = os.environ.get("SNOWFLAKE_HOST")
    if host:
        kwargs["host"] = host
    password = os.environ.get("SNOWFLAKE_PASSWORD")
    if password:
        kwargs["password"] = password
        return kwargs
    # Key-pair fallback.
    import base64

    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

    key_b64 = os.environ.get("SNOWFLAKE_PRIVATE_KEY", "")
    if not key_b64:
        raise SystemExit(
            "Need SNOWFLAKE_PASSWORD or SNOWFLAKE_PRIVATE_KEY for the Snowflake clone."
        )
    passphrase = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE") or None
    p_key = serialization.load_pem_private_key(
        base64.b64decode(key_b64),
        password=passphrase.encode() if passphrase else None,
        backend=default_backend(),
    )
    kwargs["private_key"] = p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return kwargs


def main() -> int:
    if os.environ.get("DB_TYPE", "duckdb").lower() != "snowflake":
        return 0
    if os.path.exists(ENV_FILE):
        log(f"{ENV_FILE} already present; clone ready.")
        return 0

    source_db = os.environ["SNOWFLAKE_SOURCE_DATABASE"]
    clone_db = f"retail_clone_{secrets.token_hex(6)}"

    import snowflake.connector

    log(f"Cloning {source_db} -> {clone_db}")
    conn = snowflake.connector.connect(**_connect_kwargs())
    try:
        cur = conn.cursor()
        cur.execute(f"CREATE DATABASE {clone_db} CLONE {source_db}")
    finally:
        conn.close()

    # Downstream (agent dbt runs + verifier) read these; the verifier and
    # dbt profile pick up SNOWFLAKE_DATABASE = the clone.
    passthrough = [
        "SNOWFLAKE_ACCOUNT",
        "SNOWFLAKE_HOST",
        "SNOWFLAKE_USER",
        "SNOWFLAKE_PASSWORD",
        "SNOWFLAKE_PRIVATE_KEY",
        "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE",
        "SNOWFLAKE_WAREHOUSE",
        "SNOWFLAKE_ROLE",
        "SNOWFLAKE_SCHEMA",
    ]
    lines = [f'export SNOWFLAKE_DATABASE="{clone_db}"', f'export SNOWFLAKE_CLONE_NAME="{clone_db}"', 'export DB_TYPE="snowflake"']
    for var in passthrough:
        val = os.environ.get(var)
        if val is not None:
            esc = val.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'export {var}="{esc}"')
    with open(ENV_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(CLONE_NAME_FILE, "w") as f:
        f.write(clone_db + "\n")
    log(f"Clone ready: {clone_db}; wrote {ENV_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
