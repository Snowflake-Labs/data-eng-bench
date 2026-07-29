"""
Test verifier for dbt_fix_customer_snapshot task.

Validates:
  1. SCD Type 2 snapshot correctness for customer data (Part 1)
  2. dim_customer_current derived model correctness (Part 2)
"""
import pytest
import subprocess
import os

# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from file if available."""
    env_file = '/tmp/snowflake_env.sh'
    if os.path.exists(env_file):
        result = subprocess.run(
            ['bash', '-c', f'source {env_file} && env'],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if '=' in line and line.startswith('SNOWFLAKE_'):
                key, _, value = line.partition('=')
                os.environ[key] = value


# Load Snowflake env vars at module import time
load_snowflake_env()


def get_private_key():
    """Load private key from base64-encoded env var."""
    import base64
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

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


def get_db_connection():
    """Create a database connection based on DB_TYPE environment variable."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

    if db_type == 'snowflake':
        import snowflake.connector
        # Try password auth first (many Snowflake accounts use password, not private key)
        password = os.environ.get('SNOWFLAKE_PASSWORD')
        if password:
            conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                host=os.environ.get('SNOWFLAKE_HOST') or None,
                user=os.environ['SNOWFLAKE_USER'],
                password=password,
                database=os.environ['SNOWFLAKE_DATABASE'],
                schema='main',
                warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
                role=os.environ.get('SNOWFLAKE_ROLE', None))
            return conn, 'snowflake'
        # Fall back to private key auth
        conn = snowflake.connector.connect(
            account=os.environ['SNOWFLAKE_ACCOUNT'],
            host=os.environ.get('SNOWFLAKE_HOST') or None,
            user=os.environ['SNOWFLAKE_USER'],
            private_key=get_private_key(),
            database=os.environ['SNOWFLAKE_DATABASE'],
            schema='main',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a query and return results as a list of tuples."""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        return cursor.fetchall()
    else:
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value."""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ FIXTURES ============


@pytest.fixture(scope="module")
def db_conn():
    """Create a database connection shared across all tests in this module."""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# Resolved at first call. The instruction says "place in the dbt project's
# `models/` directory" without specifying a subdirectory or schema, so agents
# legitimately materialize `dim_customer_current` to either `main` (if file
# is at models/dim_customer_current.sql) or `marts` (if at
# models/marts/.../dim_customer_current.sql). Verifier introspects which
# schema the agent picked rather than hardcoding `main`.
_DIM_SCHEMA_CACHE = None


def get_dim_schema(conn, db_type):
    global _DIM_SCHEMA_CACHE
    if _DIM_SCHEMA_CACHE is not None:
        return _DIM_SCHEMA_CACHE
    cur = conn.cursor()
    try:
        for sch in ('main', 'marts', 'analytics', 'dimensions'):
            cur.execute(
                f"SELECT COUNT(*) FROM information_schema.tables "
                f"WHERE lower(table_schema) = '{sch}' "
                f"AND lower(table_name) = 'dim_customer_current'"
            )
            row = cur.fetchone()
            if row and int(row[0]) > 0:
                _DIM_SCHEMA_CACHE = sch
                return sch
    finally:
        cur.close()
    _DIM_SCHEMA_CACHE = 'main'  # default; downstream test will fail with clear error
    return 'main'


# ============ PART 1: SNAPSHOT TESTS ============


def test_no_duplicate_current_customers(db_conn):
    """Each customer must appear exactly once in current (open) snapshot records.

    Duplicate current records would indicate the snapshot's unique_key is
    misconfigured or the strategy is producing redundant inserts.
    """
    conn, db_type = db_conn
    duplicates = execute_query(conn, db_type, """
        SELECT
            customer_id,
            COUNT(*) as cnt
        FROM snapshots.customer_snapshot
        WHERE dbt_valid_to IS NULL
        GROUP BY customer_id
        HAVING COUNT(*) > 1
    """)

    assert len(duplicates) == 0, \
        f"Found {len(duplicates)} customers with duplicate current records: {duplicates[:5]}"


def test_all_customers_have_current_record(db_conn):
    """Every customer in the source must have a current (open) snapshot record.

    If a customer exists in stg_customers but has no record with
    dbt_valid_to IS NULL, the snapshot is either filtering it out or
    incorrectly closing its record.
    """
    conn, db_type = db_conn
    missing = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.stg_customers src
        WHERE NOT EXISTS (
            SELECT 1
            FROM snapshots.customer_snapshot snap
            WHERE snap.customer_id = src.customer_id
              AND snap.dbt_valid_to IS NULL
        )
    """)

    assert int(missing) == 0, f"Found {missing} customers missing from current snapshot records"


