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

    def test_int_transaction_velocity_exists(self):
        """Verify int_transaction_velocity model exists and can be queried"""
        result = query_model("int_transaction_velocity", "COUNT(*)")
        assert result is not None

    def test_int_payment_patterns_exists(self):
        """Verify int_payment_patterns model exists and can be queried"""
        result = query_model("int_payment_patterns", "COUNT(*)")
        assert result is not None

    def test_int_customer_address_risk_exists(self):
        """Verify int_customer_address_risk model exists and can be queried"""
        result = query_model("int_customer_address_risk", "COUNT(*)")
        assert result is not None

    def test_transaction_risk_scores_exists(self):
        """Verify transaction_risk_scores model exists and can be queried"""
        result = query_model("transaction_risk_scores", "COUNT(*)")
        assert result is not None

    def test_customer_risk_profile_exists(self):
        """Verify customer_risk_profile model exists and can be queried"""
        result = query_model("customer_risk_profile", "COUNT(*)")
        assert result is not None


class TestIntTransactionVelocity:
    """Test intermediate transaction velocity model"""

    def test_has_rows(self):
        """Verify int_transaction_velocity has at least one row"""
        result = query_model("int_transaction_velocity", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_customer_ids(self):
        """Verify no NULL values in customer_id column"""
        result = query_model("int_transaction_velocity", "COUNT(*)", where="customer_id IS NULL")
        assert result[0][0] == 0, "No NULL customer_ids allowed"

    def test_no_null_total_transactions(self):
        """Verify no NULL values in total_transactions column"""
        result = query_model("int_transaction_velocity", "COUNT(*)", where="total_transactions IS NULL")
        assert result[0][0] == 0, "No NULL total_transactions allowed"

    def test_total_transactions_positive(self):
        """Verify total_transactions is at least 1 for all customers"""
        result = query_model("int_transaction_velocity", "COUNT(*)", where="total_transactions < 1")
        assert result[0][0] == 0, "Total transactions must be at least 1"

    def test_metrics_non_negative(self):
        """Verify all monetary and count metrics are non-negative"""
        result = query_model("int_transaction_velocity", "COUNT(*)",
            where="total_amount < 0 OR avg_transaction_amount < 0 OR high_value_transaction_count < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_days_as_customer_non_negative(self):
        """Verify days_as_customer is non-negative"""
        result = query_model("int_transaction_velocity", "COUNT(*)", where="days_as_customer < 0")
        assert result[0][0] == 0, "days_as_customer should be non-negative"

    def test_date_logic(self):
        """First transaction date should be <= last transaction date"""
        result = query_model("int_transaction_velocity", "COUNT(*)",
            where="first_transaction_date > last_transaction_date")
        assert result[0][0] == 0, "First transaction date should be <= last transaction date"

    def test_one_row_per_customer(self):
        """Verify exactly one row per customer_id (no duplicates)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT customer_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.int_transaction_velocity
                GROUP BY customer_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per customer_id"
        finally:
            conn.close()


class TestIntPaymentPatterns:
    """Test intermediate payment patterns model"""

    def test_has_rows(self):
        """Verify int_payment_patterns has at least one row"""
        result = query_model("int_payment_patterns", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_customer_ids(self):
        """Verify no NULL values in customer_id column"""
        result = query_model("int_payment_patterns", "COUNT(*)", where="customer_id IS NULL")
        assert result[0][0] == 0, "No NULL customer_ids allowed"

    def test_no_null_total_payments(self):
        """Verify no NULL values in total_payments column"""
        result = query_model("int_payment_patterns", "COUNT(*)", where="total_payments IS NULL")
        assert result[0][0] == 0, "No NULL total_payments allowed"

    def test_no_null_failure_rate(self):
        """Verify no NULL values in payment_failure_rate column"""
        result = query_model("int_payment_patterns", "COUNT(*)", where="payment_failure_rate IS NULL")
        assert result[0][0] == 0, "No NULL payment_failure_rate allowed"

    def test_failure_rate_in_range(self):
        """Verify payment_failure_rate is between 0.0 and 1.0"""
        result = query_model("int_payment_patterns", "COUNT(*)",
            where="payment_failure_rate < 0.0 OR payment_failure_rate > 1.0")
        assert result[0][0] == 0, "payment_failure_rate must be between 0.0 and 1.0"

    def test_uses_multiple_cards_is_boolean(self):
        """Verify uses_multiple_cards contains only boolean values"""
        result = query_model("int_payment_patterns", "COUNT(DISTINCT uses_multiple_cards)")
        assert result[0][0] <= 2, "uses_multiple_cards should only have TRUE/FALSE values"

    def test_metrics_non_negative(self):
        """Verify all payment metrics are non-negative"""
        result = query_model("int_payment_patterns", "COUNT(*)",
            where="unique_payment_methods < 0 OR unique_cards < 0 OR successful_payments < 0 OR failed_payments < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_one_row_per_customer(self):
        """Verify exactly one row per customer_id (no duplicates)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT customer_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.int_payment_patterns
                GROUP BY customer_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per customer_id"
        finally:
            conn.close()


class TestIntCustomerAddressRisk:
    """Test intermediate customer address risk model"""

    def test_has_rows(self):
        """Verify int_customer_address_risk has at least one row"""
        result = query_model("int_customer_address_risk", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_customer_ids(self):
        """Verify no NULL values in customer_id column"""
        result = query_model("int_customer_address_risk", "COUNT(*)", where="customer_id IS NULL")
        assert result[0][0] == 0, "No NULL customer_ids allowed"

    def test_no_null_total_addresses(self):
        """Verify no NULL values in total_addresses column"""
        result = query_model("int_customer_address_risk", "COUNT(*)", where="total_addresses IS NULL")
        assert result[0][0] == 0, "No NULL total_addresses allowed"

    def test_verification_rate_in_range(self):
        """Verify address_verification_rate is between 0.0 and 1.0"""
        result = query_model("int_customer_address_risk", "COUNT(*)",
            where="address_verification_rate < 0.0 OR address_verification_rate > 1.0")
        assert result[0][0] == 0, "address_verification_rate must be between 0.0 and 1.0"

    def test_mismatch_rate_in_range(self):
        """Verify mismatch_rate is between 0.0 and 1.0"""
        result = query_model("int_customer_address_risk", "COUNT(*)",
            where="mismatch_rate < 0.0 OR mismatch_rate > 1.0")
        assert result[0][0] == 0, "mismatch_rate must be between 0.0 and 1.0"

    def test_metrics_non_negative(self):
        """Verify all address metrics are non-negative"""
        result = query_model("int_customer_address_risk", "COUNT(*)",
            where="verified_addresses < 0 OR unverified_addresses < 0 OR unique_countries < 0")
        assert result[0][0] == 0, "All metrics should be non-negative"

    def test_one_row_per_customer(self):
        """Verify exactly one row per customer_id (no duplicates)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT customer_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.int_customer_address_risk
                GROUP BY customer_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per customer_id"
        finally:
            conn.close()


class TestTransactionRiskScores:
    """Test transaction risk scores mart model"""

    def test_has_rows(self):
        """Verify transaction_risk_scores has at least one row"""
        result = query_model("transaction_risk_scores", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_order_ids(self):
        """Verify no NULL values in order_id column"""
        result = query_model("transaction_risk_scores", "COUNT(*)", where="order_id IS NULL")
        assert result[0][0] == 0, "No NULL order_ids allowed"

    def test_no_null_customer_ids(self):
        """Verify no NULL values in customer_id column"""
        result = query_model("transaction_risk_scores", "COUNT(*)", where="customer_id IS NULL")
        assert result[0][0] == 0, "No NULL customer_ids allowed"

    def test_no_null_risk_score(self):
        """Verify no NULL values in risk_score column"""
        result = query_model("transaction_risk_scores", "COUNT(*)", where="risk_score IS NULL")
        assert result[0][0] == 0, "No NULL risk_score allowed"

    def test_no_null_risk_tier(self):
        """Verify no NULL values in risk_tier column"""
        result = query_model("transaction_risk_scores", "COUNT(*)", where="risk_tier IS NULL")
        assert result[0][0] == 0, "No NULL risk_tier allowed"

    def test_risk_score_in_range(self):
        """Verify risk_score is between 0 and 100"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_score < 0 OR risk_score > 100")
        assert result[0][0] == 0, "risk_score must be between 0 and 100"

    def test_review_priority_in_range(self):
        """Verify review_priority is between 0 and 100"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="review_priority < 0 OR review_priority > 100")
        assert result[0][0] == 0, "review_priority must be between 0 and 100"

    def test_risk_tier_values(self):
        """Verify risk_tier contains only valid values (HIGH, MEDIUM, LOW)"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_tier NOT IN ('HIGH', 'MEDIUM', 'LOW')")
        assert result[0][0] == 0, "risk_tier must be HIGH, MEDIUM, or LOW"

    def test_risk_tier_alignment(self):
        """Risk tier should align with risk score thresholds"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="(risk_tier = 'HIGH' AND risk_score < 70) OR (risk_tier = 'MEDIUM' AND (risk_score < 40 OR risk_score >= 70)) OR (risk_tier = 'LOW' AND risk_score >= 40)")
        assert result[0][0] == 0, "Risk tier should match risk score thresholds"

    def test_requires_review_is_boolean(self):
        """Verify requires_review contains only boolean values"""
        result = query_model("transaction_risk_scores", "COUNT(DISTINCT requires_review)")
        assert result[0][0] <= 2, "requires_review should only have TRUE/FALSE values"

    def test_recent_transactions_only(self):
        """Transactions should be from last 90 days relative to max date"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT MIN(order_date), MAX(order_date)
                FROM {MODEL_SCHEMA}.transaction_risk_scores
            """)
            min_date, max_date = result[0]
            from datetime import date
            if hasattr(min_date, 'date'):
                min_date = min_date.date()
            if hasattr(max_date, 'date'):
                max_date = max_date.date()
            days_diff = (max_date - min_date).days
            assert days_diff <= 90, f"Transactions should span at most 90 days, but found {days_diff} days"
        finally:
            conn.close()

    def test_one_row_per_order(self):
        """Verify exactly one row per order_id (no duplicates)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT order_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.transaction_risk_scores
                GROUP BY order_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per order_id"
        finally:
            conn.close()


class TestCustomerRiskProfile:
    """Test customer risk profile mart model"""

    def test_has_rows(self):
        """Verify customer_risk_profile has at least one row"""
        result = query_model("customer_risk_profile", "COUNT(*)")
        assert result[0][0] > 0, "Model should have rows"

    def test_no_null_customer_ids(self):
        """Verify no NULL values in customer_id column"""
        result = query_model("customer_risk_profile", "COUNT(*)", where="customer_id IS NULL")
        assert result[0][0] == 0, "No NULL customer_ids allowed"

    def test_no_null_total_transactions(self):
        """Verify no NULL values in total_transactions column"""
        result = query_model("customer_risk_profile", "COUNT(*)", where="total_transactions IS NULL")
        assert result[0][0] == 0, "No NULL total_transactions allowed"

    def test_no_null_overall_risk_score(self):
        """Verify no NULL values in overall_risk_score column"""
        result = query_model("customer_risk_profile", "COUNT(*)", where="overall_risk_score IS NULL")
        assert result[0][0] == 0, "No NULL overall_risk_score allowed"

    def test_no_null_risk_segment(self):
        """Verify no NULL values in risk_segment column"""
        result = query_model("customer_risk_profile", "COUNT(*)", where="risk_segment IS NULL")
        assert result[0][0] == 0, "No NULL risk_segment allowed"

    def test_overall_risk_score_in_range(self):
        """Verify overall_risk_score is between 0 and 100"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="overall_risk_score < 0 OR overall_risk_score > 100")
        assert result[0][0] == 0, "overall_risk_score must be between 0 and 100"

    def test_component_scores_in_range(self):
        """Verify all component risk scores are between 0 and 100"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="velocity_risk_score < 0 OR velocity_risk_score > 100 OR payment_risk_score < 0 OR payment_risk_score > 100 OR address_risk_score < 0 OR address_risk_score > 100")
        assert result[0][0] == 0, "All component risk scores must be between 0 and 100"

    def test_risk_segment_values(self):
        """Verify risk_segment contains only valid values"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment NOT IN ('HIGH_RISK', 'WATCH_LIST', 'ELEVATED', 'TRUSTED', 'NEW', 'STANDARD')")
        assert result[0][0] == 0, "risk_segment must be one of the valid values"

    def test_one_row_per_customer(self):
        """Verify exactly one row per customer_id (no duplicates)"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT customer_id, COUNT(*) as cnt
                FROM {MODEL_SCHEMA}.customer_risk_profile
                GROUP BY customer_id
                HAVING COUNT(*) > 1
            """)
            assert len(result) == 0, "Should have exactly one row per customer_id"
        finally:
            conn.close()

    def test_payment_failure_rate_in_range(self):
        """Verify payment_failure_rate is between 0.0 and 1.0"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="payment_failure_rate < 0.0 OR payment_failure_rate > 1.0")
        assert result[0][0] == 0, "payment_failure_rate must be between 0.0 and 1.0"

    def test_uses_multiple_cards_is_boolean(self):
        """Verify uses_multiple_cards contains only boolean values"""
        result = query_model("customer_risk_profile", "COUNT(DISTINCT uses_multiple_cards)")
        assert result[0][0] <= 2, "uses_multiple_cards should only have TRUE/FALSE values"


class TestCalculations:
    """Test calculation accuracy"""

    def test_risk_score_components(self):
        """Verify risk score calculation at transaction level"""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    order_id,
                    is_high_value,
                    is_new_customer,
                    payment_status,
                    customer_failure_rate,
                    is_billing_shipping_match,
                    customer_address_verification_rate,
                    risk_score
                FROM {MODEL_SCHEMA}.transaction_risk_scores
                WHERE risk_score > 0
                LIMIT 20
            """)

            for row in result:
                order_id, is_high_value, is_new_customer, payment_status, \
                customer_failure_rate, is_billing_shipping_match, \
                customer_address_verification_rate, actual_score = row

                is_payment_failed = payment_status is not None and payment_status.upper() in ('FAILED', 'F')

                # Calculate expected score
                expected_score = 0
                if is_high_value:
                    expected_score += 15
                if is_new_customer:
                    expected_score += 20
                if is_payment_failed:
                    expected_score += 25
                if (customer_failure_rate or 0) > 0.3:
                    expected_score += 20
                if not is_billing_shipping_match:
                    expected_score += 15
                if (customer_address_verification_rate or 0) < 0.5:
                    expected_score += 10

                expected_score = min(100, expected_score)

                # Allow some tolerance
                assert abs(to_float(actual_score) - expected_score) < 15, \
                    f"Order {order_id}: risk_score {actual_score} differs significantly from expected ~{expected_score}"
        finally:
            conn.close()

    def test_overall_risk_score_formula(self):
        """Verify overall_risk_score = weighted combination of component scores"""
        result = query_model("customer_risk_profile",
            "velocity_risk_score, payment_risk_score, address_risk_score, overall_risk_score",
            limit=50)

        for row in result:
            velocity, payment, address, overall = row
            expected = min(100, round(
                to_float(velocity) * 0.30 +
                to_float(payment) * 0.40 +
                to_float(address) * 0.30,
            2))
            assert abs(to_float(overall) - expected) < 1.0, \
                f"overall_risk_score {overall} should equal {expected}"


class TestBusinessLogic:
    """Test business logic and segmentation"""

    def test_high_risk_transactions_flagged_for_review(self):
        """HIGH risk tier transactions should require review"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_tier = 'HIGH' AND requires_review = FALSE")
        assert result[0][0] == 0, "HIGH risk transactions should require review"

    def test_high_risk_segment_alignment(self):
        """HIGH_RISK segment should have overall_risk_score >= 70"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'HIGH_RISK' AND overall_risk_score < 70")
        assert result[0][0] == 0, "HIGH_RISK customers should have overall_risk_score >= 70"

    def test_trusted_segment_criteria(self):
        """TRUSTED segment should meet criteria"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'TRUSTED' AND (overall_risk_score >= 30 OR days_as_customer < 30 OR payment_failure_rate >= 0.1)")
        assert result[0][0] == 0, "TRUSTED customers should have low risk, long tenure, and low failure rate"

    def test_new_segment_criteria(self):
        """NEW segment should have days_as_customer < 30"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'NEW' AND days_as_customer >= 30")
        assert result[0][0] == 0, "NEW customers should have days_as_customer < 30"


class TestDataQuality:
    """Test overall data quality"""

    def test_reasonable_transaction_amounts(self):
        """Transaction amounts should be reasonable"""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="transaction_amount < 0 OR transaction_amount > 1000000")
        assert result[0][0] == 0, "Transaction amounts should be between 0 and 1,000,000"

    def test_reasonable_total_transactions(self):
        """Total transactions per customer should be reasonable"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="total_transactions < 1 OR total_transactions > 10000")
        assert result[0][0] == 0, "Total transactions should be between 1 and 10,000"

    def test_date_consistency(self):
        """First transaction date should be <= last transaction date"""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="first_transaction_date > last_transaction_date")
        assert result[0][0] == 0, "First transaction date should be <= last transaction date"


