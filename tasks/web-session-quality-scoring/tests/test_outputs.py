import pytest
import subprocess
import os
from decimal import Decimal

# ============ DUAL-BACKEND INFRASTRUCTURE ============

MODEL_SCHEMA = "main"


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

def to_float(val):
    """Convert decimal.Decimal or other numeric types to float for comparison."""
    if val is None:
        return None
    return float(val)


def query_model(model_name, columns="*", where=None, order_by=None, limit=None):
    conn, db_type = get_db_connection()
    try:
        sql = f"SELECT {columns} FROM {MODEL_SCHEMA}.{model_name}"
        if where:
            sql += f" WHERE {where}"
        if order_by:
            sql += f" ORDER BY {order_by}"
        if limit:
            sql += f" LIMIT {limit}"
        return execute_query(conn, db_type, sql)
    finally:
        conn.close()


class TestModelExistence:
    """Test that all required models exist"""

    def test_int_session_engagement_exists(self):
        result = query_model("int_session_engagement", "COUNT(*)")
        assert result is not None

    def test_int_session_cart_activity_exists(self):
        result = query_model("int_session_cart_activity", "COUNT(*)")
        assert result is not None

    def test_session_quality_scores_exists(self):
        result = query_model("session_quality_scores", "COUNT(*)")
        assert result is not None

    def test_int_session_product_interest_exists(self):
        result = query_model("int_session_product_interest", "COUNT(*)")
        assert result is not None

    def test_visitor_product_affinity_exists(self):
        result = query_model("visitor_product_affinity", "COUNT(*)")
        assert result is not None