def test_snapshot_has_scd_columns(db_conn):
    """The snapshot table must contain the standard dbt SCD Type 2 metadata columns."""
    conn, db_type = db_conn
    required_cols = ['dbt_scd_id', 'dbt_updated_at', 'dbt_valid_from', 'dbt_valid_to']

    result = execute_query(conn, db_type, """
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = 'snapshots'
          AND lower(table_name) = 'customer_snapshot'
    """)

    existing_cols = [row[0].lower() for row in result]

    for col in required_cols:
        assert col.lower() in existing_cols, f"Required SCD column '{col}' is missing"


def test_current_records_have_null_valid_to(db_conn):
    """The count of open snapshot records must equal the source customer count.

    Every source customer should have exactly one record with dbt_valid_to
    IS NULL, meaning the snapshot covers all customers without omissions.
    """
    conn, db_type = db_conn
    current_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot
        WHERE dbt_valid_to IS NULL
    """)

    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main.stg_customers
    """)

    assert int(current_count) == int(source_count), \
        f"Current record count mismatch: snapshot={current_count}, source={source_count}"


def test_historical_records_closed_properly(db_conn):
    """Historical records for deleted customers must have dbt_valid_to set.

    If a customer no longer exists in the source but still has an open
    snapshot record, invalidate_hard_deletes is not working correctly.
    """
    conn, db_type = db_conn
    invalid_historical = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot snap
        WHERE snap.dbt_valid_from < (SELECT MAX(dbt_valid_from) FROM snapshots.customer_snapshot)
          AND snap.dbt_valid_to IS NULL
          AND NOT EXISTS (
              SELECT 1
              FROM main.stg_customers src
              WHERE src.customer_id = snap.customer_id
          )
    """)

    assert int(invalid_historical) == 0, \
        f"Found {invalid_historical} historical records without dbt_valid_to set"


def test_valid_to_after_valid_from(db_conn):
    """When dbt_valid_to is set, it must be strictly after dbt_valid_from.

    A record where valid_to <= valid_from represents an impossible time
    range and indicates snapshot logic corruption.
    """
    conn, db_type = db_conn
    invalid_dates = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot
        WHERE dbt_valid_to IS NOT NULL
          AND dbt_valid_to <= dbt_valid_from
    """)

    assert int(invalid_dates) == 0, \
        f"Found {invalid_dates} records where dbt_valid_to <= dbt_valid_from"


def test_customer_historical_data(db_conn):
    """The snapshot must contain at least one record (basic sanity check)."""
    conn, db_type = db_conn
    total_records = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM snapshots.customer_snapshot
    """)

    assert int(total_records) > 0, "Snapshot should have at least some records"


def test_no_gaps_in_customer_history(db_conn):
    """Consecutive snapshot records for a customer must have no time gaps.

    For each customer, the dbt_valid_to of one record should equal the
    dbt_valid_from of the next record, ensuring continuous history.
    """
    conn, db_type = db_conn
    gaps = execute_scalar(conn, db_type, """
        WITH ordered_records AS (
            SELECT
                customer_id,
                dbt_valid_from,
                dbt_valid_to,
                LEAD(dbt_valid_from) OVER (
                    PARTITION BY customer_id
                    ORDER BY dbt_valid_from
                ) as next_valid_from
            FROM snapshots.customer_snapshot
        )
        SELECT COUNT(*)
        FROM ordered_records
        WHERE dbt_valid_to IS NOT NULL
          AND next_valid_from IS NOT NULL
          AND dbt_valid_to != next_valid_from
    """)

    assert int(gaps) == 0, \
        f"Found {gaps} gaps in customer history (dbt_valid_to != next dbt_valid_from)"


def test_snapshot_row_count_reasonable(db_conn):
    """The snapshot must have at least as many rows as the source table.

    Since the snapshot includes both current and historical records, its
    total row count should always be >= the source count.
    """
    conn, db_type = db_conn
    snapshot_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM snapshots.customer_snapshot
    """)

    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.stg_customers
    """)

    assert int(snapshot_count) >= int(source_count), \
        f"Snapshot has fewer records than source: snapshot={snapshot_count}, source={source_count}"


def test_customer_attributes_match_source(db_conn):
    """Current snapshot attributes must exactly match the source table.

    For every customer with an open snapshot record, the email,
    customer_type, and phone_primary columns must agree with stg_customers.
    """
    conn, db_type = db_conn
    mismatches = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot snap
        INNER JOIN main.stg_customers src
            ON snap.customer_id = src.customer_id
        WHERE snap.dbt_valid_to IS NULL
          AND (
              snap.email != src.email
              OR snap.customer_type != src.customer_type
              OR COALESCE(CAST(snap.phone_primary AS VARCHAR), '') != COALESCE(CAST(src.phone_primary AS VARCHAR), '')
          )
    """)

    assert int(mismatches) == 0, \
        f"Found {mismatches} current records with attributes not matching source"