class TestStrictRiskScoreFormula:
    """Strict validation of risk_score formula for transaction_risk_scores.

    For sampled rows, recompute the expected risk_score from component flags and
    verify it matches the stored value exactly (within rounding tolerance).
    """

    def test_risk_score_formula_exact(self):
        """Recompute risk_score from component columns and verify exact match."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    order_id,
                    transaction_amount,
                    is_high_value,
                    is_new_customer,
                    payment_status,
                    customer_failure_rate,
                    customer_address_verification_rate,
                    is_billing_shipping_match,
                    risk_score
                FROM {MODEL_SCHEMA}.transaction_risk_scores
                LIMIT 100
            """)

            assert len(result) > 0, "Need rows to validate formula"

            for row in result:
                (order_id, txn_amount, is_high_value, is_new_customer,
                 payment_status, cust_failure_rate,
                 cust_addr_verif_rate, is_billing_shipping_match,
                 actual_score) = row

                expected = 0

                # High value transaction (>500): 15 points
                if is_high_value:
                    expected += 15

                # New customer (<=2 transactions): 20 points
                if is_new_customer:
                    expected += 20

                # Payment failure: 25 points
                if payment_status is not None and str(payment_status).upper() in ('FAILED', 'F'):
                    expected += 25

                # Customer failure rate > 0.3: 20 points
                if to_float(cust_failure_rate or 0) > 0.3:
                    expected += 20

                # Multiple cards: 10 points - need to check from intermediate
                # We cannot check uses_multiple_cards here directly; it is not
                # on the transaction_risk_scores table. Instead query it.
                cust_id_result = execute_query(conn, db_type, f"""
                    SELECT customer_id FROM {MODEL_SCHEMA}.transaction_risk_scores
                    WHERE order_id = '{order_id}'
                """)
                customer_id = cust_id_result[0][0]

                mc_result = execute_query(conn, db_type, f"""
                    SELECT uses_multiple_cards
                    FROM {MODEL_SCHEMA}.int_payment_patterns
                    WHERE customer_id = '{customer_id}'
                """)
                uses_multiple_cards = mc_result[0][0] if mc_result else False

                if uses_multiple_cards:
                    expected += 10

                # Address mismatch: 15 points if billing != shipping
                if not is_billing_shipping_match:
                    expected += 15

                # Low address verification (<0.5): 10 points
                if to_float(cust_addr_verif_rate or 0) < 0.5:
                    expected += 10

                # Multiple countries: 10 points
                mc_country_result = execute_query(conn, db_type, f"""
                    SELECT has_multiple_countries
                    FROM {MODEL_SCHEMA}.int_customer_address_risk
                    WHERE customer_id = '{customer_id}'
                """)
                has_multiple_countries = mc_country_result[0][0] if mc_country_result else False

                if has_multiple_countries:
                    expected += 10

                # Cap at 100
                expected = min(100, expected)

                assert to_float(actual_score) == pytest.approx(expected, abs=0.01), \
                    (f"Order {order_id}: risk_score mismatch. "
                     f"Actual={to_float(actual_score)}, Expected={expected}. "
                     f"is_high_value={is_high_value}, is_new_customer={is_new_customer}, "
                     f"payment_status={payment_status}, failure_rate={cust_failure_rate}, "
                     f"uses_multiple_cards={uses_multiple_cards}, "
                     f"is_billing_shipping_match={is_billing_shipping_match}, "
                     f"addr_verif_rate={cust_addr_verif_rate}, "
                     f"has_multiple_countries={has_multiple_countries}")
        finally:
            conn.close()


