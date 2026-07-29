#!/bin/bash
set -euo pipefail

#===============================================================================
# ENTRYPOINT.SH - Container Initialization Script
#===============================================================================
#
# PURPOSE:
#   This script runs when the Docker container starts. It handles the setup
#   of Snowflake database clones for isolated task execution.
#
# WORKFLOW:
#   1. Check DB_TYPE environment variable (duckdb or snowflake)
#   2. If Snowflake:
#      a. Generate unique clone database name (retail_clone_<random>)
#      b. Connect to Snowflake using private key authentication
#      c. Create a restricted role (TASK_AGENT_ROLE_<hash>) with limited permissions
#      d. Clone the source database
#      e. Grant permissions on clone to the restricted role
#      f. Export environment variables for downstream processes
#   3. Create /tmp/entrypoint_ready marker file (signals completion)
#   4. Execute the container's CMD (typically "sleep infinity")
#
# ENVIRONMENT VARIABLES (for Snowflake mode):
#   Required:
#     - DB_TYPE=snowflake
#     - SNOWFLAKE_ACCOUNT        - Snowflake account identifier
#     - SNOWFLAKE_USER           - Snowflake username
#     - SNOWFLAKE_PRIVATE_KEY    - Base64-encoded private key (PEM format)
#     - SNOWFLAKE_WAREHOUSE      - Warehouse name
#     - SNOWFLAKE_SOURCE_DATABASE - Database to clone from
#     - SNOWFLAKE_SCHEMA         - Schema name (e.g., "main")
#   Optional:
#     - SNOWFLAKE_PRIVATE_KEY_PASSPHRASE - Private key passphrase
#     - SNOWFLAKE_ROLE           - Admin role for clone creation
#
# OUTPUT FILES:
#   - /tmp/entrypoint_ready         - Marker file indicating setup complete
#   - /tmp/snowflake_env.sh         - Environment variables for child processes
#   - /tmp/snowflake_clone_name.txt - Clone database name for cleanup
#   - /tmp/snowflake_agent_role.txt - Agent role name for cleanup
#
# CLEANUP:
#   Clone cleanup is handled by test.sh after tests complete, using the
#   cleanup_snowflake.py script.
#
# BLOCKING BEHAVIOR:
#   Harbor runs commands via "bash -lc <command>". The wait-for-init.sh script
#   in /etc/profile.d/ blocks until /tmp/entrypoint_ready exists, ensuring
#   Snowflake setup completes before any commands run.
#
#===============================================================================

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------

# Log message with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Log a major step with visual separator
log_step() {
    echo ""
    log "============================================"
    log "STEP $1: $2"
    log "============================================"
}

# Log an environment variable (shows <not set> if undefined)
log_env() {
    log "Environment variable $1: ${!1:-<not set>}"
}

#-------------------------------------------------------------------------------
# Main Entrypoint Logic
#-------------------------------------------------------------------------------

log "=========================================="
log "ENTRYPOINT STARTED"
log "=========================================="

# Determine database backend (default: duckdb for local development)
DB_TYPE="${DB_TYPE:-duckdb}"
log "DB_TYPE: $DB_TYPE"

if [ "$DB_TYPE" = "snowflake" ]; then
    #---------------------------------------------------------------------------
    # SNOWFLAKE MODE: Create isolated clone database
    #---------------------------------------------------------------------------
    log_step "1" "Setting up Snowflake clone"
    
    # Log all relevant environment variables (redact sensitive ones)
    log "Checking environment variables..."
    log_env "SNOWFLAKE_ACCOUNT"
    log_env "SNOWFLAKE_USER"
    log_env "SNOWFLAKE_WAREHOUSE"
    log_env "SNOWFLAKE_SOURCE_DATABASE"
    log_env "SNOWFLAKE_SCHEMA"
    log_env "SNOWFLAKE_ROLE"
    log "SNOWFLAKE_PRIVATE_KEY: ${SNOWFLAKE_PRIVATE_KEY:+<set, length=${#SNOWFLAKE_PRIVATE_KEY}>}"
    log "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:+<set>}"

    # Generate unique hash for both clone database and role
    # Using the same hash ensures they can be cleaned up together
    RANDOM_HASH=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 12)
    export SNOWFLAKE_CLONE_NAME="retail_clone_${RANDOM_HASH}"
    
    # Create unique role name with same hash (prevents conflicts with concurrent tasks)
    export AGENT_ROLE="TASK_AGENT_ROLE_${RANDOM_HASH}"

    log "Source database: $SNOWFLAKE_SOURCE_DATABASE"
    log "Clone database: $SNOWFLAKE_CLONE_NAME"
    log "Agent role: $AGENT_ROLE"

    # Create the clone and set up restricted role with access ONLY to the clone
    # The restricted role ensures agent cannot access other databases/tables

    log_step "2" "Running Python script to create Snowflake clone"
    
    python3 << CLONE_SCRIPT
import snowflake.connector
import os
import sys
import base64
import traceback
from datetime import datetime
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

def log(msg):
    """Log with timestamp"""
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [PYTHON] {msg}", flush=True)

