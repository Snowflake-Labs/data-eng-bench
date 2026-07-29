"""
Test verifier for Marketing Campaigns Dimensional Model task.
Multi-phase testing:
  Phase 1: Validate model structure and all required columns
  Phase 2: Validate intermediate layer aggregation logic
  Phase 3: Validate RFM scoring logic
  Phase 4: Validate dimension tables
  Phase 5: Validate fact table calculations
  Phase 6: Validate time-based aggregations
  Phase 7: Validate trend analysis
  Phase 8: Validate cohort analysis
  Phase 9: Test idempotency
"""
import subprocess
from collections import Counter
import os
import re
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
        private_key_pem, password=passphrase_bytes, backend=default_backend()
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ CONSTANTS ============


MODEL_SCHEMA = "main"

INTERMEDIATE_MODELS = [
    "int_campaign_performance_summary",
    "int_promotion_redemption_summary",
    "int_customer_rfm",
    "int_campaign_daily_stats",
    "int_channel_allocation",
    "int_customer_loyalty_summary",
    "int_gift_card_summary",
    "int_campaign_audience_summary",
    "int_promotion_rule_summary",
    "int_customer_cohort",
    "int_campaign_rolling_metrics",
]

MART_MODELS = [
    "dim_campaigns",
    "dim_promotions",
    "dim_marketing_customers",
    "dim_loyalty_programs",
    "dim_gift_cards",
    "fct_campaign_daily_performance",
    "fct_campaign_performance",
    "fct_promotion_performance",
    "fct_campaign_weekly_performance",
    "fct_campaign_monthly_performance",
    "fct_loyalty_performance",
    "fct_gift_card_performance",
    "fct_campaign_audience_performance",
    "bridge_campaign_channel",
    "fct_promotion_rule_analysis",
    "fct_customer_cohort_performance",
    "fct_campaign_trend_analysis",
]

ALL_MODELS = INTERMEDIATE_MODELS + MART_MODELS

REQUIRED_COLUMNS = {
    "int_campaign_performance_summary": [
        "campaign_id", "total_impressions", "total_clicks", "total_conversions",
        "total_spend", "total_revenue"
    ],
    "int_promotion_redemption_summary": [
        "promotion_id", "redemption_count", "total_discount_given"
    ],
    "int_customer_rfm": [
        "customer_id", "recency_days", "frequency", "monetary",
        "r_score", "f_score", "m_score", "rfm_segment"
    ],
    "int_campaign_daily_stats": [
        "campaign_id", "mean_spend", "stddev_spend"
    ],
    "int_channel_allocation": [
        "channel_mapping_id", "campaign_id", "channel_type", "allocated_budget",
        "campaign_total_revenue", "channel_efficiency"
    ],
    "int_customer_loyalty_summary": [
        "customer_id", "total_points_issued", "total_points_redeemed", "points_balance",
        "transaction_count", "first_transaction_date", "last_transaction_date"
    ],
    "int_gift_card_summary": [
        "gift_card_id", "total_loaded", "total_spent", "net_balance",
        "transaction_count", "first_transaction_date", "last_transaction_date"
    ],
    "int_campaign_audience_summary": [
        "campaign_id", "audience_count", "total_audience_reach", "segment_count"
    ],
    "int_promotion_rule_summary": [
        "promotion_id", "min_quantity_rules", "min_amount_rules", "category_rules",
        "customer_tier_rules", "first_order_rules", "total_rules"
    ],
    "int_customer_cohort": [
        "customer_id", "cohort_month", "first_redemption_date", "total_redemptions",
        "total_discount"
    ],
    "int_campaign_rolling_metrics": [
        "campaign_id", "metric_date", "daily_spend", "daily_revenue",
        "rolling_7d_avg_spend", "rolling_7d_avg_revenue", "days_with_data"
    ],
    "dim_campaigns": [
        "campaign_id", "campaign_code", "campaign_name", "campaign_type",
        "start_date", "end_date", "budget", "status"
    ],
    "dim_promotions": [
        "promotion_id", "promotion_code", "promotion_name", "promotion_type",
        "discount_type", "discount_value", "min_purchase", "max_discount",
        "start_date", "end_date", "is_active"
    ],
    "dim_marketing_customers": [
        "customer_id", "recency_days", "frequency", "monetary",
        "r_score", "f_score", "m_score", "rfm_segment",
        "total_points_issued", "total_points_redeemed", "points_balance",
        "has_loyalty_activity", "has_redemption_activity"
    ],
    "dim_loyalty_programs": [
        "program_id", "program_name", "program_type", "points_per_dollar",
        "points_value", "is_active"
    ],
    "dim_gift_cards": [
        "gift_card_id", "card_number", "initial_value", "current_balance",
        "currency_code", "status", "purchased_by", "activated_at", "expires_at"
    ],
    "fct_campaign_daily_performance": [
        "campaign_id", "campaign_code", "campaign_name", "metric_date",
        "impressions", "clicks", "conversions", "spend", "revenue",
        "ctr", "conversion_rate", "roas", "is_anomalous"
    ],
    "fct_campaign_performance": [
        "campaign_id", "campaign_code", "campaign_name", "campaign_type",
        "status", "budget", "total_impressions", "total_clicks", "total_conversions",
        "total_spend", "total_revenue", "ctr", "conversion_rate", "roas", "cpa",
        "budget_utilization", "effectiveness_score", "roas_percentile",
        "ctr_percentile", "conversion_rate_percentile", "cumulative_revenue"
    ],
    "fct_promotion_performance": [
        "promotion_id", "promotion_code", "promotion_name", "promotion_type",
        "discount_type", "is_active", "redemption_count", "total_discount_given",
        "avg_discount_per_redemption", "customer_reach"
    ],
    "fct_campaign_weekly_performance": [
        "campaign_id", "campaign_name", "week_start", "weekly_impressions",
        "weekly_clicks", "weekly_conversions", "weekly_spend", "weekly_revenue",
        "weekly_roas", "prior_week_revenue", "wow_revenue_change", "running_total_revenue"
    ],
    "fct_campaign_monthly_performance": [
        "campaign_id", "campaign_name", "month_start", "monthly_impressions",
        "monthly_clicks", "monthly_conversions", "monthly_spend", "monthly_revenue",
        "monthly_roas", "prior_month_revenue", "mom_revenue_change",
        "ytd_revenue", "ytd_spend", "ytd_conversions"
    ],
    "fct_loyalty_performance": [
        "program_id", "program_name", "program_type", "is_active",
        "total_members", "total_points_issued", "total_points_redeemed",
        "total_points_outstanding", "redemption_rate", "points_value_issued",
        "points_value_redeemed"
    ],
    "fct_gift_card_performance": [
        "gift_card_id", "card_number", "initial_value", "current_balance",
        "status", "total_loaded", "total_spent", "utilization_rate",
        "transaction_count", "is_fully_redeemed"
    ],
    "fct_campaign_audience_performance": [
        "campaign_id", "campaign_code", "campaign_name", "budget",
        "total_spend", "total_revenue", "total_audience_reach", "audience_count",
        "cost_per_audience_member", "revenue_per_audience_member"
    ],
    "bridge_campaign_channel": [
        "channel_mapping_id", "campaign_id", "channel_type", "allocated_budget",
        "campaign_total_revenue", "channel_efficiency"
    ],
    "fct_promotion_rule_analysis": [
        "promotion_id", "promotion_code", "promotion_name", "redemption_count",
        "total_discount_given", "total_rules", "rule_complexity_score",
        "avg_discount_per_rule"
    ],
    "fct_customer_cohort_performance": [
        "cohort_month", "cohort_size", "total_redemptions", "total_discount",
        "avg_redemptions_per_customer", "avg_discount_per_customer",
        "retention_rate_month_1", "retention_rate_month_2", "retention_rate_month_3"
    ],
    "fct_campaign_trend_analysis": [
        "campaign_id", "campaign_name", "metric_date", "daily_spend",
        "daily_revenue", "rolling_7d_avg_spend", "rolling_7d_avg_revenue",
        "spend_trend", "revenue_trend"
    ],
}


# ============ HELPERS ============

def run_cmd(cmd, cwd=None):
    if cwd is None:
        cwd = get_dbt_project_dir()
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    print(f"STDOUT: {result.stdout[:2000] if result.stdout else '(empty)'}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:1000]}")
    return result


def run_dbt_pipeline():
    dbt_dir = get_dbt_project_dir()
    deps_result = run_cmd("dbt deps", cwd=dbt_dir)
    if deps_result.returncode != 0:
        print(f"Warning: dbt deps returned {deps_result.returncode}")
    model_list = " ".join(ALL_MODELS)
    result = run_cmd(f"dbt run --select {model_list}", cwd=dbt_dir)
    assert result.returncode == 0, f"dbt run failed: {result.stderr}"


def to_float(val):
    """Convert decimal.Decimal or other numeric types to float for comparison."""
    if val is None:
        return None
    return float(val)


def query_model(model_name, columns="*", order_by=None, limit=None):
    conn, db_type = get_db_connection()
    try:
        sql = f"SELECT {columns} FROM {MODEL_SCHEMA}.{model_name}"
        if order_by:
            sql += f" ORDER BY {order_by}"
        if limit:
            sql += f" LIMIT {limit}"
        return execute_query(conn, db_type, sql)
    finally:
        conn.close()


def get_model_columns(model_name):
    conn, db_type = get_db_connection()
    try:
        sql = f"""
            SELECT column_name FROM information_schema.columns
            WHERE lower(table_schema) = '{MODEL_SCHEMA}' AND lower(table_name) = '{model_name}'
        """
        cols = execute_query(conn, db_type, sql)
        return {c[0].lower() for c in cols}
    finally:
        conn.close()


