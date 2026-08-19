"""
Test verifier for Web Session Analytics Platform task.
Multi-phase testing for comprehensive validation.
"""
import subprocess
import os
from collections import Counter
import pytest

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
        # Try password auth first (the eval connection uses password, not private key)
        password = os.environ.get('SNOWFLAKE_PASSWORD')
        if password:
            conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
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
            **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
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
    """Execute a query and return results"""
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
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


# ============ EXPECTED VALUES ============

EXPECTED_TOTAL_SESSIONS = 5029
EXPECTED_BOUNCE_SESSIONS = 2530
EXPECTED_CONVERSIONS = 150

EXPECTED_DEVICE_TYPES = {'DESKTOP', 'MOBILE', 'TABLET'}
EXPECTED_DEVICE_COUNTS = {
    'DESKTOP': 2480,
    'MOBILE': 2061,
    'TABLET': 488,
}

VALID_QUALITY_TIERS = ['Premium', 'High', 'Medium', 'Low']
VALID_VELOCITY_CATEGORIES = ['Fast', 'Normal', 'Slow', None]
VALID_VISITOR_SEGMENTS = {'Power User', 'Regular', 'One-Time'}
# Note: Actual segments present depend on data distribution
# With current data, only 'One-Time' exists (all visitors have 1 session)

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
    """Run dbt run pipeline."""
    result = run_cmd("dbt run")
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def query_session_quality():
    """Query fct_session_quality model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                session_id, visitor_id, session_start, duration_seconds,
                page_views, is_bounce, is_converted, device_type,
                engagement_score, duration_score, quality_tier,
                engagement_velocity, velocity_category,
                visit_number, is_returning_visitor
            FROM web_analytics.fct_session_quality
            ORDER BY session_id
        """)
        return rows
    finally:
        conn.close()


def query_session_summary():
    """Query rpt_session_summary model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                device_type, total_sessions, total_conversions,
                conversion_rate, avg_duration, avg_page_views,
                bounce_rate, premium_sessions, high_sessions,
                returning_visitor_rate, avg_engagement_velocity
            FROM web_analytics.rpt_session_summary
            ORDER BY device_type
        """)
        return rows
    finally:
        conn.close()


def query_visitor_segments():
    """Query rpt_visitor_segments model."""
    conn, db_type = get_db_connection()
    try:
        rows = execute_query(conn, db_type, """
            SELECT
                visitor_segment, visitor_count, total_sessions,
                avg_sessions_per_visitor, total_conversions, conversion_rate
            FROM web_analytics.rpt_visitor_segments
            ORDER BY visitor_segment
        """)
        return rows
    finally:
        conn.close()


def _is_true(val):
    """Check if a value is truthy across both DuckDB and Snowflake.
    DuckDB may return True/False, Snowflake may return 1/0 or Decimal."""
    if val is None:
        return False
    if isinstance(val, bool):
        return val
    return int(val) == 1


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def quality_rows(dbt_run):
    return query_session_quality()


@pytest.fixture(scope="module")
def summary_rows(dbt_run):
    return query_session_summary()


@pytest.fixture(scope="module")
def segment_rows(dbt_run):
    return query_visitor_segments()


# ============ VALIDATION HELPERS ============