def test_all_customers_have_scd_id(db_conn):
    """Every snapshot record must have a non-null, unique dbt_scd_id.

    The scd_id is dbt's internal hash key that uniquely identifies each
    version of a record. Nulls or duplicates indicate snapshot corruption.
    """
    conn, db_type = db_conn
    null_scd_ids = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot
        WHERE dbt_scd_id IS NULL
    """)

    assert int(null_scd_ids) == 0, f"Found {null_scd_ids} records with NULL dbt_scd_id"

    duplicate_scd_ids = execute_scalar(conn, db_type, """
        SELECT COUNT(*) - COUNT(DISTINCT dbt_scd_id)
        FROM snapshots.customer_snapshot
    """)

    assert int(duplicate_scd_ids) == 0, f"Found {duplicate_scd_ids} duplicate dbt_scd_ids"


def test_current_records_have_recent_valid_from(db_conn):
    """Current records should not have a dbt_valid_from older than the
    earliest snapshot entry, which would indicate a timestamp anomaly.
    """
    conn, db_type = db_conn
    old_current_records = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM snapshots.customer_snapshot
        WHERE dbt_valid_to IS NULL
          AND dbt_valid_from < (SELECT MIN(dbt_valid_from) FROM snapshots.customer_snapshot)
    """)

    assert int(old_current_records) == 0, \
        f"Found {old_current_records} current records with unexpectedly old dbt_valid_from dates"


def test_all_source_customers_present(db_conn):
    """Every customer from the source table must appear in the snapshot.

    The snapshot should contain a record for every single customer in
    stg_customers. If the snapshot has fewer distinct customers than the
    source, it means some customers are being excluded from change tracking.
    """
    conn, db_type = db_conn

    source_distinct = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT customer_id)
        FROM main.stg_customers
    """)

    snapshot_distinct = execute_scalar(conn, db_type, """
        SELECT COUNT(DISTINCT customer_id)
        FROM snapshots.customer_snapshot
    """)

    assert int(snapshot_distinct) == int(source_distinct), \
        f"Snapshot has {snapshot_distinct} distinct customers but source has {source_distinct}. " \
        f"The snapshot is missing {int(source_distinct) - int(snapshot_distinct)} customers."


def test_snapshot_not_filtering_customers(db_conn):
    """Identify specific customer_ids present in source but absent from snapshot.

    This would indicate an incorrect WHERE clause or join condition in the
    snapshot model that silently drops customers.
    """
    conn, db_type = db_conn

    missing_customers = execute_query(conn, db_type, """
        SELECT src.customer_id
        FROM main.stg_customers src
        WHERE src.customer_id NOT IN (
            SELECT DISTINCT customer_id
            FROM snapshots.customer_snapshot
        )
    """)

    assert len(missing_customers) == 0, \
        f"Found {len(missing_customers)} source customers missing from snapshot entirely. " \
        f"First 10 missing IDs: {[row[0] for row in missing_customers[:10]]}"


# ============ PART 2: dim_customer_current TESTS ============


def test_dim_customer_current_exists(db_conn):
    """The dim_customer_current table/view must exist and contain rows.

    This model should be created as a standard dbt model (not a snapshot)
    that reads from the customer_snapshot and produces a current-state
    dimension table with analytical columns.
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    row_count = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {schema}.dim_customer_current
    """)

    assert row_count is not None and int(row_count) > 0, \
        "dim_customer_current does not exist or has no rows"


def test_dim_current_columns(db_conn):
    """dim_customer_current must have the three required derived columns.

    These columns extend the raw snapshot data with analytical attributes:
      - days_since_last_update: integer days from dbt_valid_from to today
      - total_versions: count of all historical snapshot versions
      - is_recently_changed: boolean flag for changes within 30 days
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    result = execute_query(conn, db_type, f"""
        SELECT column_name
        FROM information_schema.columns
        WHERE lower(table_schema) = '{schema}'
          AND lower(table_name) = 'dim_customer_current'
    """)

    existing_cols = [row[0].lower() for row in result]

    required_cols = ['days_since_last_update', 'total_versions', 'is_recently_changed']
    for col in required_cols:
        assert col in existing_cols, \
            f"Required column '{col}' is missing from dim_customer_current. " \
            f"Found columns: {sorted(existing_cols)}"