def model_exists(model_name):
    conn, db_type = get_db_connection()
    try:
        sql = f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = '{MODEL_SCHEMA}' AND lower(table_name) = '{model_name}'
        """
        result = execute_scalar(conn, db_type, sql)
        return int(result) == 1
    finally:
        conn.close()


def model_file_exists(model_name):
    dbt_dir = get_dbt_project_dir()
    if model_name.startswith("int_"):
        path = f"{dbt_dir}/models/intermediate/marketing/{model_name}.sql"
    else:
        path = f"{dbt_dir}/models/marts/marketing/{model_name}.sql"
    return os.path.exists(path)


# ============ EXPECTED VALUE HELPERS ============

def get_expected_campaign_performance_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT campaign_id), SUM(impressions), SUM(clicks),
                   SUM(conversions), SUM(spend), SUM(revenue)
            FROM main.stg_marketing__campaign_performance
        """)
        row = result[0]
        return {"campaign_count": int(row[0]), "total_impressions": int(row[1]),
                "total_clicks": int(row[2]), "total_conversions": int(row[3]),
                "total_spend": float(row[4]), "total_revenue": float(row[5])}
    finally:
        conn.close()


def get_expected_promotion_redemption_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT promotion_id), COUNT(*), SUM(discount_amount)
            FROM main.stg_marketing__promotion_redemptions
        """)
        row = result[0]
        return {"promotion_count": int(row[0]), "total_redemptions": int(row[1]),
                "total_discount": float(row[2])}
    finally:
        conn.close()


def get_expected_rfm_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT customer_id), SUM(frequency), SUM(monetary) FROM (
                SELECT customer_id, COUNT(*) as frequency, SUM(discount_amount) as monetary
                FROM (
                    SELECT customer_id, discount_amount FROM main.stg_marketing__promotion_redemptions
                    UNION ALL
                    SELECT customer_id, discount_amount FROM main.stg_marketing__coupon_redemptions
                ) sub1 GROUP BY customer_id
            ) sub2
        """)
        row = result[0]
        return {"customer_count": int(row[0]), "total_frequency": int(row[1]),
                "total_monetary": float(row[2])}
    finally:
        conn.close()


def get_expected_loyalty_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(*), SUM(issued), SUM(redeemed), SUM(balance), SUM(txn_count)
            FROM (
                SELECT customer_id,
                       SUM(CASE WHEN transaction_type IN ('EARN', 'BONUS') THEN points ELSE 0 END) as issued,
                       ABS(SUM(CASE WHEN transaction_type = 'REDEEM' THEN points ELSE 0 END)) as redeemed,
                       SUM(points) as balance,
                       COUNT(*) as txn_count
                FROM main.stg_marketing__loyalty_points_transactions
                GROUP BY customer_id
            ) per_customer
        """)
        row = result[0]
        return {"customer_count": int(row[0]), "total_issued": float(row[1]),
                "total_redeemed": float(row[2]), "total_balance": float(row[3]),
                "total_transactions": int(row[4])}
    finally:
        conn.close()


def get_expected_gift_card_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT gift_card_id),
                   SUM(CASE WHEN transaction_type IN ('ACTIVATION', 'REFUND', 'ADJUSTMENT') THEN amount ELSE 0 END),
                   ABS(SUM(CASE WHEN transaction_type = 'PURCHASE' THEN amount ELSE 0 END)),
                   SUM(amount), COUNT(*)
            FROM main.stg_marketing__gift_card_transactions
        """)
        row = result[0]
        return {"card_count": int(row[0]), "total_loaded": float(row[1]),
                "total_spent": float(row[2]), "total_balance": float(row[3]),
                "total_transactions": int(row[4])}
    finally:
        conn.close()