def log_step(step, msg):
    """Log a step"""
    log(f"--- Step {step}: {msg} ---")

def execute_sql(cursor, sql, description):
    """Execute SQL with logging"""
    log(f"Executing: {description}")
    log(f"  SQL: {sql[:100]}{'...' if len(sql) > 100 else ''}")
    try:
        cursor.execute(sql)
        log(f"  SUCCESS: {description}")
        return True
    except Exception as e:
        log(f"  FAILED: {description}")
        log(f"  Error: {e}")
        raise

def get_private_key():
    """Load private key from base64-encoded env var"""
    log("Loading private key from environment...")
    private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
    if not private_key_b64:
        raise ValueError("SNOWFLAKE_PRIVATE_KEY environment variable is required")
    
    log(f"  Private key base64 length: {len(private_key_b64)}")

    # Decode base64 to get PEM content
    try:
        private_key_pem = base64.b64decode(private_key_b64)
        log(f"  Decoded PEM length: {len(private_key_pem)} bytes")
    except Exception as e:
        log(f"  ERROR: Failed to base64 decode private key: {e}")
        raise

    # Get passphrase if provided
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    log(f"  Passphrase provided: {bool(passphrase)}")

    # Load the private key
    try:
        p_key = serialization.load_pem_private_key(
            private_key_pem,
            password=passphrase_bytes,
            backend=default_backend()
        )
        log("  Successfully loaded PEM private key")
    except Exception as e:
        log(f"  ERROR: Failed to load PEM private key: {e}")
        raise

    # Convert to DER format for snowflake connector
    pkb = p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )
    log(f"  Converted to DER format: {len(pkb)} bytes")
    return pkb