class TestStrictRiskTierConsistency:
    """Verify risk_tier matches risk_score thresholds for ALL rows."""

    def test_high_tier_exact_threshold(self):
        """Every row with risk_score >= 70 must have risk_tier = 'HIGH'."""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_score >= 70 AND risk_tier != 'HIGH'")
        assert result[0][0] == 0, \
            "All rows with risk_score >= 70 must have risk_tier = 'HIGH'"

    def test_medium_tier_exact_threshold(self):
        """Every row with 40 <= risk_score < 70 must have risk_tier = 'MEDIUM'."""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_score >= 40 AND risk_score < 70 AND risk_tier != 'MEDIUM'")
        assert result[0][0] == 0, \
            "All rows with 40 <= risk_score < 70 must have risk_tier = 'MEDIUM'"

    def test_low_tier_exact_threshold(self):
        """Every row with risk_score < 40 must have risk_tier = 'LOW'."""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_score < 40 AND risk_tier != 'LOW'")
        assert result[0][0] == 0, \
            "All rows with risk_score < 40 must have risk_tier = 'LOW'"

    def test_risk_tier_complete_coverage(self):
        """Total rows matching tier rules must equal total row count (no gaps)."""
        conn, db_type = get_db_connection()
        try:
            total = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores")[0][0]
            high = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores WHERE risk_tier = 'HIGH' AND risk_score >= 70")[0][0]
            medium = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores WHERE risk_tier = 'MEDIUM' AND risk_score >= 40 AND risk_score < 70")[0][0]
            low = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores WHERE risk_tier = 'LOW' AND risk_score < 40")[0][0]
            assert high + medium + low == total, \
                f"Tier coverage incomplete: HIGH({high}) + MEDIUM({medium}) + LOW({low}) = {high+medium+low} != total({total})"
        finally:
            conn.close()