def get_expected_promotion_rules_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT promotion_id),
                   SUM(CASE WHEN rule_type = 'MIN_QUANTITY' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN rule_type = 'MIN_AMOUNT' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN rule_type = 'CATEGORY' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN rule_type = 'CUSTOMER_TIER' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN rule_type = 'FIRST_ORDER' THEN 1 ELSE 0 END),
                   COUNT(*)
            FROM main.stg_marketing__promotion_rules
        """)
        row = result[0]
        return {"promotion_count": int(row[0]), "min_quantity_total": int(row[1]),
                "min_amount_total": int(row[2]), "category_total": int(row[3]),
                "customer_tier_total": int(row[4]), "first_order_total": int(row[5]),
                "total_rules": int(row[6])}
    finally:
        conn.close()


def get_expected_audience_totals():
    conn, db_type = get_db_connection()
    try:
        result = execute_query(conn, db_type, """
            SELECT COUNT(DISTINCT campaign_id), COUNT(*), SUM(audience_size),
                   COUNT(DISTINCT segment_id)
            FROM main.stg_marketing__campaign_audiences
        """)
        row = result[0]
        return {"campaign_count": int(row[0]), "total_audiences": int(row[1]),
                "total_reach": int(row[2]), "total_segments": int(row[3])}
    finally:
        conn.close()


def get_expected_cohort_retention():
    conn, db_type = get_db_connection()
    try:
        if db_type == 'snowflake':
            sql = """
                WITH customer_cohorts AS (
                    SELECT customer_id, DATE_TRUNC('month', MIN(CAST(redeemed_at AS TIMESTAMP))) as cohort_month
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id
                ),
                all_redemptions AS (
                    SELECT customer_id, DATE_TRUNC('month', CAST(redeemed_at AS TIMESTAMP)) as redemption_month
                    FROM main.stg_marketing__promotion_redemptions
                    UNION ALL
                    SELECT customer_id, DATE_TRUNC('month', CAST(redeemed_at AS TIMESTAMP)) as redemption_month
                    FROM main.stg_marketing__coupon_redemptions
                ),
                cohort_sizes AS (
                    SELECT cohort_month, COUNT(DISTINCT customer_id) as cohort_size
                    FROM customer_cohorts GROUP BY cohort_month
                ),
                retention AS (
                    SELECT c.cohort_month,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = DATEADD('month', 1, c.cohort_month) THEN c.customer_id END) as month_1,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = DATEADD('month', 2, c.cohort_month) THEN c.customer_id END) as month_2,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = DATEADD('month', 3, c.cohort_month) THEN c.customer_id END) as month_3
                    FROM customer_cohorts c
                    LEFT JOIN all_redemptions r ON c.customer_id = r.customer_id
                    GROUP BY c.cohort_month
                )
                SELECT cs.cohort_month, cs.cohort_size,
                       CAST(r.month_1 AS DOUBLE) / cs.cohort_size,
                       CAST(r.month_2 AS DOUBLE) / cs.cohort_size,
                       CAST(r.month_3 AS DOUBLE) / cs.cohort_size
                FROM cohort_sizes cs JOIN retention r ON cs.cohort_month = r.cohort_month
                ORDER BY cs.cohort_month
            """
        else:
            sql = """
                WITH customer_cohorts AS (
                    SELECT customer_id, DATE_TRUNC('month', MIN(redeemed_at)) as cohort_month
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id
                ),
                all_redemptions AS (
                    SELECT customer_id, DATE_TRUNC('month', redeemed_at) as redemption_month
                    FROM main.stg_marketing__promotion_redemptions
                    UNION ALL
                    SELECT customer_id, DATE_TRUNC('month', redeemed_at) as redemption_month
                    FROM main.stg_marketing__coupon_redemptions
                ),
                cohort_sizes AS (
                    SELECT cohort_month, COUNT(DISTINCT customer_id) as cohort_size
                    FROM customer_cohorts GROUP BY cohort_month
                ),
                retention AS (
                    SELECT c.cohort_month,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = c.cohort_month + INTERVAL '1 month' THEN c.customer_id END) as month_1,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = c.cohort_month + INTERVAL '2 months' THEN c.customer_id END) as month_2,
                        COUNT(DISTINCT CASE WHEN r.redemption_month = c.cohort_month + INTERVAL '3 months' THEN c.customer_id END) as month_3
                    FROM customer_cohorts c
                    LEFT JOIN all_redemptions r ON c.customer_id = r.customer_id
                    GROUP BY c.cohort_month
                )
                SELECT cs.cohort_month, cs.cohort_size,
                       r.month_1 * 1.0 / cs.cohort_size,
                       r.month_2 * 1.0 / cs.cohort_size,
                       r.month_3 * 1.0 / cs.cohort_size
                FROM cohort_sizes cs JOIN retention r ON cs.cohort_month = r.cohort_month
                ORDER BY cs.cohort_month
            """
        rows = execute_query(conn, db_type, sql)
        return rows
    finally:
        conn.close()


# ============ PYTEST FIXTURES ============

@pytest.fixture(scope="module")
def dbt_run():
    run_dbt_pipeline()
    return True


@pytest.fixture(scope="module")
def expected_campaign_perf(dbt_run):
    return get_expected_campaign_performance_totals()


@pytest.fixture(scope="module")
def expected_promo_redemption(dbt_run):
    return get_expected_promotion_redemption_totals()


@pytest.fixture(scope="module")
def expected_rfm(dbt_run):
    return get_expected_rfm_totals()


@pytest.fixture(scope="module")
def expected_loyalty(dbt_run):
    return get_expected_loyalty_totals()


@pytest.fixture(scope="module")
def expected_gift_card(dbt_run):
    return get_expected_gift_card_totals()


@pytest.fixture(scope="module")
def expected_rules(dbt_run):
    return get_expected_promotion_rules_totals()


@pytest.fixture(scope="module")
def expected_audience(dbt_run):
    return get_expected_audience_totals()


@pytest.fixture(scope="module")
def expected_retention(dbt_run):
    return get_expected_cohort_retention()


# ============ PHASE 1: MODEL STRUCTURE ============

class TestPhase1ModelStructure:

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_file_exists(self, model_name, dbt_run):
        """Verify that the SQL model file exists on disk for the given model."""
        assert model_file_exists(model_name), f"Model file not found for {model_name}"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_exists_in_schema(self, model_name, dbt_run):
        """Verify that the model exists as a table/view in the database schema."""
        assert model_exists(model_name), f"Model {model_name} not found in schema {MODEL_SCHEMA}"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_required_columns_exist(self, model_name, dbt_run):
        """Verify that all required columns are present in the model."""
        actual_cols = get_model_columns(model_name)
        required_cols = set(REQUIRED_COLUMNS[model_name])
        missing = required_cols - actual_cols
        assert not missing, f"Missing columns in {model_name}: {missing}"

    @pytest.mark.parametrize("model_name", ALL_MODELS)
    def test_model_has_rows(self, model_name, dbt_run):
        """Verify that the model contains at least one row of data."""
        rows = query_model(model_name, "COUNT(*)")
        assert int(rows[0][0]) > 0, f"{model_name} has no rows"


# ============ PHASE 2: INTERMEDIATE AGGREGATIONS ============

class TestPhase2IntCampaignPerformanceSummary:

    def test_row_count_matches(self, dbt_run, expected_campaign_perf):
        """Verify campaign count in summary matches distinct campaigns from source."""
        actual = int(query_model("int_campaign_performance_summary", "COUNT(DISTINCT campaign_id)")[0][0])
        assert actual == expected_campaign_perf["campaign_count"]

    def test_total_impressions_sum(self, dbt_run, expected_campaign_perf):
        """Verify total impressions sum reconciles with source performance data."""
        actual = int(query_model("int_campaign_performance_summary", "SUM(total_impressions)")[0][0])
        assert actual == expected_campaign_perf["total_impressions"]

    def test_total_clicks_sum(self, dbt_run, expected_campaign_perf):
        """Verify total clicks sum reconciles with source performance data."""
        actual = int(query_model("int_campaign_performance_summary", "SUM(total_clicks)")[0][0])
        assert actual == expected_campaign_perf["total_clicks"]

    def test_total_conversions_sum(self, dbt_run, expected_campaign_perf):
        """Verify total conversions sum reconciles with source performance data."""
        actual = int(query_model("int_campaign_performance_summary", "SUM(total_conversions)")[0][0])
        assert actual == expected_campaign_perf["total_conversions"]

    def test_total_spend_sum(self, dbt_run, expected_campaign_perf):
        """Verify total spend sum reconciles with source performance data within tolerance."""
        actual = float(query_model("int_campaign_performance_summary", "SUM(total_spend)")[0][0])
        assert abs(actual - expected_campaign_perf["total_spend"]) < 0.01

    def test_total_revenue_sum(self, dbt_run, expected_campaign_perf):
        """Verify total revenue sum reconciles with source performance data within tolerance."""
        actual = float(query_model("int_campaign_performance_summary", "SUM(total_revenue)")[0][0])
        assert abs(actual - expected_campaign_perf["total_revenue"]) < 0.01


class TestPhase2IntPromotionRedemptionSummary:

    def test_row_count_matches(self, dbt_run, expected_promo_redemption):
        """Verify promotion count in redemption summary matches source distinct promotions."""
        actual = int(query_model("int_promotion_redemption_summary", "COUNT(DISTINCT promotion_id)")[0][0])
        assert actual == expected_promo_redemption["promotion_count"]

    def test_total_redemptions_sum(self, dbt_run, expected_promo_redemption):
        """Verify total redemption count reconciles with source redemption data."""
        actual = int(query_model("int_promotion_redemption_summary", "SUM(redemption_count)")[0][0])
        assert actual == expected_promo_redemption["total_redemptions"]

    def test_total_discount_sum(self, dbt_run, expected_promo_redemption):
        """Verify total discount given reconciles with source redemption data within tolerance."""
        actual = float(query_model("int_promotion_redemption_summary", "SUM(total_discount_given)")[0][0])
        assert abs(actual - expected_promo_redemption["total_discount"]) < 0.01


class TestPhase2IntCustomerLoyaltySummary:

    def test_row_count_matches(self, dbt_run, expected_loyalty):
        """Verify customer count in loyalty summary matches source distinct customers."""
        actual = int(query_model("int_customer_loyalty_summary", "COUNT(DISTINCT customer_id)")[0][0])
        assert actual == expected_loyalty["customer_count"]

    def test_total_points_issued_sum(self, dbt_run, expected_loyalty):
        """Verify total loyalty points issued reconciles with source transaction data."""
        actual = float(query_model("int_customer_loyalty_summary", "SUM(total_points_issued)")[0][0])
        assert actual == expected_loyalty["total_issued"]

    def test_total_points_redeemed_sum(self, dbt_run, expected_loyalty):
        """Verify total loyalty points redeemed reconciles with source transaction data."""
        actual = float(query_model("int_customer_loyalty_summary", "SUM(total_points_redeemed)")[0][0])
        assert actual == expected_loyalty["total_redeemed"]

    def test_points_balance_sum(self, dbt_run, expected_loyalty):
        """Verify total points balance reconciles with source transaction data."""
        actual = float(query_model("int_customer_loyalty_summary", "SUM(points_balance)")[0][0])
        assert actual == expected_loyalty["total_balance"]

    def test_transaction_count_sum(self, dbt_run, expected_loyalty):
        """Verify total transaction count reconciles with source loyalty transactions."""
        actual = int(query_model("int_customer_loyalty_summary", "SUM(transaction_count)")[0][0])
        assert actual == expected_loyalty["total_transactions"]


class TestPhase2IntGiftCardSummary:

    def test_row_count_matches(self, dbt_run, expected_gift_card):
        """Verify gift card count in summary matches source distinct gift cards."""
        actual = int(query_model("int_gift_card_summary", "COUNT(DISTINCT gift_card_id)")[0][0])
        assert actual == expected_gift_card["card_count"]

    def test_total_loaded_sum(self, dbt_run, expected_gift_card):
        """Verify total loaded amount reconciles with source gift card transactions."""
        actual = float(query_model("int_gift_card_summary", "SUM(total_loaded)")[0][0])
        assert abs(actual - expected_gift_card["total_loaded"]) < 0.01

    def test_total_spent_sum(self, dbt_run, expected_gift_card):
        """Verify total spent amount reconciles with source gift card transactions."""
        actual = float(query_model("int_gift_card_summary", "SUM(total_spent)")[0][0])
        assert abs(actual - expected_gift_card["total_spent"]) < 0.01

    def test_net_balance_sum(self, dbt_run, expected_gift_card):
        """Verify net balance sum reconciles with source gift card transactions."""
        actual = float(query_model("int_gift_card_summary", "SUM(net_balance)")[0][0])
        assert abs(actual - expected_gift_card["total_balance"]) < 0.01


class TestPhase2IntPromotionRuleSummary:

    def test_row_count_matches(self, dbt_run, expected_rules):
        """Verify promotion count in rule summary matches source distinct promotions."""
        actual = int(query_model("int_promotion_rule_summary", "COUNT(DISTINCT promotion_id)")[0][0])
        assert actual == expected_rules["promotion_count"]

    def test_min_quantity_rules_sum(self, dbt_run, expected_rules):
        """Verify total MIN_QUANTITY rules count reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(min_quantity_rules)")[0][0])
        assert actual == expected_rules["min_quantity_total"]

    def test_min_amount_rules_sum(self, dbt_run, expected_rules):
        """Verify total MIN_AMOUNT rules count reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(min_amount_rules)")[0][0])
        assert actual == expected_rules["min_amount_total"]

    def test_category_rules_sum(self, dbt_run, expected_rules):
        """Verify total CATEGORY rules count reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(category_rules)")[0][0])
        assert actual == expected_rules["category_total"]

    def test_customer_tier_rules_sum(self, dbt_run, expected_rules):
        """Verify total CUSTOMER_TIER rules count reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(customer_tier_rules)")[0][0])
        assert actual == expected_rules["customer_tier_total"]

    def test_first_order_rules_sum(self, dbt_run, expected_rules):
        """Verify total FIRST_ORDER rules count reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(first_order_rules)")[0][0])
        assert actual == expected_rules["first_order_total"]

    def test_total_rules_sum(self, dbt_run, expected_rules):
        """Verify total rules count across all types reconciles with source."""
        actual = int(query_model("int_promotion_rule_summary", "SUM(total_rules)")[0][0])
        assert actual == expected_rules["total_rules"]


class TestPhase2IntCampaignAudienceSummary:

    def test_row_count_matches(self, dbt_run, expected_audience):
        """Verify campaign count in audience summary matches source distinct campaigns."""
        actual = int(query_model("int_campaign_audience_summary", "COUNT(DISTINCT campaign_id)")[0][0])
        assert actual == expected_audience["campaign_count"]

    def test_audience_count_sum(self, dbt_run, expected_audience):
        """Verify total audience count reconciles with source campaign audiences."""
        actual = int(query_model("int_campaign_audience_summary", "SUM(audience_count)")[0][0])
        assert actual == expected_audience["total_audiences"]

    def test_total_audience_reach_sum(self, dbt_run, expected_audience):
        """Verify total audience reach reconciles with source campaign audiences."""
        actual = int(query_model("int_campaign_audience_summary", "SUM(total_audience_reach)")[0][0])
        assert actual == expected_audience["total_reach"]


class TestPhase2IntCampaignDailyStats:

    def test_stddev_calculation(self, dbt_run):
        """Verify mean_spend and stddev_spend match AVG and STDDEV_POP from source."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT campaign_id, AVG(spend), STDDEV_POP(spend)
                FROM main.stg_marketing__campaign_performance
                GROUP BY campaign_id ORDER BY campaign_id LIMIT 20
            """)
            actual = query_model("int_campaign_daily_stats", "campaign_id, mean_spend, stddev_spend", "campaign_id", 20)
            for act, exp in zip(actual, expected):
                assert act[0] == exp[0]
                assert abs(float(act[1]) - float(exp[1])) < 0.01
                if exp[2] is not None and act[2] is not None:
                    assert abs(float(act[2]) - float(exp[2])) < 0.01
        finally:
            conn.close()