try:
    log("="*50)
    log("SNOWFLAKE CLONE SETUP - START")
    log("="*50)
    
    log_step("2.1", "Loading private key")
    private_key = get_private_key()

    log_step("2.2", "Connecting to Snowflake")
    account = os.environ['SNOWFLAKE_ACCOUNT']
    user = os.environ['SNOWFLAKE_USER']
    warehouse = os.environ['SNOWFLAKE_WAREHOUSE']
    role = os.environ.get('SNOWFLAKE_ROLE', '')
    
    log(f"  Account: {account}")
    log(f"  User: {user}")
    log(f"  Warehouse: {warehouse}")
    log(f"  Role: {role}")
    
    conn = snowflake.connector.connect(
        account=account,
        user=user,
        private_key=private_key,
        warehouse=warehouse,
        role=role,
    )
    log("  Connected to Snowflake successfully!")
    cursor = conn.cursor()

    source_db = os.environ['SNOWFLAKE_SOURCE_DATABASE']
    clone_db = os.environ['SNOWFLAKE_CLONE_NAME']
    schema = os.environ.get('SNOWFLAKE_SCHEMA', 'PUBLIC')
    current_user = user
    agent_role = os.environ['AGENT_ROLE']  # Set by bash script: TASK_AGENT_ROLE_<hash>
    
    log(f"  Source DB: {source_db}")
    log(f"  Clone DB: {clone_db}")
    log(f"  Schema: {schema}")
    log(f"  Agent Role: {agent_role}")

    log_step("2.3", "Create restricted role")
    execute_sql(cursor, f"CREATE ROLE IF NOT EXISTS {agent_role}", "Create role")

    log_step("2.4", "Grant warehouse usage")
    execute_sql(cursor, f"GRANT USAGE ON WAREHOUSE {warehouse} TO ROLE {agent_role}", "Grant warehouse usage")

    log_step("2.5", "Grant role to user")
    execute_sql(cursor, f"GRANT ROLE {agent_role} TO USER {current_user}", "Grant role to user")

    log_step("2.6", "Create clone database")
    execute_sql(cursor, f"CREATE DATABASE {clone_db} CLONE {source_db}", "Create clone database")

    log_step("2.7", "Grant permissions on clone")
    execute_sql(cursor, f"GRANT USAGE ON DATABASE {clone_db} TO ROLE {agent_role}", "Grant DB usage")
    execute_sql(cursor, f"GRANT CREATE SCHEMA ON DATABASE {clone_db} TO ROLE {agent_role}", "Grant create schema")
    execute_sql(cursor, f"GRANT USAGE ON ALL SCHEMAS IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant schema usage")
    execute_sql(cursor, f"GRANT SELECT ON ALL TABLES IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant table select")
    execute_sql(cursor, f"GRANT SELECT ON ALL VIEWS IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant view select")
    execute_sql(cursor, f"GRANT CREATE TABLE ON ALL SCHEMAS IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant create table")
    execute_sql(cursor, f"GRANT CREATE VIEW ON ALL SCHEMAS IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant create view")
    execute_sql(cursor, f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN DATABASE {clone_db} TO ROLE {agent_role}", "Grant DML")

    # Note: ALTER ROLE ... SET DEFAULT_NAMESPACE is not valid Snowflake syntax
    # The database/schema is set explicitly in dbt profiles.yml, so this is not needed

    log("="*50)
    log(f"SNOWFLAKE CLONE SETUP - COMPLETE")
    log(f"Clone database ready: {clone_db}")
    log("="*50)

    conn.close()

except Exception as e:
    log("="*50)
    log("SNOWFLAKE CLONE SETUP - FAILED")
    log(f"Error: {e}")
    log("Traceback:")
    traceback.print_exc()
    log("="*50)
    sys.exit(1)
CLONE_SCRIPT

    #---------------------------------------------------------------------------
    # Export environment variables for downstream processes (dbt, tests, etc.)
    #---------------------------------------------------------------------------
    log_step "3" "Exporting environment variables"
    
    # Export the restricted agent role (used by dbt profiles)
    export SNOWFLAKE_AGENT_ROLE="$AGENT_ROLE"

    # Set the clone as the active database for downstream use
    export SNOWFLAKE_DATABASE="$SNOWFLAKE_CLONE_NAME"

    # Persist clone name and role name to files for cleanup later (used by cleanup_snowflake.py)
    echo "$SNOWFLAKE_CLONE_NAME" > /tmp/snowflake_clone_name.txt
    echo "$AGENT_ROLE" > /tmp/snowflake_agent_role.txt
    log "Saved clone name to /tmp/snowflake_clone_name.txt"
    log "Saved agent role to /tmp/snowflake_agent_role.txt"

    # Persist all Snowflake env vars for child processes
    # This file is sourced by wait-for-init.sh and solve.sh
    # IMPORTANT: SNOWFLAKE_ROLE is set to AGENT_ROLE (restricted) not ADMIN_ROLE
    cat > /tmp/snowflake_env.sh << ENVFILE
export SNOWFLAKE_DATABASE="$SNOWFLAKE_CLONE_NAME"
export SNOWFLAKE_CLONE_NAME="$SNOWFLAKE_CLONE_NAME"
export SNOWFLAKE_ACCOUNT="$SNOWFLAKE_ACCOUNT"
export SNOWFLAKE_HOST="${SNOWFLAKE_HOST:-}"
export SNOWFLAKE_USER="$SNOWFLAKE_USER"
export SNOWFLAKE_PRIVATE_KEY="$SNOWFLAKE_PRIVATE_KEY"
export SNOWFLAKE_PRIVATE_KEY_PASSPHRASE="${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}"
export SNOWFLAKE_WAREHOUSE="$SNOWFLAKE_WAREHOUSE"
export SNOWFLAKE_SCHEMA="$SNOWFLAKE_SCHEMA"
export SNOWFLAKE_ADMIN_ROLE="${SNOWFLAKE_ROLE:-}"
export SNOWFLAKE_AGENT_ROLE="$SNOWFLAKE_AGENT_ROLE"
export SNOWFLAKE_ROLE="$SNOWFLAKE_AGENT_ROLE"
export DB_TYPE="snowflake"
ENVFILE
    log "Saved environment to /tmp/snowflake_env.sh"
    
    log "Final environment:"
    log "  SNOWFLAKE_DATABASE: $SNOWFLAKE_DATABASE"
    log "  SNOWFLAKE_CLONE_NAME: $SNOWFLAKE_CLONE_NAME"
    log "  SNOWFLAKE_AGENT_ROLE: $SNOWFLAKE_AGENT_ROLE"
    
    log "=========================================="
    log "Snowflake clone setup COMPLETE"
    log "=========================================="
else
    #---------------------------------------------------------------------------
    # DUCKDB MODE: No setup needed (uses local file-based database)
    #---------------------------------------------------------------------------
    log "Using DuckDB backend - no Snowflake clone needed"
fi

#-------------------------------------------------------------------------------
# Create Ready Marker (signals that setup is complete)
#-------------------------------------------------------------------------------
# This file is checked by:
#   - /etc/profile.d/wait-for-init.sh (blocks login shells until ready)
#   - docker-compose healthcheck (marks container as "healthy")
#-------------------------------------------------------------------------------
log_step "4" "Creating ready marker"

touch /tmp/entrypoint_ready
log "Created /tmp/entrypoint_ready marker file"

# Verify all expected files were created
log "Verification:"
log "  /tmp/entrypoint_ready exists: $(test -f /tmp/entrypoint_ready && echo 'YES' || echo 'NO')"
log "  /tmp/snowflake_env.sh exists: $(test -f /tmp/snowflake_env.sh && echo 'YES' || echo 'NO')"
log "  /tmp/snowflake_clone_name.txt exists: $(test -f /tmp/snowflake_clone_name.txt && echo 'YES' || echo 'NO')"
log "  /tmp/snowflake_agent_role.txt exists: $(test -f /tmp/snowflake_agent_role.txt && echo 'YES' || echo 'NO')"

log "=========================================="
log "ENTRYPOINT COMPLETE - Container is ready"
log "=========================================="

#-------------------------------------------------------------------------------
# Execute Container Command (CMD from docker-compose or Dockerfile)
#-------------------------------------------------------------------------------
# Typically this is "sleep infinity" to keep container running
# Harbor then uses "docker exec" to run commands inside the container
#-------------------------------------------------------------------------------
if [ $# -gt 0 ]; then
    log "Executing command: $@"
    exec "$@"
else
    log "No command provided, starting bash shell"
    exec /bin/bash
fi