def validate_quality_columns():
    """Validate that fct_session_quality has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = 'web_analytics'
            AND lower(table_name) = 'fct_session_quality'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {
            "session_id", "visitor_id", "session_start", "duration_seconds",
            "page_views", "is_bounce", "is_converted", "device_type",
            "engagement_score", "duration_score", "quality_tier",
            "engagement_velocity", "velocity_category",
            "visit_number", "is_returning_visitor"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in fct_session_quality: {missing}"
    finally:
        conn.close()


def validate_summary_columns():
    """Validate that rpt_session_summary has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = 'web_analytics'
            AND lower(table_name) = 'rpt_session_summary'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {
            "device_type", "total_sessions", "total_conversions", "conversion_rate",
            "avg_duration", "avg_page_views", "bounce_rate", "premium_sessions",
            "high_sessions", "returning_visitor_rate", "avg_engagement_velocity"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in rpt_session_summary: {missing}"
    finally:
        conn.close()


def validate_segment_columns():
    """Validate that rpt_visitor_segments has all required columns."""
    conn, db_type = get_db_connection()
    try:
        cols = execute_query(conn, db_type, """
            SELECT column_name
            FROM information_schema.columns
            WHERE lower(table_schema) = 'web_analytics'
            AND lower(table_name) = 'rpt_visitor_segments'
        """)
        col_names = {c[0].lower() for c in cols}
        required = {
            "visitor_segment", "visitor_count", "total_sessions",
            "avg_sessions_per_visitor", "total_conversions", "conversion_rate"
        }
        missing = required - col_names
        assert not missing, f"Missing columns in rpt_visitor_segments: {missing}"
    finally:
        conn.close()


# ============ PYTEST TEST FUNCTIONS ============

class TestPhase1Structure:
    """Phase 1: Validate model structure."""

    def test_quality_columns_exist(self, dbt_run):
        """Verify fct_session_quality has all required columns."""
        print("\n" + "="*50)
        print("PHASE 1: Structure Validation")
        print("="*50)
        validate_quality_columns()

    def test_summary_columns_exist(self, dbt_run):
        """Verify rpt_session_summary has all required columns."""
        validate_summary_columns()

    def test_segment_columns_exist(self, dbt_run):
        """Verify rpt_visitor_segments has all required columns."""
        validate_segment_columns()

    def test_session_count(self, quality_rows):
        """Check that the total number of sessions matches the expected count."""
        actual = len(quality_rows)
        assert actual == EXPECTED_TOTAL_SESSIONS, \
            f"Expected {EXPECTED_TOTAL_SESSIONS} sessions, got {actual}"

    def test_unique_sessions(self, quality_rows):
        """Ensure all session_id values are unique with no duplicates."""
        session_ids = [row[0] for row in quality_rows]
        duplicates = [sid for sid, count in Counter(session_ids).items() if count > 1]
        assert not duplicates, f"Duplicate session_ids: {duplicates[:5]}"


class TestPhase2SessionQuality:
    """Phase 2: Validate session quality scoring."""

    def test_scores_valid_range(self, quality_rows):
        """Verify engagement_score and duration_score are between 1 and 5."""
        print("\n" + "="*50)
        print("PHASE 2: Session Quality Validation")
        print("="*50)
        for row in quality_rows:
            engagement_score, duration_score = int(row[8]), int(row[9])
            assert 1 <= engagement_score <= 5
            assert 1 <= duration_score <= 5

    def test_quality_tiers_valid(self, quality_rows):
        """Ensure all quality_tier values are in the allowed set."""
        for row in quality_rows:
            tier = row[10]
            assert tier in VALID_QUALITY_TIERS

    def test_bounce_count(self, quality_rows):
        """Verify the total number of bounce sessions matches the expected count."""
        bounce_count = sum(1 for row in quality_rows if _is_true(row[5]))
        assert bounce_count == EXPECTED_BOUNCE_SESSIONS

    def test_engagement_velocity_logic(self, quality_rows):
        """Validate engagement_velocity calculation."""
        for row in quality_rows:
            duration = int(row[3])
            page_views = int(row[4])
            velocity = float(row[11])

            if duration < 60:
                assert velocity == 0.0, f"Session {row[0]}: velocity should be 0 for duration < 60"
            else:
                expected = round(page_views / (duration / 60.0), 4)
                assert abs(velocity - expected) < 0.01, \
                    f"Session {row[0]}: velocity mismatch"

    def test_velocity_category_logic(self, quality_rows):
        """Validate velocity_category assignment."""
        for row in quality_rows:
            duration = int(row[3])
            velocity = float(row[11])
            category = row[12]

            if duration < 60:
                assert category is None
            elif velocity > 2:
                assert category == 'Fast'
            elif velocity >= 1:
                assert category == 'Normal'
            else:
                assert category == 'Slow'

    def test_visit_number_sequential(self, quality_rows):
        """Validate visit_number is sequential per visitor."""
        visitors = {}
        for row in quality_rows:
            visitor_id = row[1]
            session_start = row[2]
            visit_number = int(row[13])
            if visitor_id not in visitors:
                visitors[visitor_id] = []
            visitors[visitor_id].append((session_start, visit_number))

        for visitor_id, visits in visitors.items():
            visits.sort(key=lambda x: x[0])
            for i, (_, vn) in enumerate(visits, 1):
                assert vn == i, f"Visitor {visitor_id}: expected visit_number {i}, got {vn}"

    def test_is_returning_visitor(self, quality_rows):
        """Validate is_returning_visitor matches visit_number."""
        for row in quality_rows:
            visit_number = int(row[13])
            is_returning = _is_true(row[14])
            expected = visit_number > 1
            assert is_returning == expected


class TestPhase3Summary:
    """Phase 3: Validate session summary report."""

    def test_summary_device_types(self, summary_rows):
        """Check that the summary contains exactly the expected device types."""
        print("\n" + "="*50)
        print("PHASE 3: Summary Report Validation")
        print("="*50)
        device_types = {row[0] for row in summary_rows}
        assert device_types == EXPECTED_DEVICE_TYPES

    def test_summary_session_counts(self, summary_rows):
        """Validate session counts per device type match expected values."""
        for row in summary_rows:
            device_type = row[0]
            total_sessions = int(row[1])
            expected = EXPECTED_DEVICE_COUNTS.get(device_type)
            if expected:
                assert total_sessions == expected

    def test_summary_has_returning_visitor_rate(self, summary_rows):
        """Check that returning_visitor_rate is between 0 and 1 for each device type."""
        for row in summary_rows:
            rate = float(row[9])
            assert rate is not None
            assert 0 <= rate <= 1

    def test_summary_has_avg_velocity(self, summary_rows):
        """Verify avg_engagement_velocity is non-negative for each device type."""
        for row in summary_rows:
            avg_vel = float(row[10])
            assert avg_vel is not None
            assert avg_vel >= 0

    def test_summary_totals_match(self, summary_rows, quality_rows):
        """Ensure total sessions in the summary report match the quality table row count."""
        total_from_summary = sum(int(row[1]) for row in summary_rows)
        total_from_quality = len(quality_rows)
        assert total_from_summary == total_from_quality


class TestPhase4VisitorSegments:
    """Phase 4: Validate visitor segments report."""

    def test_segments_exist(self, segment_rows):
        """Verify at least one segment exists and all are valid visitor segment names."""
        print("\n" + "="*50)
        print("PHASE 4: Visitor Segments Validation")
        print("="*50)
        segments = {row[0] for row in segment_rows}
        # All segments should be valid (subset of VALID_VISITOR_SEGMENTS)
        assert segments.issubset(VALID_VISITOR_SEGMENTS), \
            f"Invalid segments: {segments - VALID_VISITOR_SEGMENTS}"
        # At least one segment should exist
        assert len(segments) >= 1, "No segments found"

    def test_segment_totals_match(self, segment_rows, quality_rows):
        """Total sessions from segments should match quality table."""
        total_sessions = sum(int(row[2]) for row in segment_rows)
        assert total_sessions == len(quality_rows)

    def test_segment_logic(self, segment_rows):
        """Validate segment classification logic."""
        for row in segment_rows:
            segment = row[0]
            avg_sessions = float(row[3])

            if segment == 'Power User':
                assert avg_sessions >= 5
            elif segment == 'Regular':
                assert 2 <= avg_sessions < 5
            elif segment == 'One-Time':
                assert avg_sessions == 1

    def test_segment_conversion_rates(self, segment_rows):
        """Validate conversion rates are valid."""
        for row in segment_rows:
            rate = float(row[5])
            assert 0 <= rate <= 1


class TestPhase5Idempotency:
    """Phase 5: Test idempotency."""

    def test_idempotency(self, quality_rows):
        """Verify that re-running the dbt pipeline produces identical session quality results."""
        print("\n" + "="*50)
        print("PHASE 5: Idempotency Test")
        print("="*50)
        rows_before = list(quality_rows)
        run_dbt_pipeline()
        rows_after = query_session_quality()

        assert len(rows_before) == len(rows_after)
        for before, after in zip(rows_before, rows_after):
            # Compare key fields with type-safe conversions
            assert before[0] == after[0], f"session_id mismatch"
            assert int(before[3]) == int(after[3]), f"duration_seconds mismatch"
            assert int(before[4]) == int(after[4]), f"page_views mismatch"
            assert int(before[8]) == int(after[8]), f"engagement_score mismatch"
            assert int(before[9]) == int(after[9]), f"duration_score mismatch"
            assert before[10] == after[10], f"quality_tier mismatch"
            assert abs(float(before[11]) - float(after[11])) < 0.001, f"engagement_velocity mismatch"
            assert before[12] == after[12], f"velocity_category mismatch"