class TestPhase2IntChannelAllocation:

    def test_channel_efficiency_calculation(self, dbt_run):
        """Verify channel_efficiency equals revenue/budget, or NULL when budget is zero."""
        rows = query_model("int_channel_allocation",
            "channel_mapping_id, allocated_budget, campaign_total_revenue, channel_efficiency", limit=50)
        for row in rows:
            budget, revenue, efficiency = float(row[1]), float(row[2]), row[3]
            if budget == 0:
                assert efficiency is None
            else:
                expected = revenue / budget
                assert abs(to_float(efficiency) - expected) < 0.0001

    def test_default_revenue_zero(self, dbt_run):
        """Verify campaign_total_revenue defaults to zero (not NULL) for all channels."""
        rows = query_model("int_channel_allocation", "campaign_total_revenue")
        for row in rows:
            assert row[0] is not None and float(row[0]) >= 0


# ============ PHASE 3: RFM SCORING ============

class TestPhase3RFMScoring:

    def test_customer_count_matches(self, dbt_run, expected_rfm):
        """Verify customer count in RFM model matches source distinct customers."""
        actual = int(query_model("int_customer_rfm", "COUNT(DISTINCT customer_id)")[0][0])
        assert actual == expected_rfm["customer_count"]

    def test_total_frequency_sum(self, dbt_run, expected_rfm):
        """Verify total frequency sum reconciles with source redemption counts."""
        actual = int(query_model("int_customer_rfm", "SUM(frequency)")[0][0])
        assert actual == expected_rfm["total_frequency"]

    def test_total_monetary_sum(self, dbt_run, expected_rfm):
        """Verify total monetary sum reconciles with source discount amounts."""
        actual = float(query_model("int_customer_rfm", "SUM(monetary)")[0][0])
        assert abs(actual - expected_rfm["total_monetary"]) < 0.01

    def test_rfm_scores_are_1_to_5(self, dbt_run):
        """Verify all RFM scores (R, F, M) are within the valid 1-5 range."""
        rows = query_model("int_customer_rfm", "customer_id, r_score, f_score, m_score")
        for row in rows:
            assert 1 <= int(row[1]) <= 5
            assert 1 <= int(row[2]) <= 5
            assert 1 <= int(row[3]) <= 5

    def test_rfm_segment_format(self, dbt_run):
        """Verify rfm_segment follows the RFM_XYZ format derived from individual scores."""
        rows = query_model("int_customer_rfm", "customer_id, r_score, f_score, m_score, rfm_segment")
        for row in rows:
            expected_segment = f"RFM_{int(row[1])}{int(row[2])}{int(row[3])}"
            assert row[4] == expected_segment

    def test_recency_days_calculation(self, dbt_run):
        """Verify recency_days matches days since most recent redemption from source."""
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                sql = """
                    SELECT customer_id, DATEDIFF('day', MAX(redeemed_at)::DATE,
                        (SELECT MAX(redeemed_at)::DATE FROM (
                            SELECT redeemed_at FROM main.stg_marketing__promotion_redemptions
                            UNION ALL
                            SELECT redeemed_at FROM main.stg_marketing__coupon_redemptions
                        ) sub)) as recency_days
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            else:
                sql = """
                    SELECT customer_id,
                        (SELECT MAX(redeemed_at)::DATE FROM (
                            SELECT redeemed_at FROM main.stg_marketing__promotion_redemptions
                            UNION ALL
                            SELECT redeemed_at FROM main.stg_marketing__coupon_redemptions
                        ) sub) - MAX(redeemed_at)::DATE as recency_days
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            expected = execute_query(conn, db_type, sql)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT recency_days FROM {MODEL_SCHEMA}.int_customer_rfm
                    WHERE customer_id = '{exp[0]}'
                """)
                if actual:
                    assert abs(int(actual[0][0]) - int(exp[1])) <= 1
        finally:
            conn.close()

    def test_score_5_is_best_recency(self, dbt_run):
        """Verify R-score 5 customers have lower avg recency days than R-score 1."""
        conn, db_type = get_db_connection()
        try:
            r5_avg = execute_scalar(conn, db_type, f"SELECT AVG(recency_days) FROM {MODEL_SCHEMA}.int_customer_rfm WHERE r_score = 5")
            r1_avg = execute_scalar(conn, db_type, f"SELECT AVG(recency_days) FROM {MODEL_SCHEMA}.int_customer_rfm WHERE r_score = 1")
            if r5_avg and r1_avg:
                assert float(r5_avg) < float(r1_avg)
        finally:
            conn.close()

    # NOTE: test_score_5_is_best_frequency and test_score_5_is_best_monetary
    # were removed because NTILE with heavily tied data does not guarantee
    # monotonic bucket averages across different database backends.


# ============ PHASE 4: DIMENSION TABLES ============

class TestPhase4DimensionTables:

    def test_dim_campaigns_row_count(self, dbt_run):
        """Verify dim_campaigns row count matches source marketing campaigns."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.stg_marketing__marketing_campaigns"))
            actual = int(query_model("dim_campaigns", "COUNT(*)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_dim_promotions_row_count(self, dbt_run):
        """Verify dim_promotions row count matches source promotions."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.stg_marketing__promotions"))
            actual = int(query_model("dim_promotions", "COUNT(*)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_dim_loyalty_programs_row_count(self, dbt_run):
        """Verify dim_loyalty_programs row count matches source loyalty programs."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.stg_marketing__loyalty_programs"))
            actual = int(query_model("dim_loyalty_programs", "COUNT(*)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_dim_gift_cards_row_count(self, dbt_run):
        """Verify dim_gift_cards row count matches source gift cards."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.stg_marketing__gift_cards"))
            actual = int(query_model("dim_gift_cards", "COUNT(*)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_dim_marketing_customers_includes_all_rfm(self, dbt_run):
        """Verify all RFM customers appear in dim_marketing_customers with redemption flag."""
        conn, db_type = get_db_connection()
        try:
            rfm_count = int(execute_scalar(conn, db_type, f"SELECT COUNT(DISTINCT customer_id) FROM {MODEL_SCHEMA}.int_customer_rfm"))
            dim_with_redemption = int(execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.dim_marketing_customers
                WHERE has_redemption_activity = 1
            """))
            assert dim_with_redemption == rfm_count
        finally:
            conn.close()

    def test_dim_marketing_customers_includes_all_loyalty(self, dbt_run):
        """Verify all loyalty customers appear in dim_marketing_customers with loyalty flag."""
        conn, db_type = get_db_connection()
        try:
            loyalty_count = int(execute_scalar(conn, db_type, f"SELECT COUNT(DISTINCT customer_id) FROM {MODEL_SCHEMA}.int_customer_loyalty_summary"))
            dim_with_loyalty = int(execute_scalar(conn, db_type, f"""
                SELECT COUNT(*) FROM {MODEL_SCHEMA}.dim_marketing_customers
                WHERE has_loyalty_activity = 1
            """))
            assert dim_with_loyalty == loyalty_count
        finally:
            conn.close()

    def test_dim_marketing_customers_defaults_no_redemptions(self, dbt_run):
        """Verify customers without redemptions have NULL RFM scores and zero frequency/monetary."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT customer_id, recency_days, frequency, monetary, r_score, f_score, m_score, rfm_segment
                FROM {MODEL_SCHEMA}.dim_marketing_customers
                WHERE has_redemption_activity = 0
                LIMIT 20
            """)
            for row in rows:
                assert row[1] is None  # recency_days NULL
                assert int(row[2]) == 0     # frequency 0
                assert float(row[3]) == 0     # monetary 0
                assert row[4] is None  # r_score NULL
                assert row[5] is None  # f_score NULL
                assert row[6] is None  # m_score NULL
                assert row[7] is None  # rfm_segment NULL
        finally:
            conn.close()

    def test_dim_marketing_customers_defaults_no_loyalty(self, dbt_run):
        """Verify customers without loyalty activity have zero points issued/redeemed/balance."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT customer_id, total_points_issued, total_points_redeemed, points_balance
                FROM {MODEL_SCHEMA}.dim_marketing_customers
                WHERE has_loyalty_activity = 0
                LIMIT 20
            """)
            for row in rows:
                assert float(row[1]) == 0
                assert float(row[2]) == 0
                assert float(row[3]) == 0
        finally:
            conn.close()


# ============ PHASE 5: FACT CALCULATIONS ============