class TestStrictReviewPriorityWaterfall:
    """Verify review_priority follows the waterfall logic correctly for sampled rows."""

    def test_review_priority_waterfall_exact(self):
        """Recompute review_priority from risk_score and flags and verify exact match."""
        conn, db_type = get_db_connection()
        try:
            result = execute_query(conn, db_type, f"""
                SELECT
                    order_id,
                    risk_score,
                    is_high_value,
                    is_new_customer,
                    payment_status,
                    is_billing_shipping_match,
                    review_priority
                FROM {MODEL_SCHEMA}.transaction_risk_scores
                LIMIT 200
            """)

            assert len(result) > 0, "Need rows to validate waterfall"

            for row in result:
                (order_id, risk_score, is_high_value, is_new_customer,
                 payment_status, is_billing_shipping_match,
                 actual_priority) = row

                rs = to_float(risk_score)
                is_payment_failed = (payment_status is not None and
                                     str(payment_status).upper() in ('FAILED', 'F'))
                is_addr_mismatch = not is_billing_shipping_match

                # Waterfall logic (first match wins)
                if rs >= 80:
                    expected = 100
                elif rs >= 70 and is_high_value:
                    expected = 90
                elif rs >= 60 and is_new_customer:
                    expected = 85
                elif rs >= 50 and is_payment_failed:
                    expected = 80
                elif rs >= 50:
                    expected = 70
                elif rs >= 40 and is_addr_mismatch:
                    expected = 65
                elif rs >= 40:
                    expected = 50
                elif rs >= 30:
                    expected = 30
                else:
                    expected = 10

                assert to_float(actual_priority) == pytest.approx(expected, abs=0.01), \
                    (f"Order {order_id}: review_priority mismatch. "
                     f"Actual={to_float(actual_priority)}, Expected={expected}. "
                     f"risk_score={rs}, is_high_value={is_high_value}, "
                     f"is_new_customer={is_new_customer}, "
                     f"payment_status={payment_status}, "
                     f"is_billing_shipping_match={is_billing_shipping_match}")
        finally:
            conn.close()


