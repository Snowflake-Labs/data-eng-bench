"""
Test verifier for RFM Customer Segmentation task.
Multi-phase testing:
  Phase 1: Validate model structure and basic output
  Phase 2: Validate RFM scores are correctly calculated
  Phase 3: Validate segment assignments match expected distribution
  Phase 4: Test idempotency (re-run produces same results)
"""
import subprocess
import os
from collections import Counter
import pytest

# ============ EXPECTED VALUES ============

# Expected segment counts (with tolerance for NTILE edge cases)
# Wider ranges to account for NTILE bucket boundary variations
EXPECTED_SEGMENT_COUNTS = {
    'Champions': (30, 50),  # (min, max) expected range
    'Loyal Customers': (20, 40),
    'Potential Loyalists': (20, 35),
    'Need Attention': (15, 35),
    'Cannot Lose': (5, 20),
    'At Risk': (5, 20),
    'Promising': (5, 20),
    'About to Sleep': (5, 20),
    'Hibernating': (10, 25),
    'Lost': (0, 15),
    'Recent Customers': (5, 20),
    'Other': (15, 30),
}

EXPECTED_TOTAL_CUSTOMERS = 213
VALID_SEGMENTS = [
    'Champions', 'Loyal Customers', 'Potential Loyalists', 'Recent Customers',
    'Promising', 'Need Attention', 'About to Sleep', 'At Risk', 'Cannot Lose',
    'Hibernating', 'Lost', 'Other'
]

# Known high-value customers for spot checks
HIGH_VALUE_CUSTOMERS = [
    # (customer_id, expected_r_score, expected_f_score, expected_m_score, expected_segment)
    ('05e238d5-82ac-4683-baa3-b649026efd25', 5, 5, 5, 'Champions'),  # Highest monetary
    ('414ac645-cc7b-4613-9d3a-9b3e974d3c7a', 5, 5, 5, 'Champions'),  # Second highest
]

# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from file if available"""
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
    """Load private key from base64-encoded env var"""
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
    """Create a database connection based on DB_TYPE environment variable"""
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
            schema='rfm_analytics',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        if not os.path.exists(db_path):
            pytest.skip(f"Database not found at {db_path}")
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a query and return results, handling differences between DuckDB and Snowflake"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        return cursor.fetchall()
    else:
        # DuckDB
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


# ============ HELPERS ============

def run_cmd(cmd, cwd="/app/dbt_project"):
    """Run a shell command and return the result."""
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    """Run dbt run."""
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_rfm_segments():
    """Query rfm_segments model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                customer_id,
                customer_name,
                recency_days,
                frequency,
                monetary,
                r_score,
                f_score,
                m_score,
                rfm_score,
                rfm_segment
            FROM rfm_analytics.rfm_segments
            ORDER BY customer_id
        """)
        return rows
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    """Fixture that runs dbt once per test module."""
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def rfm_rows(dbt_run):
    """Fixture that provides rfm_segments rows after dbt run."""
    return query_rfm_segments()


# ============ VALIDATION HELPERS ============

def validate_columns():
    """Validate required columns exist in rfm_segments."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = 'rfm_analytics'
            AND lower(table_name) = 'rfm_segments'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {
            "customer_id", "customer_name", "recency_days", "frequency",
            "monetary", "r_score", "f_score", "m_score", "rfm_score", "rfm_segment"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in rfm_segments: {missing}"
        print(f"All required columns present: {required}")
    finally:
        conn.close()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure and basic output."""

    def test_columns_exist(self, dbt_run):
        """Validate required columns exist in rfm_segments."""
        print("\n" + "="*50)
        print("PHASE 1: Structure and Basic Validation")
        print("="*50)
        validate_columns()

    def test_no_nulls(self, rfm_rows):
        """Validate no NULL values in any column."""
        for row in rfm_rows:
            for i, val in enumerate(row):
                assert val is not None, f"NULL value found in row: {row}"
        print(f"No NULL values found in {len(rfm_rows)} rows")

    def test_unique_customers(self, rfm_rows):
        """Validate exactly one row per customer."""
        customer_ids = [row[0] for row in rfm_rows]
        duplicates = [cid for cid, count in Counter(customer_ids).items() if count > 1]
        assert not duplicates, f"Duplicate customer_ids found: {duplicates[:5]}"
        print(f"All {len(rfm_rows)} customers are unique")

    def test_customer_count(self, rfm_rows):
        """Validate total customer count."""
        actual = len(rfm_rows)
        assert actual == EXPECTED_TOTAL_CUSTOMERS, \
            f"Expected {EXPECTED_TOTAL_CUSTOMERS} customers, got {actual}"
        print(f"Customer count correct: {actual}")