class TestPhase5FctCampaignDailyPerformance:

    def test_campaign_code_null_when_not_found(self, dbt_run):
        """Validate campaign_code is NULL when campaign not found in stg_marketing__marketing_campaigns."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT p.campaign_id, f.campaign_code, f.campaign_name
                FROM main.stg_marketing__campaign_performance p
                LEFT JOIN main.stg_marketing__marketing_campaigns c ON p.campaign_id = c.campaign_id
                LEFT JOIN {MODEL_SCHEMA}.fct_campaign_daily_performance f ON p.campaign_id = f.campaign_id AND p.metric_date = f.metric_date
                WHERE c.campaign_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                if row[1] is not None or row[2] is not None:
                    assert row[1] is None, f"campaign_code should be NULL for orphan campaign {row[0]}"
                    assert row[2] is None, f"campaign_name should be NULL for orphan campaign {row[0]}"
        finally:
            conn.close()

    def test_ctr_calculation(self, dbt_run):
        """Verify daily CTR equals clicks/impressions, or NULL when impressions is zero."""
        rows = query_model("fct_campaign_daily_performance",
            "campaign_id, metric_date, clicks, impressions, ctr", limit=100)
        for row in rows:
            clicks, impressions, ctr = float(row[2]), float(row[3]), row[4]
            if impressions == 0:
                assert ctr is None
            else:
                assert abs(to_float(ctr) - clicks / impressions) < 0.0001

    def test_conversion_rate_calculation(self, dbt_run):
        """Verify daily conversion rate equals conversions/clicks, or NULL when clicks is zero."""
        rows = query_model("fct_campaign_daily_performance",
            "campaign_id, metric_date, conversions, clicks, conversion_rate", limit=100)
        for row in rows:
            conversions, clicks, conv_rate = float(row[2]), float(row[3]), row[4]
            if clicks == 0:
                assert conv_rate is None
            else:
                assert abs(to_float(conv_rate) - conversions / clicks) < 0.0001

    def test_roas_calculation(self, dbt_run):
        """Verify daily ROAS equals revenue/spend, or NULL when spend is zero."""
        rows = query_model("fct_campaign_daily_performance",
            "campaign_id, metric_date, revenue, spend, roas", limit=100)
        for row in rows:
            revenue, spend, roas = float(row[2]), float(row[3]), row[4]
            if spend == 0:
                assert roas is None
            else:
                assert abs(to_float(roas) - revenue / spend) < 0.0001

    def test_is_anomalous_logic(self, dbt_run):
        """Verify is_anomalous flag based on CTR>0.5, conv_rate>0.8, or spend>mean+3*stddev."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT f.campaign_id, f.metric_date, f.ctr, f.conversion_rate, f.spend,
                       s.mean_spend, s.stddev_spend, f.is_anomalous
                FROM {MODEL_SCHEMA}.fct_campaign_daily_performance f
                LEFT JOIN {MODEL_SCHEMA}.int_campaign_daily_stats s ON f.campaign_id = s.campaign_id
                LIMIT 100
            """)
            for row in rows:
                ctr, conv_rate, spend = row[2], row[3], row[4]
                mean_spend, stddev_spend, is_anomalous = row[5], row[6], row[7]
                expected = 0
                if ctr is not None and float(ctr) > 0.5:
                    expected = 1
                if conv_rate is not None and float(conv_rate) > 0.8:
                    expected = 1
                if mean_spend is not None and stddev_spend is not None and float(spend) > (float(mean_spend) + 3 * float(stddev_spend)):
                    expected = 1
                assert int(is_anomalous) == expected
        finally:
            conn.close()


class TestPhase5FctCampaignPerformance:

    def test_ctr_calculation(self, dbt_run):
        """Verify aggregate CTR equals total_clicks/total_impressions, or NULL when zero."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_clicks, total_impressions, ctr", limit=50)
        for row in rows:
            clicks, impressions, ctr = float(row[1]), float(row[2]), row[3]
            if impressions == 0:
                assert ctr is None
            else:
                assert abs(to_float(ctr) - clicks / impressions) < 0.0001

    def test_conversion_rate_calculation(self, dbt_run):
        """Verify aggregate conversion rate equals total_conversions/total_clicks, or NULL when zero."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_conversions, total_clicks, conversion_rate", limit=50)
        for row in rows:
            conversions, clicks, conv_rate = float(row[1]), float(row[2]), row[3]
            if clicks == 0:
                assert conv_rate is None
            else:
                assert abs(to_float(conv_rate) - conversions / clicks) < 0.0001

    def test_roas_calculation(self, dbt_run):
        """Verify aggregate ROAS equals total_revenue/total_spend, or NULL when zero."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_revenue, total_spend, roas", limit=50)
        for row in rows:
            revenue, spend, roas = float(row[1]), float(row[2]), row[3]
            if spend == 0:
                assert roas is None
            else:
                assert abs(to_float(roas) - revenue / spend) < 0.0001

    def test_cpa_calculation(self, dbt_run):
        """Verify CPA equals total_spend/total_conversions, or NULL when zero conversions."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_spend, total_conversions, cpa", limit=50)
        for row in rows:
            spend, conversions, cpa = float(row[1]), float(row[2]), row[3]
            if conversions == 0:
                assert cpa is None
            else:
                assert abs(to_float(cpa) - spend / conversions) < 0.01

    def test_budget_utilization_calculation(self, dbt_run):
        """Verify budget utilization equals total_spend/budget, or NULL when budget is zero."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_spend, budget, budget_utilization", limit=50)
        for row in rows:
            spend, budget, util = float(row[1]), float(row[2]), row[3]
            if budget == 0:
                assert util is None
            else:
                assert abs(to_float(util) - spend / budget) < 0.0001

    def test_effectiveness_score_formula(self, dbt_run):
        """Verify effectiveness_score follows weighted formula: ROAS*0.4 + CR*0.3 + CTR*0.2 + BU*0.1."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, roas, conversion_rate, ctr, budget_utilization, effectiveness_score", limit=50)
        for row in rows:
            roas, conv_rate, ctr, budget_util, eff_score = row[1], row[2], row[3], row[4], row[5]
            if roas is None:
                assert eff_score is None
            else:
                cr = float(conv_rate) if conv_rate else 0
                c = float(ctr) if ctr else 0
                bu = float(budget_util) if budget_util else 0
                expected = (float(roas) * 0.4) + (cr * 100 * 0.3) + (c * 100 * 0.2) + (bu * 0.1)
                assert abs(float(eff_score) - expected) < 0.01

    def test_percentiles_valid(self, dbt_run):
        """Verify ROAS, CTR, and conversion rate percentiles are within 0-1 range."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, roas_percentile, ctr_percentile, conversion_rate_percentile")
        for row in rows:
            for pct in [row[1], row[2], row[3]]:
                if pct is not None:
                    assert 0 <= float(pct) <= 1

    def test_cumulative_revenue_ordering(self, dbt_run):
        """Verify cumulative_revenue is a running sum of total_revenue ordered by campaign_id."""
        rows = query_model("fct_campaign_performance",
            "campaign_id, total_revenue, cumulative_revenue", "campaign_id")
        running_sum = 0
        for row in rows:
            running_sum += float(row[1])
            assert abs(float(row[2]) - running_sum) < 0.01


class TestPhase5FctPromotionPerformance:

    def test_default_zero_for_no_redemptions(self, dbt_run):
        """Validate redemption_count and total_discount_given default to 0."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT p.promotion_id
                FROM main.stg_marketing__promotions p
                LEFT JOIN {MODEL_SCHEMA}.int_promotion_redemption_summary r ON p.promotion_id = r.promotion_id
                WHERE r.promotion_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                promo_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT redemption_count, total_discount_given
                    FROM {MODEL_SCHEMA}.fct_promotion_performance
                    WHERE promotion_id = '{promo_id}'
                """)
                if actual:
                    assert int(actual[0][0]) == 0, f"redemption_count should be 0 for promo without redemptions"
                    assert float(actual[0][1]) == 0, f"total_discount_given should be 0 for promo without redemptions"
        finally:
            conn.close()

    def test_avg_discount_per_redemption(self, dbt_run):
        """Verify avg_discount_per_redemption equals total_discount/count, or NULL when count is zero."""
        rows = query_model("fct_promotion_performance",
            "promotion_id, total_discount_given, redemption_count, avg_discount_per_redemption", limit=50)
        for row in rows:
            discount, count, avg = float(row[1]), int(row[2]), row[3]
            if count == 0:
                assert avg is None
            else:
                assert abs(to_float(avg) - discount / count) < 0.01

    def test_customer_reach_calculation(self, dbt_run):
        """Verify customer_reach matches distinct customer count from source redemptions."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT promotion_id, COUNT(DISTINCT customer_id)
                FROM main.stg_marketing__promotion_redemptions
                GROUP BY promotion_id ORDER BY promotion_id LIMIT 20
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT customer_reach FROM {MODEL_SCHEMA}.fct_promotion_performance
                    WHERE promotion_id = '{exp[0]}'
                """)
                if actual:
                    assert int(actual[0][0]) == int(exp[1])
        finally:
            conn.close()


class TestPhase5FctLoyaltyPerformance:

    def test_total_members_calculation(self, dbt_run):
        """Verify total_members matches distinct customer count per program from source."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT program_id, COUNT(DISTINCT customer_id) as total_members
                FROM main.stg_marketing__loyalty_points_transactions
                GROUP BY program_id ORDER BY program_id
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT total_members FROM {MODEL_SCHEMA}.fct_loyalty_performance
                    WHERE program_id = '{exp[0]}'
                """)
                if actual:
                    assert int(actual[0][0]) == int(exp[1]), \
                        f"total_members mismatch for {exp[0]}: got {actual[0][0]}, expected {exp[1]}"
        finally:
            conn.close()

    def test_total_points_outstanding_calculation(self, dbt_run):
        """Verify total_points_outstanding matches net points sum per program from source."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT program_id, SUM(points) as total_outstanding
                FROM main.stg_marketing__loyalty_points_transactions
                GROUP BY program_id ORDER BY program_id
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT total_points_outstanding FROM {MODEL_SCHEMA}.fct_loyalty_performance
                    WHERE program_id = '{exp[0]}'
                """)
                if actual:
                    assert float(actual[0][0]) == float(exp[1]), \
                        f"total_points_outstanding mismatch for {exp[0]}: got {actual[0][0]}, expected {exp[1]}"
        finally:
            conn.close()

    def test_redemption_rate_calculation(self, dbt_run):
        """Verify redemption_rate equals redeemed/issued, or NULL when issued is zero."""
        rows = query_model("fct_loyalty_performance",
            "program_id, total_points_issued, total_points_redeemed, redemption_rate", limit=20)
        for row in rows:
            issued, redeemed, rate = float(row[1]), float(row[2]), row[3]
            if issued == 0:
                assert rate is None
            else:
                assert abs(to_float(rate) - redeemed / issued) < 0.0001

    def test_points_value_issued_calculation(self, dbt_run):
        """Verify points_value_issued equals total_points_issued * points_value from dim."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT f.program_id, f.total_points_issued, p.points_value, f.points_value_issued
                FROM {MODEL_SCHEMA}.fct_loyalty_performance f
                JOIN {MODEL_SCHEMA}.dim_loyalty_programs p ON f.program_id = p.program_id
                LIMIT 20
            """)
            for row in rows:
                issued, pv, value_issued = float(row[1]), float(row[2]), float(row[3])
                assert abs(value_issued - issued * pv) < 0.01
        finally:
            conn.close()

    def test_points_value_redeemed_calculation(self, dbt_run):
        """Verify points_value_redeemed equals total_points_redeemed * points_value from dim."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT f.program_id, f.total_points_redeemed, p.points_value, f.points_value_redeemed
                FROM {MODEL_SCHEMA}.fct_loyalty_performance f
                JOIN {MODEL_SCHEMA}.dim_loyalty_programs p ON f.program_id = p.program_id
                LIMIT 20
            """)
            for row in rows:
                redeemed, pv, value_redeemed = float(row[1]), float(row[2]), float(row[3])
                assert abs(value_redeemed - redeemed * pv) < 0.01
        finally:
            conn.close()