class TestStrictRequiresReviewConsistency:
    """Verify requires_review = TRUE iff risk_tier = 'HIGH' OR review_priority >= 80."""

    def test_requires_review_true_conditions(self):
        """Every row where risk_tier='HIGH' OR review_priority>=80 must have requires_review=TRUE."""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="(risk_tier = 'HIGH' OR review_priority >= 80) AND requires_review = FALSE")
        assert result[0][0] == 0, \
            "requires_review must be TRUE when risk_tier='HIGH' or review_priority >= 80"

    def test_requires_review_false_conditions(self):
        """Every row where risk_tier!='HIGH' AND review_priority<80 must have requires_review=FALSE."""
        result = query_model("transaction_risk_scores", "COUNT(*)",
            where="risk_tier != 'HIGH' AND review_priority < 80 AND requires_review = TRUE")
        assert result[0][0] == 0, \
            "requires_review must be FALSE when risk_tier != 'HIGH' and review_priority < 80"

    def test_requires_review_exhaustive(self):
        """Total TRUE + FALSE requires_review must equal total rows (no NULLs)."""
        conn, db_type = get_db_connection()
        try:
            total = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores")[0][0]
            null_count = execute_query(conn, db_type,
                f"SELECT COUNT(*) FROM {MODEL_SCHEMA}.transaction_risk_scores WHERE requires_review IS NULL")[0][0]
            assert null_count == 0, \
                f"Found {null_count} NULL requires_review values out of {total} rows"
        finally:
            conn.close()


