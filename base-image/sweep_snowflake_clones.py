#!/usr/bin/env python3
"""Drop orphaned per-task Snowflake clone databases left by DB_TYPE=snowflake runs.

Each Snowflake task clones SNOWFLAKE_SOURCE_DATABASE into ``retail_clone_<hash>``
via the Harbor healthcheck, and cleanup_snowflake.py drops it at the end of the
task's test.sh. A run that fails *before* the verifier phase (e.g. a
healthcheck/clone timeout or an agent crash) never reaches that cleanup, so the
clone is orphaned. Harbor tasks have no always-run teardown hook, so run this
sweep periodically (cron) or after a batch to reclaim leftovers.

Auth mirrors snowflake_clone.py / cleanup_snowflake.py: SNOWFLAKE_PASSWORD when
set, otherwise a base64 PKCS8 key in SNOWFLAKE_PRIVATE_KEY (+ optional
SNOWFLAKE_PRIVATE_KEY_PASSPHRASE). SNOWFLAKE_HOST is optional and passed only
when set (passing host=None breaks host derivation for org-dash accounts).

Usage:
  export SNOWFLAKE_ACCOUNT=... SNOWFLAKE_USER=... SNOWFLAKE_PASSWORD=...
  export SNOWFLAKE_WAREHOUSE=COMPUTE_WH SNOWFLAKE_ROLE=SYSADMIN
  python3 sweep_snowflake_clones.py --older-than-hours 24            # drop stale
  python3 sweep_snowflake_clones.py --older-than-hours 0 --dry-run   # preview all
"""

import argparse
import base64
import datetime
import os
import sys


def _connect_kwargs() -> dict:
    kwargs = {
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "user": os.environ["SNOWFLAKE_USER"],
        "warehouse": os.environ["SNOWFLAKE_WAREHOUSE"],
        "role": os.environ.get("SNOWFLAKE_ROLE") or None,
    }
    # Only pass host when explicitly set; host=None breaks org-dash derivation.
    if os.environ.get("SNOWFLAKE_HOST"):
        kwargs["host"] = os.environ["SNOWFLAKE_HOST"]

    password = os.environ.get("SNOWFLAKE_PASSWORD")
    if password:
        kwargs["password"] = password
        return kwargs

    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

    key_b64 = os.environ.get("SNOWFLAKE_PRIVATE_KEY", "")
    if not key_b64:
        raise SystemExit("Need SNOWFLAKE_PASSWORD or SNOWFLAKE_PRIVATE_KEY.")
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
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix", default="retail_clone_",
                    help="Clone name prefix to match (default: retail_clone_)")
    ap.add_argument("--older-than-hours", type=float, default=24.0,
                    help="Only drop clones older than this many hours (default: 24)")
    ap.add_argument("--dry-run", action="store_true",
                    help="List what would be dropped without dropping")
    args = ap.parse_args()

    import snowflake.connector

    conn = snowflake.connector.connect(**_connect_kwargs())
    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(hours=args.older_than_hours)
    prefix = args.prefix.lower()

    dropped = kept = 0
    try:
        cur = conn.cursor()
        # SHOW DATABASES columns: created_on(0), name(1), ...
        cur.execute(f"SHOW DATABASES LIKE '{args.prefix}%'")
        rows = cur.fetchall()
        for row in rows:
            created_on, name = row[0], row[1]
            if not name.lower().startswith(prefix):
                continue
            age_h = (now - created_on).total_seconds() / 3600.0
            if created_on > cutoff:
                kept += 1
                continue
            if args.dry_run:
                print(f"[dry-run] would drop {name} (age {age_h:.1f}h)")
                dropped += 1
                continue
            try:
                cur.execute(f'DROP DATABASE IF EXISTS "{name}"')
                print(f"dropped {name} (age {age_h:.1f}h)")
                dropped += 1
            except Exception as e:
                print(f"WARN could not drop {name}: {e}", file=sys.stderr)
    finally:
        conn.close()

    verb = "would drop" if args.dry_run else "dropped"
    print(f"\n{verb} {dropped} clone(s); kept {kept} younger than "
          f"{args.older_than_hours}h.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