class TestPhase5FctGiftCardPerformance:

    def test_default_zero_for_no_transactions(self, dbt_run):
        """Verify gift cards without transactions default to zero for loaded/spent/count."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT g.gift_card_id
                FROM main.stg_marketing__gift_cards g
                LEFT JOIN {MODEL_SCHEMA}.int_gift_card_summary s ON g.gift_card_id = s.gift_card_id
                WHERE s.gift_card_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                card_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT total_loaded, total_spent, transaction_count
                    FROM {MODEL_SCHEMA}.fct_gift_card_performance
                    WHERE gift_card_id = '{card_id}'
                """)
                if actual:
                    assert float(actual[0][0]) == 0, f"total_loaded should be 0"
                    assert float(actual[0][1]) == 0, f"total_spent should be 0"
                    assert int(actual[0][2]) == 0, f"transaction_count should be 0"
        finally:
            conn.close()

    def test_utilization_rate_calculation(self, dbt_run):
        """Verify utilization_rate equals spent/loaded, or NULL when loaded is zero."""
        rows = query_model("fct_gift_card_performance",
            "gift_card_id, total_loaded, total_spent, utilization_rate", limit=50)
        for row in rows:
            loaded, spent, rate = float(row[1]), float(row[2]), row[3]
            if loaded == 0:
                assert rate is None
            else:
                assert abs(to_float(rate) - spent / loaded) < 0.0001

    def test_is_fully_redeemed_logic(self, dbt_run):
        """Verify is_fully_redeemed is 1 when balance=0 and spent>0, else 0."""
        rows = query_model("fct_gift_card_performance",
            "gift_card_id, current_balance, total_spent, is_fully_redeemed", limit=100)
        for row in rows:
            balance, spent, is_redeemed = float(row[1]), float(row[2]), int(row[3])
            expected = 1 if (balance == 0 and spent > 0) else 0
            assert is_redeemed == expected


class TestPhase5FctCampaignAudiencePerformance:

    def test_default_zero_for_no_performance(self, dbt_run):
        """Verify campaigns without performance data default to zero spend and revenue."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT c.campaign_id
                FROM main.stg_marketing__marketing_campaigns c
                LEFT JOIN {MODEL_SCHEMA}.int_campaign_performance_summary p ON c.campaign_id = p.campaign_id
                WHERE p.campaign_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                camp_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT total_spend, total_revenue
                    FROM {MODEL_SCHEMA}.fct_campaign_audience_performance
                    WHERE campaign_id = '{camp_id}'
                """)
                if actual:
                    assert float(actual[0][0]) == 0, f"total_spend should be 0 for campaign without performance"
                    assert float(actual[0][1]) == 0, f"total_revenue should be 0 for campaign without performance"
        finally:
            conn.close()

    def test_default_zero_for_no_audience(self, dbt_run):
        """Verify campaigns without audience data default to zero reach and count."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT c.campaign_id
                FROM main.stg_marketing__marketing_campaigns c
                LEFT JOIN {MODEL_SCHEMA}.int_campaign_audience_summary a ON c.campaign_id = a.campaign_id
                WHERE a.campaign_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                camp_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT total_audience_reach, audience_count
                    FROM {MODEL_SCHEMA}.fct_campaign_audience_performance
                    WHERE campaign_id = '{camp_id}'
                """)
                if actual:
                    assert int(actual[0][0]) == 0, f"total_audience_reach should be 0"
                    assert int(actual[0][1]) == 0, f"audience_count should be 0"
        finally:
            conn.close()

    def test_cost_per_audience_member(self, dbt_run):
        """Verify cost_per_audience_member equals spend/reach, or NULL when reach is zero."""
        rows = query_model("fct_campaign_audience_performance",
            "campaign_id, total_spend, total_audience_reach, cost_per_audience_member", limit=50)
        for row in rows:
            spend, reach, cost = float(row[1]), float(row[2]), row[3]
            if reach == 0:
                assert cost is None
            else:
                assert abs(to_float(cost) - spend / reach) < 0.0001

    def test_revenue_per_audience_member(self, dbt_run):
        """Verify revenue_per_audience_member equals revenue/reach, or NULL when reach is zero."""
        rows = query_model("fct_campaign_audience_performance",
            "campaign_id, total_revenue, total_audience_reach, revenue_per_audience_member", limit=50)
        for row in rows:
            revenue, reach, rpm = float(row[1]), float(row[2]), row[3]
            if reach == 0:
                assert rpm is None
            else:
                assert abs(to_float(rpm) - revenue / reach) < 0.0001


class TestPhase5FctPromotionRuleAnalysis:

    def test_default_zero_for_no_rules(self, dbt_run):
        """Verify promotions without rules default to zero for total_rules and complexity_score."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT p.promotion_id
                FROM main.stg_marketing__promotions p
                LEFT JOIN {MODEL_SCHEMA}.int_promotion_rule_summary r ON p.promotion_id = r.promotion_id
                WHERE r.promotion_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                promo_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT total_rules, rule_complexity_score
                    FROM {MODEL_SCHEMA}.fct_promotion_rule_analysis
                    WHERE promotion_id = '{promo_id}'
                """)
                if actual:
                    assert int(actual[0][0]) == 0, f"total_rules should be 0"
                    assert int(actual[0][1]) == 0, f"rule_complexity_score should be 0"
        finally:
            conn.close()

    def test_default_zero_for_no_redemptions(self, dbt_run):
        """Verify promotions without redemptions default to zero count and discount."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT p.promotion_id
                FROM main.stg_marketing__promotions p
                LEFT JOIN {MODEL_SCHEMA}.int_promotion_redemption_summary r ON p.promotion_id = r.promotion_id
                WHERE r.promotion_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                promo_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT redemption_count, total_discount_given
                    FROM {MODEL_SCHEMA}.fct_promotion_rule_analysis
                    WHERE promotion_id = '{promo_id}'
                """)
                if actual:
                    assert int(actual[0][0]) == 0, f"redemption_count should be 0"
                    assert float(actual[0][1]) == 0, f"total_discount_given should be 0"
        finally:
            conn.close()

    def test_rule_complexity_score_formula(self, dbt_run):
        """Verify rule_complexity_score follows weighted formula based on rule type counts."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT f.promotion_id,
                    COALESCE(r.min_quantity_rules, 0), COALESCE(r.min_amount_rules, 0),
                    COALESCE(r.category_rules, 0), COALESCE(r.customer_tier_rules, 0),
                    COALESCE(r.first_order_rules, 0), f.rule_complexity_score
                FROM {MODEL_SCHEMA}.fct_promotion_rule_analysis f
                LEFT JOIN {MODEL_SCHEMA}.int_promotion_rule_summary r ON f.promotion_id = r.promotion_id
                LIMIT 50
            """)
            for row in rows:
                min_qty, min_amt, cat, tier, first_order, actual = int(row[1]), int(row[2]), int(row[3]), int(row[4]), int(row[5]), int(row[6])
                expected = (min_qty * 1) + (min_amt * 2) + (cat * 1) + (tier * 3) + (first_order * 2)
                assert actual == expected
        finally:
            conn.close()

    def test_avg_discount_per_rule(self, dbt_run):
        """Verify avg_discount_per_rule equals total_discount/total_rules, or NULL when zero rules."""
        rows = query_model("fct_promotion_rule_analysis",
            "promotion_id, total_discount_given, total_rules, avg_discount_per_rule", limit=50)
        for row in rows:
            discount, rules, avg = float(row[1]), int(row[2]), row[3]
            if rules == 0:
                assert avg is None
            else:
                assert abs(to_float(avg) - discount / rules) < 0.01


# ============ PHASE 6: TIME AGGREGATIONS ============