class TestIntSessionEngagement:
    """Test intermediate engagement metrics model"""

    def test_has_rows(self):
        result = query_model("int_session_engagement", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_session_ids(self):
        result = query_model("int_session_engagement", "COUNT(*)", where="session_id IS NULL")
        assert result[0][0] == 0, "No NULL session_ids allowed"

    def test_metrics_non_negative(self):
        result = query_model("int_session_engagement", "COUNT(*)",
            where="total_pageviews < 0 OR unique_pages_viewed < 0 OR product_page_views < 0 OR add_to_cart_events < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_unique_pages_not_exceed_total(self):
        result = query_model("int_session_engagement", "COUNT(*)",
            where="unique_pages_viewed > total_pageviews")
        assert result[0][0] == 0, "Unique pages should not exceed total pageviews"

class TestIntSessionCartActivity:
    """Test intermediate cart activity model"""

    def test_has_rows(self):
        result = query_model("int_session_cart_activity", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_session_ids(self):
        result = query_model("int_session_cart_activity", "COUNT(*)", where="session_id IS NULL")
        assert result[0][0] == 0, "No NULL session_ids allowed"

    def test_cart_created_is_boolean(self):
        result = query_model("int_session_cart_activity",
            "COUNT(DISTINCT cart_created)")
        row_count = result[0][0]
        assert row_count <= 2, "cart_created should only have TRUE/FALSE values"

    def test_cart_values_non_negative(self):
        result = query_model("int_session_cart_activity", "COUNT(*)",
            where="cart_item_count < 0 OR cart_subtotal < 0")
        assert result[0][0] == 0, "Cart values should be non-negative"

class TestSessionQualityScores:
    """Test final session quality scores model"""

    def test_has_rows(self):
        result = query_model("session_quality_scores", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_session_ids(self):
        result = query_model("session_quality_scores", "COUNT(*)", where="session_id IS NULL")
        assert result[0][0] == 0, "No NULL session_ids allowed"

    def test_no_null_engagement_scores(self):
        result = query_model("session_quality_scores", "COUNT(*)", where="engagement_score IS NULL")
        assert result[0][0] == 0, "No NULL engagement scores allowed"

    def test_no_null_conversion_probability(self):
        result = query_model("session_quality_scores", "COUNT(*)", where="conversion_probability IS NULL")
        assert result[0][0] == 0, "No NULL conversion probabilities allowed"

    def test_engagement_score_in_range(self):
        result = query_model("session_quality_scores",
            "COUNT(*)", where="engagement_score < 0 OR engagement_score > 100")
        assert result[0][0] == 0, "Engagement score must be between 0 and 100"

    def test_conversion_probability_in_range(self):
        result = query_model("session_quality_scores",
            "COUNT(*)", where="conversion_probability < 0.0 OR conversion_probability > 1.0")
        assert result[0][0] == 0, "Conversion probability must be between 0.0 and 1.0"

    def test_quality_tier_values(self):
        result = query_model("session_quality_scores",
            "COUNT(DISTINCT session_quality_tier)")
        distinct_count = result[0][0]
        assert distinct_count <= 3, "Should only have HIGH, MEDIUM, LOW tiers"

        result = query_model("session_quality_scores",
            "COUNT(*)", where="session_quality_tier NOT IN ('HIGH', 'MEDIUM', 'LOW')")
        assert result[0][0] == 0, "Quality tier must be HIGH, MEDIUM, or LOW"

    def test_bounce_type_values(self):
        result = query_model("session_quality_scores", "COUNT(*)",
            where="bounce_type IS NOT NULL AND bounce_type NOT IN ('IMMEDIATE', 'SHORT_VISIT')")
        assert result[0][0] == 0, "Bounce type must be IMMEDIATE, SHORT_VISIT, or NULL"

    def test_traffic_source_not_null(self):
        result = query_model("session_quality_scores", "COUNT(*)", where="traffic_source IS NULL")
        assert result[0][0] == 0, "Traffic source should default to 'direct' if NULL"

    def test_expected_value_calculation(self):
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT expected_value, conversion_probability
                FROM {MODEL_SCHEMA}.session_quality_scores WHERE conversion_probability > 0 LIMIT 1
            """)
            if result:
                expected_value, conversion_prob = result[0]
                calculated = round(float(conversion_prob) * 150.0, 2)
                assert abs(float(expected_value) - calculated) < 0.01, "Expected value should be conversion_probability * 150"
        finally:
            conn.close()

    def test_bounce_logic(self):
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                where = "CAST(is_bounce AS INTEGER) = 1 AND NOT (page_views = 1 AND session_duration_seconds < 10)"
            else:
                where = "is_bounce = TRUE AND NOT (page_views = 1 AND session_duration_seconds < 10)"
            result = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.session_quality_scores WHERE {where}")
            assert result[0][0] == 0, "Bounce should only be TRUE for single page views with < 10 sec duration"
        finally:
            conn.close()

    def test_did_convert_is_boolean(self):
        result = query_model("session_quality_scores",
            "COUNT(DISTINCT did_convert)")
        distinct_count = result[0][0]
        assert distinct_count <= 2, "did_convert should only have TRUE/FALSE values"

    def test_recent_sessions_only(self):
        """Sessions should span at most 90 days (data-relative window)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT MIN(session_date), MAX(session_date)
                FROM {MODEL_SCHEMA}.session_quality_scores
            """)
            min_date, max_date = result[0]
            # Handle potential datetime vs date type mismatch
            from datetime import date
            if hasattr(min_date, 'date'):
                min_date = min_date.date()
            if hasattr(max_date, 'date'):
                max_date = max_date.date()
            days_diff = (max_date - min_date).days
            assert days_diff <= 90, f"Sessions should span at most 90 days, but found {days_diff} days"
        finally:
            conn.close()

    def test_one_row_per_session(self):
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT session_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.session_quality_scores
                GROUP BY session_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per session_id"
        finally:
            conn.close()

class TestCalculations:
    """Test calculation accuracy"""

    def test_session_duration_minutes_calculation(self):
        """Verify session_duration_minutes = session_duration_seconds / 60.0"""
        result = query_model("session_quality_scores",
            "session_duration_seconds, session_duration_minutes",
            limit=50)
        for row in result:
            seconds, minutes = row[0], row[1]
            expected_minutes = round(to_float(seconds) / 60.0, 2)
            assert abs(to_float(minutes) - expected_minutes) < 0.01, \
                f"Duration minutes {minutes} should equal {expected_minutes} (seconds {seconds} / 60)"

    def test_expected_value_calculation_formula(self):
        """Verify expected_value = conversion_probability * 150.0"""
        result = query_model("session_quality_scores",
            "conversion_probability, expected_value",
            limit=50)
        for row in result:
            conv_prob, expected_val = row[0], row[1]
            calculated = round(float(conv_prob) * 150.0, 2)
            assert abs(float(expected_val) - calculated) < 0.01, \
                f"Expected value {expected_val} should equal {calculated} (probability {conv_prob} * 150)"

    def test_engagement_score_components(self):
        """Verify engagement score calculation components"""
        conn, db_type = get_db_connection()
        try:
            # Test a few specific sessions
            result = execute_query(conn, db_type, f"""
                SELECT
                    s.session_id,
                    s.page_views,
                    s.session_duration_minutes,
                    e.product_page_views,
                    s.added_to_cart,
                    e.checkout_page_views,
                    e.avg_scroll_depth_percent,
                    e.search_events,
                    e.video_play_events,
                    s.unique_pages_viewed,
                    s.engagement_score
                FROM {MODEL_SCHEMA}.session_quality_scores s
                JOIN {MODEL_SCHEMA}.int_session_engagement e ON s.session_id = e.session_id
                WHERE s.engagement_score > 0
                LIMIT 10
            """)

            for row in result:
                session_id, page_views, duration_min, product_views, added_to_cart, \
                checkout_views, scroll_depth, search_events, video_events, unique_pages, actual_score = row

                # Calculate expected score components (capped values)
                page_score = min(to_float(page_views) or 0, 5) * 5
                duration_score = min(to_float(duration_min) or 0, 10) * 1.5
                product_score = 10 if (to_float(product_views) or 0) > 0 else 0
                cart_score = 15 if added_to_cart else 0
                checkout_score = 5 if (to_float(checkout_views) or 0) > 0 else 0
                scroll_score = 10 if (to_float(scroll_depth) or 0) >= 75 else (to_float(scroll_depth) or 0) / 10.0
                search_score = 5 if (to_float(search_events) or 0) > 0 else 0
                video_score = 5 if (to_float(video_events) or 0) > 0 else 0
                unique_page_score = 10 if (to_float(unique_pages) or 0) >= 3 else (to_float(unique_pages) or 0) * 3.0

                expected_score = min(100, round(
                    page_score + duration_score + product_score + cart_score +
                    checkout_score + scroll_score + search_score + video_score + unique_page_score,
                    2))

                # Allow small tolerance for rounding differences
                assert abs(to_float(actual_score) - expected_score) < 2.0, \
                    f"Session {session_id}: engagement_score {actual_score} differs from expected {expected_score}"
        finally:
            conn.close()

    def test_conversion_probability_logic(self):
        """Verify conversion probability follows the specified rules"""
        conn, db_type = get_db_connection()
        try:
            # Test various scenarios
            result = execute_query(conn, db_type, f"""
                SELECT
                    s.session_id,
                    s.did_convert,
                    e.checkout_page_views,
                    s.engagement_score,
                    s.added_to_cart,
                    e.product_page_views,
                    s.is_bounce,
                    s.conversion_probability
                FROM {MODEL_SCHEMA}.session_quality_scores s
                JOIN {MODEL_SCHEMA}.int_session_engagement e ON s.session_id = e.session_id
                LIMIT 50
            """)

            for row in result:
                session_id, did_convert, checkout_views, eng_score, added_to_cart, \
                product_views, is_bounce, actual_prob = row

                # Determine expected probability based on rules
                if did_convert:
                    expected_prob = 1.0
                elif (checkout_views or 0) > 0:
                    expected_prob = 0.85
                elif eng_score >= 80 and added_to_cart:
                    expected_prob = 0.75
                elif eng_score >= 70:
                    expected_prob = 0.65
                elif eng_score >= 60 and (product_views or 0) >= 3:
                    expected_prob = 0.55
                elif eng_score >= 50:
                    expected_prob = 0.45
                elif eng_score >= 40:
                    expected_prob = 0.30
                elif eng_score >= 30 and (product_views or 0) > 0:
                    expected_prob = 0.25
                elif eng_score >= 20:
                    expected_prob = 0.15
                elif not is_bounce:
                    expected_prob = 0.10
                else:
                    expected_prob = 0.05

                assert abs(float(actual_prob) - expected_prob) < 0.01, \
                    f"Session {session_id}: conversion_probability {actual_prob} should be {expected_prob}"
        finally:
            conn.close()

class TestBusinessLogic:
    """Test business logic and scoring"""

    def test_converted_sessions_have_high_probability(self):
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                where = "CAST(did_convert AS INTEGER) = 1 AND conversion_probability < 1.0"
            else:
                where = "did_convert = TRUE AND conversion_probability < 1.0"
            result = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.session_quality_scores WHERE {where}")
            assert result[0][0] == 0, "Converted sessions should have 1.0 conversion probability"
        finally:
            conn.close()

    def test_checkout_sessions_have_high_probability(self):
        """Sessions with checkout page views should have high conversion probability"""
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                bool_false = "CAST(s.did_convert AS INTEGER) = 0"
            else:
                bool_false = "s.did_convert = FALSE"
            # Get sessions with checkout views
            result = execute_query(conn, db_type, f"""
                SELECT s.session_id, s.conversion_probability
                FROM {MODEL_SCHEMA}.session_quality_scores s
                JOIN {MODEL_SCHEMA}.int_session_engagement e ON s.session_id = e.session_id
                WHERE e.checkout_page_views > 0 AND {bool_false}
                LIMIT 10
            """)

            for session_id, conv_prob in result:
                assert conv_prob >= 0.85, f"Session {session_id} with checkout views should have conversion_probability >= 0.85"
        finally:
            conn.close()

    def test_bounce_sessions_have_low_scores(self):
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                bounce_true = "CAST(is_bounce AS INTEGER) = 1"
            else:
                bounce_true = "is_bounce = TRUE"
            result = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.session_quality_scores WHERE {bounce_true} AND engagement_score > 30")
            bounce_with_high_score = result[0][0]
            # Most bounces should have low engagement
            total_bounces_result = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.session_quality_scores WHERE {bounce_true}")
            total_bounces = total_bounces_result[0][0]

            if total_bounces > 0:
                ratio = bounce_with_high_score / total_bounces
                assert ratio < 0.5, "Most bounces should have low engagement scores (< 30)"
        finally:
            conn.close()

    def test_cart_sessions_have_higher_scores(self):
        """Sessions with carts should generally have higher engagement than those without"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    AVG(CASE WHEN added_to_cart THEN engagement_score END) as avg_with_cart,
                    AVG(CASE WHEN NOT added_to_cart THEN engagement_score END) as avg_without_cart
                FROM {MODEL_SCHEMA}.session_quality_scores
            """)

            avg_with_cart, avg_without_cart = result[0]
            if avg_with_cart and avg_without_cart:
                assert avg_with_cart > avg_without_cart, "Average engagement score should be higher for sessions with cart"
        finally:
            conn.close()

    def test_quality_tier_alignment(self):
        """Quality tier should align with engagement score thresholds"""
        result = query_model("session_quality_scores", "COUNT(*)",
            where="(session_quality_tier = 'HIGH' AND engagement_score < 70) OR (session_quality_tier = 'MEDIUM' AND (engagement_score < 40 OR engagement_score >= 70)) OR (session_quality_tier = 'LOW' AND engagement_score >= 40)")
        assert result[0][0] == 0, "Quality tier should match engagement score thresholds"

class TestDataQuality:
    """Test overall data quality"""

    def test_reasonable_session_durations(self):
        """Session durations should be reasonable (not negative, not absurdly long)"""
        result = query_model("session_quality_scores",
            "COUNT(*)", where="session_duration_seconds < 0 OR session_duration_seconds > 86400")  # 24 hours
        assert result[0][0] == 0, "Session durations should be between 0 and 24 hours"

    def test_reasonable_page_views(self):
        """Page view counts should be reasonable"""
        result = query_model("session_quality_scores",
            "COUNT(*)", where="page_views < 1 OR page_views > 1000")
        assert result[0][0] == 0, "Page views should be between 1 and 1000"

    def test_cart_value_reasonable(self):
        """Cart values should be reasonable"""
        result = query_model("session_quality_scores",
            "COUNT(*)", where="cart_value < 0 OR cart_value > 100000")
        assert result[0][0] == 0, "Cart values should be between 0 and 100,000"

    def test_session_date_matches_start(self):
        """session_date should be the date portion of session_start"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT COUNT(*)
                FROM {MODEL_SCHEMA}.session_quality_scores
                WHERE session_date != CAST(session_start AS DATE)
            """)
            assert result[0][0] == 0, "session_date should match DATE(session_start)"
        finally:
            conn.close()

class TestIntSessionProductInterest:
    """Test intermediate product interest model"""

    def test_has_rows(self):
        result = query_model("int_session_product_interest", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_session_ids(self):
        result = query_model("int_session_product_interest", "COUNT(*)", where="session_id IS NULL")
        assert result[0][0] == 0, "No NULL session_ids allowed"

    def test_metrics_non_negative(self):
        result = query_model("int_session_product_interest", "COUNT(*)",
            where="unique_products_viewed < 0 OR products_added_to_cart < 0 OR products_wishlisted < 0 OR cart_item_quantity < 0 OR avg_product_price < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_has_high_value_item_is_boolean(self):
        result = query_model("int_session_product_interest",
            "COUNT(DISTINCT has_high_value_item)")
        row_count = result[0][0]
        assert row_count <= 2, "has_high_value_item should only have TRUE/FALSE values"

    def test_wishlist_to_cart_ratio_in_range(self):
        result = query_model("int_session_product_interest",
            "COUNT(*)", where="wishlist_to_cart_ratio < 0 OR wishlist_to_cart_ratio > 100")
        assert result[0][0] == 0, "wishlist_to_cart_ratio should be non-negative"

    def test_products_carted_not_exceed_quantity(self):
        """Products added to cart count should not exceed total quantity"""
        result = query_model("int_session_product_interest", "COUNT(*)",
            where="products_added_to_cart > cart_item_quantity AND cart_item_quantity > 0")
        assert result[0][0] == 0, "Distinct products should not exceed total item quantity"

    def test_product_interest_score_in_range(self):
        result = query_model("int_session_product_interest",
            "COUNT(*)", where="product_interest_score < 0 OR product_interest_score > 100")
        assert result[0][0] == 0, "Product interest score must be between 0 and 100"

    def test_no_null_product_interest_score(self):
        result = query_model("int_session_product_interest", "COUNT(*)", where="product_interest_score IS NULL")
        assert result[0][0] == 0, "No NULL product_interest_score allowed"

    def test_product_interest_score_calculation(self):
        """Verify product_interest_score = (views x 2) + (cart x 5) + (wishlist x 3), capped at 100"""
        result = query_model("int_session_product_interest",
            "unique_products_viewed, products_added_to_cart, products_wishlisted, product_interest_score",
            limit=50)
        for row in result:
            views, cart, wishlist, actual_score = row[0], row[1], row[2], row[3]
            expected_score = min(100, round((to_float(views) * 2) + (to_float(cart) * 5) + (to_float(wishlist) * 3), 2))
            assert abs(to_float(actual_score) - expected_score) < 0.01, \
                f"Product interest score {actual_score} should equal {expected_score} ((views {views} x 2) + (cart {cart} x 5) + (wishlist {wishlist} x 3))"

class TestVisitorProductAffinity:
    """Test visitor product affinity mart model"""

    def test_has_rows(self):
        result = query_model("visitor_product_affinity", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_visitor_ids(self):
        result = query_model("visitor_product_affinity", "COUNT(*)", where="visitor_id IS NULL")
        assert result[0][0] == 0, "No NULL visitor_ids allowed"

    def test_no_null_total_sessions(self):
        result = query_model("visitor_product_affinity", "COUNT(*)", where="total_sessions IS NULL")
        assert result[0][0] == 0, "No NULL total_sessions allowed"

    def test_no_null_dates(self):
        result = query_model("visitor_product_affinity", "COUNT(*)",
            where="first_session_date IS NULL OR last_session_date IS NULL")
        assert result[0][0] == 0, "No NULL session dates allowed"

    def test_total_sessions_positive(self):
        result = query_model("visitor_product_affinity", "COUNT(*)", where="total_sessions < 1")
        assert result[0][0] == 0, "Total sessions must be at least 1"

    def test_sessions_with_views_not_exceed_total(self):
        result = query_model("visitor_product_affinity", "COUNT(*)",
            where="sessions_with_product_views > total_sessions")
        assert result[0][0] == 0, "Sessions with product views should not exceed total sessions"

    def test_metrics_non_negative(self):
        result = query_model("visitor_product_affinity", "COUNT(*)",
            where="total_products_viewed < 0 OR total_products_carted < 0 OR total_products_wishlisted < 0 OR avg_products_per_session < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_cart_conversion_rate_in_range(self):
        result = query_model("visitor_product_affinity",
            "COUNT(*)", where="cart_conversion_rate < 0.0 OR cart_conversion_rate > 1.0")
        assert result[0][0] == 0, "Cart conversion rate must be between 0.0 and 1.0"

    def test_wishlist_preference_score_in_range(self):
        result = query_model("visitor_product_affinity",
            "COUNT(*)", where="wishlist_preference_score < 0.0 OR wishlist_preference_score > 1.0")
        assert result[0][0] == 0, "Wishlist preference score must be between 0.0 and 1.0"

    def test_high_value_shopper_is_boolean(self):
        result = query_model("visitor_product_affinity",
            "COUNT(DISTINCT high_value_shopper)")
        distinct_count = result[0][0]
        assert distinct_count <= 2, "high_value_shopper should only have TRUE/FALSE values"

    def test_date_logic(self):
        """First session date should be <= last session date"""
        result = query_model("visitor_product_affinity", "COUNT(*)",
            where="first_session_date > last_session_date")
        assert result[0][0] == 0, "First session date should be <= last session date"

    def test_days_active_calculation(self):
        """Verify days_active = last_session_date - first_session_date"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT first_session_date, last_session_date, days_active, total_sessions
                FROM {MODEL_SCHEMA}.visitor_product_affinity
                LIMIT 50
            """)

            for row in result:
                first_date, last_date, days_active, total_sessions = row
                expected_days = (last_date - first_date).days if total_sessions > 1 else 0
                assert days_active == expected_days, \
                    f"days_active {days_active} should equal {expected_days} (difference between {last_date} and {first_date})"
        finally:
            conn.close()

    def test_avg_products_per_session_calculation(self):
        """Verify avg_products_per_session = total_products_viewed / total_sessions"""
        result = query_model("visitor_product_affinity",
            "total_products_viewed, total_sessions, avg_products_per_session",
            limit=50)
        for row in result:
            total_viewed, total_sessions, avg_per_session = row[0], row[1], row[2]
            expected_avg = round(to_float(total_viewed) / to_float(total_sessions), 2)
            assert abs(to_float(avg_per_session) - expected_avg) < 0.01, \
                f"avg_products_per_session {avg_per_session} should equal {expected_avg} ({total_viewed} / {total_sessions})"

    def test_recent_visitors_only(self):
        """Visitors should have sessions spanning at most 90 days (data-relative window)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT MIN(first_session_date), MAX(last_session_date)
                FROM {MODEL_SCHEMA}.visitor_product_affinity
            """)
            min_date, max_date = result[0]
            # Handle potential datetime vs date type mismatch
            from datetime import date
            if hasattr(min_date, 'date'):
                min_date = min_date.date()
            if hasattr(max_date, 'date'):
                max_date = max_date.date()
            days_diff = (max_date - min_date).days
            assert days_diff <= 90, f"Visitors should have sessions spanning at most 90 days, but found {days_diff} days"
        finally:
            conn.close()

    def test_one_row_per_visitor(self):
        """Should have exactly one row per visitor_id"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT visitor_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.visitor_product_affinity
                GROUP BY visitor_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per visitor_id"
        finally:
            conn.close()

    def test_browse_to_action_ratio_non_negative(self):
        result = query_model("visitor_product_affinity",
            "COUNT(*)", where="browse_to_action_ratio < 0")
        assert result[0][0] == 0, "browse_to_action_ratio should be non-negative"

    def test_browse_to_action_ratio_calculation(self):
        """Verify browse_to_action_ratio = total_products_viewed / (total_products_carted + total_products_wishlisted)"""
        result = query_model("visitor_product_affinity",
            "total_products_viewed, total_products_carted, total_products_wishlisted, browse_to_action_ratio",
            limit=50)
        for row in result:
            viewed, carted, wishlisted, actual_ratio = row[0], row[1], row[2], row[3]
            actions = to_float(carted) + to_float(wishlisted)
            expected_ratio = 0 if actions == 0 else round(to_float(viewed) / actions, 2)
            assert abs(to_float(actual_ratio) - expected_ratio) < 0.01, \
                f"browse_to_action_ratio {actual_ratio} should equal {expected_ratio} ({viewed} / ({carted} + {wishlisted}))"

    def test_visitor_segment_values(self):
        result = query_model("visitor_product_affinity",
            "COUNT(*)", where="visitor_segment NOT IN ('CONVERTER', 'BROWSER', 'RESEARCHER', 'CASUAL')")
        assert result[0][0] == 0, "visitor_segment must be CONVERTER, BROWSER, RESEARCHER, or CASUAL"

    def test_no_null_visitor_segment(self):
        result = query_model("visitor_product_affinity", "COUNT(*)", where="visitor_segment IS NULL")
        assert result[0][0] == 0, "No NULL visitor_segment allowed"

    def test_visitor_segment_logic(self):
        """Verify visitor_segment categorization follows the rules"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    visitor_id,
                    cart_conversion_rate,
                    browse_to_action_ratio,
                    wishlist_preference_score,
                    visitor_segment,
                    total_products_carted,
                    total_products_wishlisted
                FROM {MODEL_SCHEMA}.visitor_product_affinity
                LIMIT 50
            """)

            for row in result:
                visitor_id, cart_rate, browse_ratio, wishlist_pref, segment, carted, wishlisted = row

                # Determine expected segment
                if cart_rate >= 0.5:
                    expected_segment = 'CONVERTER'
                elif browse_ratio >= 5.0 and cart_rate < 0.5 and (carted + wishlisted) > 0:
                    expected_segment = 'BROWSER'
                elif wishlist_pref >= 0.6:
                    expected_segment = 'RESEARCHER'
                else:
                    expected_segment = 'CASUAL'

                assert segment == expected_segment, \
                    f"Visitor {visitor_id}: segment '{segment}' should be '{expected_segment}' (cart_rate={cart_rate}, browse_ratio={browse_ratio}, wishlist_pref={wishlist_pref})"
        finally:
            conn.close()