class TestPhase2Scores:
    """Phase 2: Validate RFM scores are correctly calculated."""

    def test_scores_valid_range(self, rfm_rows):
        """Validate RFM scores are 1-5."""
        print("\n" + "="*50)
        print("PHASE 2: Score Validation")
        print("="*50)
        for row in rfm_rows:
            r_score, f_score, m_score = row[5], row[6], row[7]
            assert 1 <= r_score <= 5, f"Invalid r_score {r_score} for customer {row[0]}"
            assert 1 <= f_score <= 5, f"Invalid f_score {f_score} for customer {row[0]}"
            assert 1 <= m_score <= 5, f"Invalid m_score {m_score} for customer {row[0]}"
        print("All RFM scores are valid (1-5)")

    def test_rfm_score_format(self, rfm_rows):
        """Validate rfm_score is concatenated string like '555'."""
        for row in rfm_rows:
            r_score, f_score, m_score = row[5], row[6], row[7]
            rfm_score = row[8]
            expected = f"{r_score}{f_score}{m_score}"
            assert str(rfm_score) == expected, \
                f"Invalid rfm_score {rfm_score}, expected {expected} for customer {row[0]}"
        print("All rfm_score values correctly formatted")

    def test_recency_score_order(self, rfm_rows):
        """Validate recency scoring direction: lower recency_days = higher r_score."""
        by_r_score = {}
        for row in rfm_rows:
            r_score = row[5]
            recency = row[2]
            if r_score not in by_r_score:
                by_r_score[r_score] = []
            by_r_score[r_score].append(recency)

        if 5 in by_r_score and 1 in by_r_score:
            max_r5 = max(by_r_score[5])
            min_r1 = min(by_r_score[1])
            assert max_r5 < min_r1, \
                f"Recency scoring incorrect: r_score=5 max recency ({max_r5}) >= r_score=1 min recency ({min_r1})"
        print("Recency score direction validated (higher score = more recent)")

    def test_frequency_score_order(self, rfm_rows):
        """Validate frequency scoring direction: higher frequency = higher f_score."""
        by_f_score = {}
        for row in rfm_rows:
            f_score = row[6]
            frequency = row[3]
            if f_score not in by_f_score:
                by_f_score[f_score] = []
            by_f_score[f_score].append(frequency)

        if 5 in by_f_score and 1 in by_f_score:
            min_f5 = min(by_f_score[5])
            max_f1 = max(by_f_score[1])
            assert min_f5 > max_f1, \
                f"Frequency scoring incorrect: f_score=5 min freq ({min_f5}) <= f_score=1 max freq ({max_f1})"
        print("Frequency score direction validated (higher score = more frequent)")

    def test_monetary_score_order(self, rfm_rows):
        """Validate monetary scoring direction: higher monetary = higher m_score."""
        by_m_score = {}
        for row in rfm_rows:
            m_score = row[7]
            monetary = float(row[4])
            if m_score not in by_m_score:
                by_m_score[m_score] = []
            by_m_score[m_score].append(monetary)

        if 5 in by_m_score and 1 in by_m_score:
            min_m5 = min(by_m_score[5])
            max_m1 = max(by_m_score[1])
            assert min_m5 > max_m1, \
                f"Monetary scoring incorrect: m_score=5 min monetary ({min_m5}) <= m_score=1 max monetary ({max_m1})"
        print("Monetary score direction validated (higher score = higher spend)")


class TestPhase3Segments:
    """Phase 3: Validate segment assignments."""

    def test_segments_valid(self, rfm_rows):
        """Validate all segments are valid."""
        print("\n" + "="*50)
        print("PHASE 3: Segment Validation")
        print("="*50)
        for row in rfm_rows:
            segment = row[9]
            assert segment in VALID_SEGMENTS, f"Invalid segment '{segment}' for customer {row[0]}"
        print("All segments are valid")

    def test_segment_distribution(self, rfm_rows):
        """Validate segment distribution is reasonable."""
        segment_counts = Counter(row[9] for row in rfm_rows)
        print(f"Segment distribution: {dict(segment_counts)}")

        for segment, (min_count, max_count) in EXPECTED_SEGMENT_COUNTS.items():
            actual = segment_counts.get(segment, 0)
            assert min_count <= actual <= max_count, \
                f"Segment '{segment}' count {actual} outside expected range ({min_count}, {max_count})"
        print("Segment distribution within expected ranges")

    def test_high_value_customers(self, rfm_rows):
        """Spot-check specific high-value customers."""
        rows_by_id = {row[0]: row for row in rfm_rows}

        for cust_id, exp_r, exp_f, exp_m, exp_segment in HIGH_VALUE_CUSTOMERS:
            row = rows_by_id.get(cust_id)
            assert row is not None, f"High-value customer {cust_id} not found"

            r_score, f_score, m_score, segment = row[5], row[6], row[7], row[9]
            assert r_score == exp_r, \
                f"Customer {cust_id}: expected r_score={exp_r}, got {r_score}"
            assert f_score == exp_f, \
                f"Customer {cust_id}: expected f_score={exp_f}, got {f_score}"
            assert m_score == exp_m, \
                f"Customer {cust_id}: expected m_score={exp_m}, got {m_score}"
            assert segment == exp_segment, \
                f"Customer {cust_id}: expected segment={exp_segment}, got {segment}"
        print(f"High-value customer spot checks passed ({len(HIGH_VALUE_CUSTOMERS)} customers)")


class TestPhase4Idempotency:
    """Phase 4: Test idempotency (re-run produces same results)."""

    def test_idempotency(self, rfm_rows):
        """Test that re-running dbt produces the same results."""
        print("\n" + "="*50)
        print("PHASE 4: Idempotency Test")
        print("="*50)

        # Store current results
        rows_before = list(rfm_rows)

        # Re-run dbt
        run_dbt_pipeline()

        # Get new results
        rows_after = query_rfm_segments()

        # Compare
        assert len(rows_before) == len(rows_after), \
            f"Row count changed after re-run: {len(rows_before)} -> {len(rows_after)}"

        # Compare row by row (sorted by customer_id)
        for before, after in zip(rows_before, rows_after):
            assert before == after, \
                f"Row changed after re-run:\nBefore: {before}\nAfter: {after}"

        print(f"Idempotency verified: {len(rows_after)} rows unchanged after re-run")
        print("Phase 4 PASSED")