class TestPhase6WeeklyPerformance:

    def test_weekly_aggregations(self, dbt_run):
        """Verify weekly aggregated metrics match source data grouped by week."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT campaign_id, DATE_TRUNC('week', metric_date) as week_start,
                       SUM(impressions), SUM(clicks), SUM(conversions), SUM(spend), SUM(revenue)
                FROM main.stg_marketing__campaign_performance
                GROUP BY campaign_id, DATE_TRUNC('week', metric_date)
                ORDER BY campaign_id, week_start LIMIT 20
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT weekly_impressions, weekly_clicks, weekly_conversions, weekly_spend, weekly_revenue
                    FROM {MODEL_SCHEMA}.fct_campaign_weekly_performance
                    WHERE campaign_id = '{exp[0]}' AND week_start = '{exp[1]}'
                """)
                if actual:
                    assert int(actual[0][0]) == int(exp[2]), f"weekly_impressions mismatch"
                    assert int(actual[0][1]) == int(exp[3]), f"weekly_clicks mismatch"
                    assert int(actual[0][2]) == int(exp[4]), f"weekly_conversions mismatch"
                    assert abs(float(actual[0][3]) - float(exp[5])) < 0.01, f"weekly_spend mismatch"
                    assert abs(float(actual[0][4]) - float(exp[6])) < 0.01, f"weekly_revenue mismatch"
        finally:
            conn.close()

    def test_prior_week_revenue_lag(self, dbt_run):
        """Verify prior_week_revenue matches LAG of weekly_revenue partitioned by campaign."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, week_start, weekly_revenue,
                    LAG(weekly_revenue) OVER (PARTITION BY campaign_id ORDER BY week_start) as expected_prior,
                    prior_week_revenue
                FROM {MODEL_SCHEMA}.fct_campaign_weekly_performance
                ORDER BY campaign_id, week_start
            """)
            for row in rows:
                expected_prior, actual_prior = row[3], row[4]
                if expected_prior is None:
                    assert actual_prior is None
                else:
                    assert abs(float(actual_prior) - float(expected_prior)) < 0.01
        finally:
            conn.close()

    def test_weekly_roas_calculation(self, dbt_run):
        """Verify weekly_roas equals weekly_revenue/weekly_spend, or NULL when spend is zero."""
        rows = query_model("fct_campaign_weekly_performance",
            "campaign_id, week_start, weekly_revenue, weekly_spend, weekly_roas", limit=50)
        for row in rows:
            revenue, spend, roas = float(row[2]), float(row[3]), row[4]
            if spend == 0:
                assert roas is None
            else:
                assert abs(to_float(roas) - revenue / spend) < 0.0001

    def test_wow_revenue_change_calculation(self, dbt_run):
        """Verify WoW revenue change equals (current-prior)/prior, or NULL when prior is zero."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, week_start, weekly_revenue, prior_week_revenue, wow_revenue_change
                FROM {MODEL_SCHEMA}.fct_campaign_weekly_performance
                WHERE prior_week_revenue IS NOT NULL LIMIT 50
            """)
            for row in rows:
                weekly, prior, wow = float(row[2]), float(row[3]), row[4]
                if prior == 0:
                    assert wow is None
                else:
                    assert abs(to_float(wow) - (weekly - prior) / prior) < 0.0001
        finally:
            conn.close()

    def test_running_total_revenue(self, dbt_run):
        """Verify running_total_revenue is a cumulative sum of weekly_revenue per campaign."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, week_start, weekly_revenue, running_total_revenue
                FROM {MODEL_SCHEMA}.fct_campaign_weekly_performance
                ORDER BY campaign_id, week_start
            """)
            current_campaign = None
            running_sum = 0
            for row in rows:
                if row[0] != current_campaign:
                    current_campaign = row[0]
                    running_sum = 0
                running_sum += float(row[2])
                assert abs(float(row[3]) - running_sum) < 0.01
        finally:
            conn.close()


class TestPhase6MonthlyPerformance:

    def test_monthly_aggregations(self, dbt_run):
        """Verify monthly aggregated metrics match source data grouped by month."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT campaign_id, DATE_TRUNC('month', metric_date) as month_start,
                       SUM(impressions), SUM(clicks), SUM(conversions), SUM(spend), SUM(revenue)
                FROM main.stg_marketing__campaign_performance
                GROUP BY campaign_id, DATE_TRUNC('month', metric_date)
                ORDER BY campaign_id, month_start LIMIT 20
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT monthly_impressions, monthly_clicks, monthly_conversions, monthly_spend, monthly_revenue
                    FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                    WHERE campaign_id = '{exp[0]}' AND month_start = '{exp[1]}'
                """)
                if actual:
                    assert int(actual[0][0]) == int(exp[2]), f"monthly_impressions mismatch"
                    assert int(actual[0][1]) == int(exp[3]), f"monthly_clicks mismatch"
                    assert int(actual[0][2]) == int(exp[4]), f"monthly_conversions mismatch"
                    assert abs(float(actual[0][3]) - float(exp[5])) < 0.01, f"monthly_spend mismatch"
                    assert abs(float(actual[0][4]) - float(exp[6])) < 0.01, f"monthly_revenue mismatch"
        finally:
            conn.close()

    def test_prior_month_revenue_lag(self, dbt_run):
        """Verify prior_month_revenue matches LAG of monthly_revenue partitioned by campaign."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, month_start, monthly_revenue,
                    LAG(monthly_revenue) OVER (PARTITION BY campaign_id ORDER BY month_start) as expected_prior,
                    prior_month_revenue
                FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                ORDER BY campaign_id, month_start
            """)
            for row in rows:
                expected_prior, actual_prior = row[3], row[4]
                if expected_prior is None:
                    assert actual_prior is None
                else:
                    assert abs(float(actual_prior) - float(expected_prior)) < 0.01
        finally:
            conn.close()

    def test_ytd_spend_accumulates_by_year(self, dbt_run):
        """Verify ytd_spend is a cumulative sum of monthly_spend resetting each year."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, month_start, EXTRACT(YEAR FROM month_start) as year,
                       monthly_spend, ytd_spend
                FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                ORDER BY campaign_id, month_start
            """)
            current_campaign = None
            current_year = None
            running_sum = 0
            for row in rows:
                if row[0] != current_campaign or int(row[2]) != (current_year or 0):
                    current_campaign = row[0]
                    current_year = int(row[2])
                    running_sum = 0
                running_sum += float(row[3])
                assert abs(float(row[4]) - running_sum) < 0.01
        finally:
            conn.close()

    def test_ytd_conversions_accumulates_by_year(self, dbt_run):
        """Verify ytd_conversions is a cumulative sum of monthly_conversions resetting each year."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, month_start, EXTRACT(YEAR FROM month_start) as year,
                       monthly_conversions, ytd_conversions
                FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                ORDER BY campaign_id, month_start
            """)
            current_campaign = None
            current_year = None
            running_sum = 0
            for row in rows:
                if row[0] != current_campaign or int(row[2]) != (current_year or 0):
                    current_campaign = row[0]
                    current_year = int(row[2])
                    running_sum = 0
                running_sum += int(row[3])
                assert int(row[4]) == running_sum
        finally:
            conn.close()

    def test_monthly_roas_calculation(self, dbt_run):
        """Verify monthly_roas equals monthly_revenue/monthly_spend, or NULL when spend is zero."""
        rows = query_model("fct_campaign_monthly_performance",
            "campaign_id, month_start, monthly_revenue, monthly_spend, monthly_roas", limit=50)
        for row in rows:
            revenue, spend, roas = float(row[2]), float(row[3]), row[4]
            if spend == 0:
                assert roas is None
            else:
                assert abs(to_float(roas) - revenue / spend) < 0.0001

    def test_mom_revenue_change_calculation(self, dbt_run):
        """Verify MoM revenue change equals (current-prior)/prior, or NULL when prior is zero."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, month_start, monthly_revenue, prior_month_revenue, mom_revenue_change
                FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                WHERE prior_month_revenue IS NOT NULL LIMIT 50
            """)
            for row in rows:
                monthly, prior, mom = float(row[2]), float(row[3]), row[4]
                if prior == 0:
                    assert mom is None
                else:
                    assert abs(to_float(mom) - (monthly - prior) / prior) < 0.0001
        finally:
            conn.close()

    def test_ytd_revenue_accumulates_by_year(self, dbt_run):
        """Verify ytd_revenue is a cumulative sum of monthly_revenue resetting each year."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, month_start, EXTRACT(YEAR FROM month_start) as year,
                       monthly_revenue, ytd_revenue
                FROM {MODEL_SCHEMA}.fct_campaign_monthly_performance
                ORDER BY campaign_id, month_start
            """)
            current_campaign = None
            current_year = None
            running_sum = 0
            for row in rows:
                if row[0] != current_campaign or int(row[2]) != (current_year or 0):
                    current_campaign = row[0]
                    current_year = int(row[2])
                    running_sum = 0
                running_sum += float(row[3])
                assert abs(float(row[4]) - running_sum) < 0.01
        finally:
            conn.close()


# ============ PHASE 7: TREND ANALYSIS ============

class TestPhase7TrendAnalysis:

    def test_trend_values_valid(self, dbt_run):
        """Verify spend_trend and revenue_trend only contain valid values: UP, DOWN, STABLE, or NULL."""
        rows = query_model("fct_campaign_trend_analysis",
            "campaign_id, metric_date, spend_trend, revenue_trend")
        valid = {'UP', 'DOWN', 'STABLE', None}
        for row in rows:
            assert row[2] in valid
            assert row[3] in valid

    def test_spend_trend_logic(self, dbt_run):
        """Verify spend_trend is UP/DOWN/STABLE based on 5% threshold vs prior rolling average."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, metric_date, rolling_7d_avg_spend,
                    LAG(rolling_7d_avg_spend) OVER (PARTITION BY campaign_id ORDER BY metric_date) as prior_avg,
                    spend_trend
                FROM {MODEL_SCHEMA}.fct_campaign_trend_analysis
                ORDER BY campaign_id, metric_date
            """)
            for row in rows:
                current, prior, trend = row[2], row[3], row[4]
                if prior is None or float(prior) == 0:
                    assert trend is None
                elif current is None:
                    continue
                else:
                    current_f, prior_f = float(current), float(prior)
                    if current_f > prior_f * 1.05:
                        expected = 'UP'
                    elif current_f < prior_f * 0.95:
                        expected = 'DOWN'
                    else:
                        expected = 'STABLE'
                    assert trend == expected
        finally:
            conn.close()

    def test_revenue_trend_logic(self, dbt_run):
        """Verify revenue_trend is UP/DOWN/STABLE based on 5% threshold vs prior rolling average."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, metric_date, rolling_7d_avg_revenue,
                    LAG(rolling_7d_avg_revenue) OVER (PARTITION BY campaign_id ORDER BY metric_date) as prior_avg,
                    revenue_trend
                FROM {MODEL_SCHEMA}.fct_campaign_trend_analysis
                ORDER BY campaign_id, metric_date
            """)
            for row in rows:
                current, prior, trend = row[2], row[3], row[4]
                if prior is None or float(prior) == 0:
                    assert trend is None
                elif current is None:
                    continue
                else:
                    current_f, prior_f = float(current), float(prior)
                    if current_f > prior_f * 1.05:
                        expected = 'UP'
                    elif current_f < prior_f * 0.95:
                        expected = 'DOWN'
                    else:
                        expected = 'STABLE'
                    assert trend == expected
        finally:
            conn.close()