def test_dim_current_one_row_per_customer(db_conn):
    """dim_customer_current must have exactly one row per customer_id.

    The model should filter to only current snapshot records (dbt_valid_to
    IS NULL) and produce a clean 1:1 mapping from customer_id to its
    current dimensional attributes.
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    duplicates = execute_query(conn, db_type, f"""
        SELECT customer_id, COUNT(*) as cnt
        FROM {schema}.dim_customer_current
        GROUP BY customer_id
        HAVING COUNT(*) > 1
    """)

    assert len(duplicates) == 0, \
        f"dim_customer_current has duplicate rows for {len(duplicates)} customers: {duplicates[:5]}"

    # Also verify the row count matches source
    dim_count = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*) FROM {schema}.dim_customer_current
    """)
    source_count = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.stg_customers
    """)

    assert int(dim_count) == int(source_count), \
        f"dim_customer_current has {dim_count} rows but source has {source_count} customers"


def test_days_since_last_update_non_negative(db_conn):
    """days_since_last_update must be >= 0 for every row.

    This column represents the number of days between the record's
    dbt_valid_from timestamp and the current date. Since dbt_valid_from
    is always in the past (or today), negative values would indicate a
    computation error.
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    negative_days = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {schema}.dim_customer_current
        WHERE days_since_last_update < 0
    """)

    assert int(negative_days) == 0, \
        f"Found {negative_days} rows with negative days_since_last_update"


def test_total_versions_positive(db_conn):
    """total_versions must be >= 1 for every row.

    Every customer in dim_customer_current has at least one snapshot record
    (the current one), so the version count can never be zero or null.
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    invalid_versions = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {schema}.dim_customer_current
        WHERE total_versions < 1 OR total_versions IS NULL
    """)

    assert int(invalid_versions) == 0, \
        f"Found {invalid_versions} rows with total_versions < 1 or NULL"


def test_recently_changed_consistency(db_conn):
    """is_recently_changed must be logically consistent with days_since_last_update.

    The rule is: is_recently_changed should be true if and only if
    days_since_last_update <= 30. Any violation means the boolean flag
    and the day-count column are computed from different logic.
    """
    conn, db_type = db_conn
    schema = get_dim_schema(conn, db_type)

    # Check: is_recently_changed = true but days > 30
    false_positives = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {schema}.dim_customer_current
        WHERE UPPER(CAST(is_recently_changed AS VARCHAR)) IN ('TRUE', '1', 'T')
          AND days_since_last_update > 30
    """)

    assert int(false_positives) == 0, \
        f"Found {false_positives} rows marked recently changed but days_since_last_update > 30"

    # Check: is_recently_changed = false but days <= 30
    false_negatives = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*)
        FROM {schema}.dim_customer_current
        WHERE UPPER(CAST(is_recently_changed AS VARCHAR)) NOT IN ('TRUE', '1', 'T')
          AND days_since_last_update <= 30
    """)

    assert int(false_negatives) == 0, \
        f"Found {false_negatives} rows NOT marked recently changed but days_since_last_update <= 30"
