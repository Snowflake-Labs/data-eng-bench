#!/usr/bin/env python3
"""
Cleanup script to destroy the Snowflake clone and role after task completion.

This script is called by test.sh after tests complete. It:
1. Drops the clone database (retail_clone_<hash>)
2. Drops the agent role (TASK_AGENT_ROLE_<hash>)

Both resources use the same hash to ensure they're cleaned up together.
"""

import os
import sys
import subprocess


def load_snowflake_env():
    """Load Snowflake environment variables from file if available"""
    env_file = '/tmp/snowflake_env.sh'
    if os.path.exists(env_file):
        result = subprocess.run(
            ['bash', '-c', f'source {env_file} && env'],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if '=' in line and (line.startswith('SNOWFLAKE_') or line.startswith('DB_TYPE')):
                key, _, value = line.partition('=')
                os.environ[key] = value


def cleanup_snowflake_clone():
    # Load env vars from file first
    load_snowflake_env()
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type != 'snowflake':
        print("DuckDB backend - no cleanup needed")
        return

    # Get clone name from file or environment
    clone_name = None
    if os.path.exists('/tmp/snowflake_clone_name.txt'):
        with open('/tmp/snowflake_clone_name.txt', 'r') as f:
            clone_name = f.read().strip()
    elif os.environ.get('SNOWFLAKE_CLONE_NAME'):
        clone_name = os.environ['SNOWFLAKE_CLONE_NAME']

    # Get agent role name from file or environment
    agent_role = None
    if os.path.exists('/tmp/snowflake_agent_role.txt'):
        with open('/tmp/snowflake_agent_role.txt', 'r') as f:
            agent_role = f.read().strip()
    elif os.environ.get('SNOWFLAKE_AGENT_ROLE'):
        agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']

    if not clone_name and not agent_role:
        print("No Snowflake clone or role found - skipping cleanup")
        return

    print("==========================================")
    print(f"Cleaning up Snowflake resources")
    print(f"  Clone database: {clone_name or 'N/A'}")
    print(f"  Agent role: {agent_role or 'N/A'}")
    print("==========================================")

    try:
        import snowflake.connector
        import base64
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives import serialization

        def get_private_key():
            """Load private key from base64-encoded env var"""
            private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
            if not private_key_b64:
                raise ValueError("SNOWFLAKE_PRIVATE_KEY not found")
            private_key_pem = base64.b64decode(private_key_b64)
            passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
            passphrase_bytes = passphrase.encode() if passphrase else None
            p_key = serialization.load_pem_private_key(
                private_key_pem,
                password=passphrase_bytes,
                backend=default_backend()
            )
            return p_key.private_bytes(
                encoding=serialization.Encoding.DER,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()
            )

        # Role that owns the clone (can drop it). Falls back to SNOWFLAKE_ROLE
        # since the clone is created by the caller's own role.
        admin_role = (
            os.environ.get('SNOWFLAKE_ADMIN_ROLE')
            or os.environ.get('SNOWFLAKE_ROLE')
            or None
        )

        conn_kwargs = dict(
            account=os.environ['SNOWFLAKE_ACCOUNT'],
            user=os.environ['SNOWFLAKE_USER'],
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=admin_role,
        )
        # Include host only when explicitly set. Passing host=None makes the
        # connector fail to derive it from an org-dash account
        # ('NoneType' has no attribute 'lower'), which silently aborted cleanup
        # and leaked clone databases. Matches snowflake_clone.py.
        if os.environ.get('SNOWFLAKE_HOST'):
            conn_kwargs['host'] = os.environ['SNOWFLAKE_HOST']
        # Password when available, else key-pair (matches snowflake_clone.py).
        if os.environ.get('SNOWFLAKE_PASSWORD'):
            conn_kwargs['password'] = os.environ['SNOWFLAKE_PASSWORD']
        else:
            conn_kwargs['private_key'] = get_private_key()
        conn = snowflake.connector.connect(**conn_kwargs)
        cursor = conn.cursor()

        # Step 1: Revoke grants from agent role before dropping database
        if clone_name and agent_role:
            print(f"Revoking grants from {agent_role} on {clone_name}")
            try:
                cursor.execute(f"REVOKE ALL ON DATABASE {clone_name} FROM ROLE {agent_role}")
            except Exception as e:
                print(f"  Note: Could not revoke grants (may already be gone): {e}")

        # Step 2: Drop the clone database
        if clone_name:
            print(f"Dropping clone database: {clone_name}")
            cursor.execute(f"DROP DATABASE IF EXISTS {clone_name}")
            print(f"  Successfully dropped clone database: {clone_name}")

        # Step 3: Drop the agent role
        if agent_role:
            print(f"Dropping agent role: {agent_role}")
            try:
                cursor.execute(f"DROP ROLE IF EXISTS {agent_role}")
                print(f"  Successfully dropped agent role: {agent_role}")
            except Exception as e:
                print(f"  Note: Could not drop role: {e}")

        conn.close()

        # Remove the temporary files
        for tmp_file in ['/tmp/snowflake_clone_name.txt', '/tmp/snowflake_agent_role.txt']:
            if os.path.exists(tmp_file):
                os.remove(tmp_file)
                print(f"  Removed {tmp_file}")

        print("==========================================")
        print("Cleanup complete")
        print("==========================================")

    except Exception as e:
        print(f"Warning: Failed to cleanup: {e}", file=sys.stderr)
        # Don't fail the overall task if cleanup fails
        return


if __name__ == '__main__':
    cleanup_snowflake_clone()