# ============ PHASE 8: ROLLING METRICS ============

class TestPhase8RollingMetrics:

    def test_days_with_data_range(self, dbt_run):
        """Verify days_with_data is between 1 and 7 for all rolling metric rows."""
        rows = query_model("int_campaign_rolling_metrics", "campaign_id, metric_date, days_with_data")
        for row in rows:
            assert 1 <= int(row[2]) <= 7

    def test_null_when_less_than_7_days(self, dbt_run):
        """Verify rolling averages are NULL when fewer than 7 days of data exist."""
        conn, db_type = get_db_connection()
        try:
            rows = execute_query(conn, db_type, f"""
                SELECT campaign_id, metric_date, days_with_data, rolling_7d_avg_spend, rolling_7d_avg_revenue
                FROM {MODEL_SCHEMA}.int_campaign_rolling_metrics
                WHERE days_with_data < 7 LIMIT 50
            """)
            for row in rows:
                assert row[3] is None
                assert row[4] is None
        finally:
            conn.close()


# ============ PHASE 9: COHORT ANALYSIS ============

class TestPhase9IntCustomerCohort:

    def test_cohort_month_calculation(self, dbt_run):
        """Verify cohort_month matches the truncated month of each customer's first redemption."""
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                sql = """
                    SELECT customer_id, DATE_TRUNC('month', MIN(CAST(redeemed_at AS TIMESTAMP))) as cohort_month
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            else:
                sql = """
                    SELECT customer_id, DATE_TRUNC('month', MIN(redeemed_at)) as cohort_month
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            expected = execute_query(conn, db_type, sql)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT cohort_month FROM {MODEL_SCHEMA}.int_customer_cohort
                    WHERE customer_id = '{exp[0]}'
                """)
                if actual:
                    assert str(actual[0][0])[:10] == str(exp[1])[:10], \
                        f"cohort_month mismatch for {exp[0]}"
        finally:
            conn.close()

    def test_first_redemption_date_calculation(self, dbt_run):
        """Verify first_redemption_date matches the earliest redemption date from source."""
        conn, db_type = get_db_connection()
        try:
            if db_type == 'snowflake':
                sql = """
                    SELECT customer_id, MIN(CAST(redeemed_at AS TIMESTAMP)) as first_redemption_date
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            else:
                sql = """
                    SELECT customer_id, MIN(redeemed_at) as first_redemption_date
                    FROM (
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__promotion_redemptions
                        UNION ALL
                        SELECT customer_id, redeemed_at FROM main.stg_marketing__coupon_redemptions
                    ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
                """
            expected = execute_query(conn, db_type, sql)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT first_redemption_date FROM {MODEL_SCHEMA}.int_customer_cohort
                    WHERE customer_id = '{exp[0]}'
                """)
                if actual:
                    assert str(actual[0][0])[:19] == str(exp[1])[:19], \
                        f"first_redemption_date mismatch for {exp[0]}"
        finally:
            conn.close()

    def test_total_redemptions_calculation(self, dbt_run):
        """Verify total_redemptions per customer matches count from source promotion + coupon data."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT customer_id, COUNT(*) as total_redemptions
                FROM (
                    SELECT customer_id FROM main.stg_marketing__promotion_redemptions
                    UNION ALL
                    SELECT customer_id FROM main.stg_marketing__coupon_redemptions
                ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT total_redemptions FROM {MODEL_SCHEMA}.int_customer_cohort
                    WHERE customer_id = '{exp[0]}'
                """)
                if actual:
                    assert int(actual[0][0]) == int(exp[1]), \
                        f"total_redemptions mismatch for {exp[0]}: got {actual[0][0]}, expected {exp[1]}"
        finally:
            conn.close()

    def test_total_discount_calculation(self, dbt_run):
        """Verify total_discount per customer matches sum from source promotion + coupon data."""
        conn, db_type = get_db_connection()
        try:
            expected = execute_query(conn, db_type, """
                SELECT customer_id, SUM(discount_amount) as total_discount
                FROM (
                    SELECT customer_id, discount_amount FROM main.stg_marketing__promotion_redemptions
                    UNION ALL
                    SELECT customer_id, discount_amount FROM main.stg_marketing__coupon_redemptions
                ) sub1 GROUP BY customer_id ORDER BY customer_id LIMIT 20
            """)
            for exp in expected:
                actual = execute_query(conn, db_type, f"""
                    SELECT total_discount FROM {MODEL_SCHEMA}.int_customer_cohort
                    WHERE customer_id = '{exp[0]}'
                """)
                if actual:
                    assert abs(float(actual[0][0]) - float(exp[1])) < 0.01, \
                        f"total_discount mismatch for {exp[0]}: got {actual[0][0]}, expected {exp[1]}"
        finally:
            conn.close()


class TestPhase9CohortPerformance:

    def test_cohort_customer_count(self, dbt_run):
        """Verify cohort total customer count matches distinct customers from source redemptions."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, """
                SELECT COUNT(DISTINCT customer_id) FROM (
                    SELECT customer_id FROM main.stg_marketing__promotion_redemptions
                    UNION
                    SELECT customer_id FROM main.stg_marketing__coupon_redemptions
                ) sub1
            """))
            actual = int(query_model("int_customer_cohort", "COUNT(DISTINCT customer_id)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_retention_rates_range(self, dbt_run):
        """Verify retention rates for months 1-3 are between 0 and 1 when not NULL."""
        rows = query_model("fct_customer_cohort_performance",
            "cohort_month, retention_rate_month_1, retention_rate_month_2, retention_rate_month_3")
        for row in rows:
            for rate in [row[1], row[2], row[3]]:
                if rate is not None:
                    assert 0 <= float(rate) <= 1

    def test_retention_rate_calculation(self, dbt_run, expected_retention):
        """Verify retention rates match independently computed values from source data."""
        conn, db_type = get_db_connection()
        try:
            for exp in expected_retention[:5]:
                cohort = exp[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT retention_rate_month_1, retention_rate_month_2, retention_rate_month_3
                    FROM {MODEL_SCHEMA}.fct_customer_cohort_performance
                    WHERE cohort_month = '{cohort}'
                """)
                if actual and exp[2] is not None:
                    assert abs(float(actual[0][0]) - float(exp[2])) < 0.01
                if actual and exp[3] is not None:
                    assert abs(float(actual[0][1]) - float(exp[3])) < 0.01
                if actual and exp[4] is not None:
                    assert abs(float(actual[0][2]) - float(exp[4])) < 0.01
        finally:
            conn.close()

    def test_avg_calculations(self, dbt_run):
        """Verify avg_redemptions and avg_discount per customer match total/size calculations."""
        rows = query_model("fct_customer_cohort_performance",
            "cohort_month, cohort_size, total_redemptions, total_discount, avg_redemptions_per_customer, avg_discount_per_customer")
        for row in rows:
            size = float(row[1])
            redemptions = float(row[2])
            discount = float(row[3])
            avg_red = float(row[4])
            avg_disc = float(row[5])
            assert abs(avg_red - redemptions / size) < 0.01
            assert abs(avg_disc - discount / size) < 0.01


# ============ PHASE 10: BRIDGE TABLE ============

class TestPhase10BridgeCampaignChannel:

    def test_default_zero_for_no_performance(self, dbt_run):
        """Verify bridge rows for campaigns without performance default revenue to zero."""
        conn, db_type = get_db_connection()
        try:
            orphans = execute_query(conn, db_type, f"""
                SELECT ch.channel_mapping_id, ch.campaign_id
                FROM main.stg_marketing__campaign_channels ch
                LEFT JOIN {MODEL_SCHEMA}.int_campaign_performance_summary p ON ch.campaign_id = p.campaign_id
                WHERE p.campaign_id IS NULL
                LIMIT 10
            """)
            for row in orphans:
                mapping_id = row[0]
                actual = execute_query(conn, db_type, f"""
                    SELECT campaign_total_revenue
                    FROM {MODEL_SCHEMA}.bridge_campaign_channel
                    WHERE channel_mapping_id = '{mapping_id}'
                """)
                if actual:
                    assert float(actual[0][0]) == 0, f"campaign_total_revenue should be 0 for channel without performance"
        finally:
            conn.close()

    def test_row_count_matches_source(self, dbt_run):
        """Verify bridge_campaign_channel row count matches source campaign channels."""
        conn, db_type = get_db_connection()
        try:
            expected = int(execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main.stg_marketing__campaign_channels"))
            actual = int(query_model("bridge_campaign_channel", "COUNT(*)")[0][0])
            assert actual == expected
        finally:
            conn.close()

    def test_channel_efficiency_calculation(self, dbt_run):
        """Verify bridge channel_efficiency equals revenue/budget, or NULL when budget is zero."""
        rows = query_model("bridge_campaign_channel",
            "channel_mapping_id, allocated_budget, campaign_total_revenue, channel_efficiency", limit=50)
        for row in rows:
            budget, revenue, efficiency = float(row[1]), float(row[2]), row[3]
            if budget == 0:
                assert efficiency is None
            else:
                assert abs(to_float(efficiency) - revenue / budget) < 0.0001


# ============ PHASE 11: IDEMPOTENCY ============

class TestPhase11Idempotency:

    def test_idempotency(self, dbt_run):
        """Verify re-running the dbt pipeline produces identical row counts for all models."""
        counts_before = {m: int(query_model(m, "COUNT(*)")[0][0]) for m in ALL_MODELS}
        run_dbt_pipeline()
        for model in ALL_MODELS:
            count_after = int(query_model(model, "COUNT(*)")[0][0])
            assert count_after == counts_before[model]