class TestStrictCustomerRiskProfileScoresBounded:
    """Verify all component and overall risk scores are between 0 and 100 inclusive."""

    def test_velocity_risk_score_bounded(self):
        """velocity_risk_score must be between 0 and 100 inclusive for ALL rows."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="velocity_risk_score < 0 OR velocity_risk_score > 100")
        assert result[0][0] == 0, "velocity_risk_score must be in [0, 100]"

    def test_payment_risk_score_bounded(self):
        """payment_risk_score must be between 0 and 100 inclusive for ALL rows."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="payment_risk_score < 0 OR payment_risk_score > 100")
        assert result[0][0] == 0, "payment_risk_score must be in [0, 100]"

    def test_address_risk_score_bounded(self):
        """address_risk_score must be between 0 and 100 inclusive for ALL rows."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="address_risk_score < 0 OR address_risk_score > 100")
        assert result[0][0] == 0, "address_risk_score must be in [0, 100]"

    def test_overall_risk_score_bounded(self):
        """overall_risk_score must be between 0 and 100 inclusive for ALL rows."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="overall_risk_score < 0 OR overall_risk_score > 100")
        assert result[0][0] == 0, "overall_risk_score must be in [0, 100]"

    def test_no_null_component_scores(self):
        """No component risk scores should be NULL."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="velocity_risk_score IS NULL OR payment_risk_score IS NULL OR address_risk_score IS NULL")
        assert result[0][0] == 0, "Component risk scores must not be NULL"

    def test_score_values_are_numeric(self):
        """Verify scores are usable as floats for sampled rows."""
        result = query_model("customer_risk_profile",
            "velocity_risk_score, payment_risk_score, address_risk_score, overall_risk_score",
            limit=50)
        for row in result:
            for i, col_name in enumerate(
                ["velocity_risk_score", "payment_risk_score",
                 "address_risk_score", "overall_risk_score"]):
                val = to_float(row[i])
                assert val is not None, f"{col_name} should not be None"
                assert 0.0 <= val <= 100.0, \
                    f"{col_name}={val} out of [0, 100] range"


class TestStrictRiskSegmentValidity:
    """Verify risk_segment only contains valid values and follows segmentation rules."""

    VALID_SEGMENTS = {'HIGH_RISK', 'WATCH_LIST', 'ELEVATED', 'TRUSTED', 'NEW', 'STANDARD'}

    def test_only_valid_segment_values(self):
        """risk_segment must only contain values from the defined set."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment NOT IN ('HIGH_RISK', 'WATCH_LIST', 'ELEVATED', 'TRUSTED', 'NEW', 'STANDARD')")
        assert result[0][0] == 0, \
            f"risk_segment must be one of {self.VALID_SEGMENTS}"

    def test_high_risk_segment_rule(self):
        """HIGH_RISK: overall_risk_score >= 70."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'HIGH_RISK' AND overall_risk_score < 70")
        assert result[0][0] == 0, "HIGH_RISK segment requires overall_risk_score >= 70"

    def test_watch_list_segment_rule(self):
        """WATCH_LIST: overall_risk_score >= 50 AND < 70."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'WATCH_LIST' AND (overall_risk_score < 50 OR overall_risk_score >= 70)")
        assert result[0][0] == 0, "WATCH_LIST segment requires 50 <= overall_risk_score < 70"

    def test_elevated_segment_rule(self):
        """ELEVATED: overall_risk_score >= 30 AND < 50."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'ELEVATED' AND (overall_risk_score < 30 OR overall_risk_score >= 50)")
        assert result[0][0] == 0, "ELEVATED segment requires 30 <= overall_risk_score < 50"

    def test_trusted_segment_rule(self):
        """TRUSTED: overall_risk_score < 30 AND days_as_customer >= 30 AND payment_failure_rate < 0.1."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'TRUSTED' AND (overall_risk_score >= 30 OR days_as_customer < 30 OR payment_failure_rate >= 0.1)")
        assert result[0][0] == 0, \
            "TRUSTED segment requires score < 30, tenure >= 30 days, and failure_rate < 0.1"

    def test_new_segment_rule(self):
        """NEW: overall_risk_score < 30 AND days_as_customer < 30."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment = 'NEW' AND (overall_risk_score >= 30 OR days_as_customer >= 30)")
        assert result[0][0] == 0, \
            "NEW segment requires score < 30 and tenure < 30 days"

    def test_segment_mutual_exclusivity_by_score_ranges(self):
        """Customers with score >= 70 cannot be in LOW-score segments."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="overall_risk_score >= 70 AND risk_segment IN ('WATCH_LIST', 'ELEVATED', 'TRUSTED', 'NEW', 'STANDARD')")
        assert result[0][0] == 0, \
            "Customers with score >= 70 must be HIGH_RISK, not in a lower segment"

    def test_no_null_risk_segments(self):
        """No NULL risk_segment values allowed."""
        result = query_model("customer_risk_profile", "COUNT(*)",
            where="risk_segment IS NULL")
        assert result[0][0] == 0, "risk_segment must not be NULL"
