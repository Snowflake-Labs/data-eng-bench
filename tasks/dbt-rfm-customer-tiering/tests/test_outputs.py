"""
Test verifier for RFM Customer Tiering task.
Validates RFM scoring, tier transitions, channel revenue attribution, and cohort analysis.

Enhanced with:
- Tier assignment threshold validation
- Intervention priority logic validation
- Projected tier logic validation
- RFM segment assignment checks
- Stricter tolerance for currency calculations (0.01 vs 0.5)
- Minimum row count validation
- Customer health score validation
- Churn risk prediction validation
- Lifetime value estimate validation
- Tier stability index validation
- Upgrade probability validation
- Recommended action validation
- Channel acquisition and repeat purchase rate validation
- Cohort analysis validation
"""
import subprocess
import os
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


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ END INFRASTRUCTURE ============


SCHEMA = "main"


def require(condition, msg):
    if not condition:
        raise AssertionError(msg)


def validate_columns(conn, db_type, table_name, required_columns):
    """Validate required columns exist."""
    cols = execute_query(conn, db_type, f"""
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = lower('{SCHEMA}') AND lower(table_name) = lower('{table_name}')
    """)
    col_names = {c[0].lower() for c in cols}
    missing = required_columns - col_names
    require(not missing, f"{table_name} missing columns: {missing}")
    print(f"  {table_name} has all required columns")


def validate_customer_rfm_scores(conn, db_type):
    """Validate customer_rfm_scores table structure and logic."""
    required_cols = {
        'customer_id', 'analysis_date', 'first_order_date', 'last_order_date',
        'recency_days', 'frequency', 'monetary', 'avg_order_value',
        'recency_score', 'frequency_score', 'monetary_score', 'rfm_score',
        'rfm_segment', 'assigned_tier', 'customer_lifetime_days',
        'orders_per_month', 'revenue_velocity',
        'customer_health_score', 'predicted_churn_risk',
        'expected_next_order_days', 'lifetime_value_estimate'
    }
    validate_columns(conn, db_type, 'customer_rfm_scores', required_cols)

    # Get all rows
    rows = execute_query(conn, db_type, f"""
        SELECT * FROM {SCHEMA}.customer_rfm_scores
        ORDER BY customer_id
    """)

    require(len(rows) > 0, "customer_rfm_scores is empty")
    require(len(rows) >= 10, f"customer_rfm_scores has too few rows: {len(rows)} (expected at least 10 customers)")
    print(f"  customer_rfm_scores has {len(rows)} rows")

    # Validate specific business rules
    # 1. Check analysis_date is 2024-12-31
    analysis_dates = execute_query(conn, db_type, f"""
        SELECT DISTINCT analysis_date FROM {SCHEMA}.customer_rfm_scores
    """)
    require(len(analysis_dates) == 1, f"Expected single analysis_date, got {len(analysis_dates)}")
    require(str(analysis_dates[0][0]) == '2024-12-31', f"Expected analysis_date 2024-12-31, got {analysis_dates[0][0]}")
    print("  analysis_date is correctly set to 2024-12-31")

    # 2. Validate scores are in range 1-5
    score_range = execute_query(conn, db_type, f"""
        SELECT
            MIN(recency_score), MAX(recency_score),
            MIN(frequency_score), MAX(frequency_score),
            MIN(monetary_score), MAX(monetary_score)
        FROM {SCHEMA}.customer_rfm_scores
    """)
    sr = score_range[0]
    require(int(sr[0]) >= 1 and int(sr[1]) <= 5, f"recency_score out of range: {sr[0]}-{sr[1]}")
    require(int(sr[2]) >= 1 and int(sr[3]) <= 5, f"frequency_score out of range: {sr[2]}-{sr[3]}")
    require(int(sr[4]) >= 1 and int(sr[5]) <= 5, f"monetary_score out of range: {sr[4]}-{sr[5]}")
    print("  All RFM scores are in valid range (1-5)")

    # 3. Validate RFM score calculation: (R*0.35 + F*0.25 + M*0.40)
    rfm_check = execute_query(conn, db_type, f"""
        SELECT customer_id, recency_score, frequency_score, monetary_score, rfm_score,
            ROUND((recency_score * 0.35) + (frequency_score * 0.25) + (monetary_score * 0.40), 2) as expected_rfm
        FROM {SCHEMA}.customer_rfm_scores
        WHERE ABS(rfm_score - ((recency_score * 0.35) + (frequency_score * 0.25) + (monetary_score * 0.40))) > 0.01
    """)
    require(len(rfm_check) == 0, f"RFM score calculation mismatch: {rfm_check[:5]}")
    print("  RFM score formula is correct (R*0.35 + F*0.25 + M*0.40)")

    # 4. Validate tier assignments are valid
    valid_tiers = {'Diamond', 'Platinum', 'Gold', 'Silver', 'Bronze', 'Standard'}
    tier_values = execute_query(conn, db_type, f"""
        SELECT DISTINCT assigned_tier FROM {SCHEMA}.customer_rfm_scores
    """)
    for tier in tier_values:
        require(tier[0] in valid_tiers, f"Invalid tier: {tier[0]}")
    print("  All assigned_tier values are valid")

    # 4b. Validate tier assignment logic matches rfm_score thresholds
    tier_logic_check = execute_query(conn, db_type, f"""
        SELECT customer_id, rfm_score, assigned_tier
        FROM {SCHEMA}.customer_rfm_scores
        WHERE (rfm_score >= 4.2 AND assigned_tier != 'Diamond')
           OR (rfm_score >= 3.5 AND rfm_score < 4.2 AND assigned_tier != 'Platinum')
           OR (rfm_score >= 2.8 AND rfm_score < 3.5 AND assigned_tier != 'Gold')
           OR (rfm_score >= 2.0 AND rfm_score < 2.8 AND assigned_tier != 'Silver')
           OR (rfm_score >= 1.0 AND rfm_score < 2.0 AND assigned_tier != 'Bronze')
    """)
    require(len(tier_logic_check) == 0, f"Tier assignment doesn't match rfm_score thresholds: {tier_logic_check[:5]}")
    print("  Tier assignments match rfm_score thresholds")

    # 5. Validate recency_days calculation
    recency_check = execute_query(conn, db_type, f"""
        SELECT r.customer_id, r.last_order_date, r.recency_days,
            DATEDIFF('day', r.last_order_date, CAST('2024-12-31' AS DATE)) as expected_recency
        FROM {SCHEMA}.customer_rfm_scores r
        WHERE r.recency_days != DATEDIFF('day', r.last_order_date, CAST('2024-12-31' AS DATE))
    """)
    require(len(recency_check) == 0, f"Recency days mismatch: {recency_check[:5]}")
    print("  recency_days calculation is correct")

    # 6. Validate sample RFM segment assignments
    # Check Champions: R >= 4 AND F >= 4 AND M >= 4
    segment_check_champions = execute_query(conn, db_type, f"""
        SELECT customer_id, recency_score, frequency_score, monetary_score, rfm_segment
        FROM {SCHEMA}.customer_rfm_scores
        WHERE recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
          AND rfm_segment != 'Champions'
    """)
    require(len(segment_check_champions) == 0, f"Champions segment misclassified: {segment_check_champions[:3]}")

    # Check Lost: R = 1 AND F = 1
    segment_check_lost = execute_query(conn, db_type, f"""
        SELECT customer_id, recency_score, frequency_score, rfm_segment
        FROM {SCHEMA}.customer_rfm_scores
        WHERE recency_score = 1 AND frequency_score = 1
          AND rfm_segment != 'Lost'
    """)
    require(len(segment_check_lost) == 0, f"Lost segment misclassified: {segment_check_lost[:3]}")
    print("  RFM segment assignment logic validated (sample checks)")

    # 7. Validate customer_health_score is in range 0-100
    health_range = execute_query(conn, db_type, f"""
        SELECT MIN(customer_health_score), MAX(customer_health_score)
        FROM {SCHEMA}.customer_rfm_scores
    """)
    hr = health_range[0]
    require(float(hr[0]) >= 0 and float(hr[1]) <= 100,
            f"customer_health_score out of range: {hr[0]}-{hr[1]} (expected 0-100)")
    print("  customer_health_score is in valid range (0-100)")

    # 8. Validate predicted_churn_risk is in range 0-1
    churn_range = execute_query(conn, db_type, f"""
        SELECT MIN(predicted_churn_risk), MAX(predicted_churn_risk)
        FROM {SCHEMA}.customer_rfm_scores
    """)
    cr = churn_range[0]
    require(float(cr[0]) >= 0 and float(cr[1]) <= 1,
            f"predicted_churn_risk out of range: {cr[0]}-{cr[1]} (expected 0-1)")
    print("  predicted_churn_risk is in valid range (0-1)")

    # 9. Validate churn risk logic - Champions should have low risk, Lost should have high risk
    churn_logic_check = execute_query(conn, db_type, f"""
        SELECT customer_id, rfm_segment, predicted_churn_risk
        FROM {SCHEMA}.customer_rfm_scores
        WHERE (rfm_segment = 'Champions' AND predicted_churn_risk > 0.30)
           OR (rfm_segment = 'Lost' AND predicted_churn_risk < 0.80)
    """)
    require(len(churn_logic_check) == 0, f"Churn risk logic incorrect: {churn_logic_check[:3]}")
    print("  predicted_churn_risk logic validated for key segments")

    # 10. Validate expected_next_order_days is non-negative integer
    next_order_check = execute_query(conn, db_type, f"""
        SELECT customer_id, expected_next_order_days
        FROM {SCHEMA}.customer_rfm_scores
        WHERE expected_next_order_days < 0
    """)
    require(len(next_order_check) == 0, f"expected_next_order_days has negative values: {next_order_check[:3]}")
    print("  expected_next_order_days is non-negative")

    # 11. Validate lifetime_value_estimate is positive and reasonable
    ltv_check = execute_query(conn, db_type, f"""
        SELECT customer_id, monetary, lifetime_value_estimate
        FROM {SCHEMA}.customer_rfm_scores
        WHERE lifetime_value_estimate < monetary
    """)
    require(len(ltv_check) == 0, f"lifetime_value_estimate should be >= monetary: {ltv_check[:3]}")
    print("  lifetime_value_estimate >= monetary for all customers")


def validate_customer_tier_transitions(conn, db_type):
    """Validate customer_tier_transitions table structure and logic."""
    required_cols = {
        'customer_id', 'current_tier', 'previous_tier', 'tier_direction',
        'transition_score_delta', 'days_in_current_tier', 'at_risk_flag',
        'momentum_score', 'projected_next_tier', 'intervention_priority',
        'tier_stability_index', 'upgrade_probability', 'recommended_action'
    }
    validate_columns(conn, db_type, 'customer_tier_transitions', required_cols)

    rows = execute_query(conn, db_type, f"""
        SELECT * FROM {SCHEMA}.customer_tier_transitions
        ORDER BY customer_id
    """)

    require(len(rows) > 0, "customer_tier_transitions is empty")
    require(len(rows) >= 10, f"customer_tier_transitions has too few rows: {len(rows)}")
    print(f"  customer_tier_transitions has {len(rows)} rows")

    # 1. Validate tier_direction values
    valid_directions = {'upgrade', 'downgrade', 'stable', 'new'}
    direction_values = execute_query(conn, db_type, f"""
        SELECT DISTINCT tier_direction FROM {SCHEMA}.customer_tier_transitions
    """)
    for d in direction_values:
        require(d[0] in valid_directions, f"Invalid tier_direction: {d[0]}")
    print("  All tier_direction values are valid")

    # 2. Validate at_risk_flag logic
    # Handle boolean differences: DuckDB uses true/false, Snowflake may use TRUE/FALSE or 1/0
    at_risk_check = execute_query(conn, db_type, f"""
        SELECT t.customer_id, t.at_risk_flag, r.recency_days, t.tier_direction
        FROM {SCHEMA}.customer_tier_transitions t
        JOIN {SCHEMA}.customer_rfm_scores r ON t.customer_id = r.customer_id
        WHERE (r.recency_days > 60 AND t.tier_direction IN ('downgrade', 'stable')
               AND UPPER(CAST(t.at_risk_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'YES'))
        OR (NOT (r.recency_days > 60 AND t.tier_direction IN ('downgrade', 'stable'))
               AND UPPER(CAST(t.at_risk_flag AS VARCHAR)) IN ('1', 'TRUE', 'T', 'YES'))
    """)
    require(len(at_risk_check) == 0, f"at_risk_flag logic mismatch: {at_risk_check[:5]}")
    print("  at_risk_flag logic is correct")

    # 3. Validate intervention_priority values
    valid_priorities = {'critical', 'high', 'medium', 'low'}
    priority_values = execute_query(conn, db_type, f"""
        SELECT DISTINCT intervention_priority FROM {SCHEMA}.customer_tier_transitions
    """)
    for p in priority_values:
        require(p[0] in valid_priorities, f"Invalid intervention_priority: {p[0]}")
    print("  All intervention_priority values are valid")

    # 3b. Validate intervention_priority logic
    priority_logic_check = execute_query(conn, db_type, f"""
        SELECT t.customer_id, t.at_risk_flag, t.current_tier, t.intervention_priority, t.tier_direction
        FROM {SCHEMA}.customer_tier_transitions t
        WHERE (UPPER(CAST(t.at_risk_flag AS VARCHAR)) IN ('1', 'TRUE', 'T', 'YES') AND t.current_tier IN ('Diamond', 'Platinum') AND t.intervention_priority != 'critical')
           OR (UPPER(CAST(t.at_risk_flag AS VARCHAR)) IN ('1', 'TRUE', 'T', 'YES') AND t.current_tier = 'Gold' AND t.intervention_priority != 'high')
           OR (UPPER(CAST(t.at_risk_flag AS VARCHAR)) IN ('1', 'TRUE', 'T', 'YES') AND t.current_tier = 'Silver' AND t.intervention_priority != 'medium')
           OR (t.tier_direction = 'downgrade' AND UPPER(CAST(t.at_risk_flag AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'YES') AND t.intervention_priority != 'medium')
    """)
    require(len(priority_logic_check) == 0, f"Intervention priority logic incorrect: {priority_logic_check[:5]}")
    print("  Intervention priority logic is correct")

    # 4. Validate momentum_score is clamped between -10 and 10
    momentum_check = execute_query(conn, db_type, f"""
        SELECT customer_id, momentum_score
        FROM {SCHEMA}.customer_tier_transitions
        WHERE momentum_score < -10.0 OR momentum_score > 10.0
    """)
    require(len(momentum_check) == 0, f"momentum_score out of range: {momentum_check}")
    print("  momentum_score is properly clamped (-10 to 10)")

    # 5. Validate projected_next_tier values are valid tiers
    valid_tiers = {'Diamond', 'Platinum', 'Gold', 'Silver', 'Bronze', 'Standard'}
    projected_values = execute_query(conn, db_type, f"""
        SELECT DISTINCT projected_next_tier FROM {SCHEMA}.customer_tier_transitions
    """)
    for tier in projected_values:
        require(tier[0] in valid_tiers, f"Invalid projected_next_tier: {tier[0]}")
    print("  All projected_next_tier values are valid")

    # 5b. Validate projected tier logic based on momentum score
    # Check upgrade projections (momentum >= 2.0)
    upgrade_check = execute_query(conn, db_type, f"""
        SELECT customer_id, current_tier, momentum_score, projected_next_tier
        FROM {SCHEMA}.customer_tier_transitions
        WHERE (momentum_score >= 2.0 AND current_tier = 'Bronze' AND projected_next_tier != 'Silver')
           OR (momentum_score >= 2.0 AND current_tier = 'Silver' AND projected_next_tier != 'Gold')
           OR (momentum_score >= 2.0 AND current_tier = 'Gold' AND projected_next_tier != 'Platinum')
           OR (momentum_score >= 2.0 AND current_tier = 'Platinum' AND projected_next_tier != 'Diamond')
           OR (momentum_score >= 2.0 AND current_tier = 'Diamond' AND projected_next_tier != 'Diamond')
    """)
    require(len(upgrade_check) == 0, f"Projected tier upgrade logic incorrect: {upgrade_check[:3]}")
    print("  Projected tier upgrade logic is correct")

    # 6. Validate tier direction logic
    direction_logic = execute_query(conn, db_type, f"""
        SELECT t.customer_id, t.tier_direction, t.previous_tier
        FROM {SCHEMA}.customer_tier_transitions t
        WHERE t.tier_direction = 'new' AND t.previous_tier IS NOT NULL
    """)
    require(len(direction_logic) == 0, f"new customers should have NULL previous_tier: {direction_logic}")
    print("  tier_direction 'new' correctly has NULL previous_tier")

    # 7. Validate tier_stability_index is in range 0-100
    stability_range = execute_query(conn, db_type, f"""
        SELECT MIN(tier_stability_index), MAX(tier_stability_index)
        FROM {SCHEMA}.customer_tier_transitions
    """)
    sr = stability_range[0]
    require(float(sr[0]) >= 0 and float(sr[1]) <= 100,
            f"tier_stability_index out of range: {sr[0]}-{sr[1]} (expected 0-100)")
    print("  tier_stability_index is in valid range (0-100)")

    # 8. Validate upgrade_probability is in range 0-1
    upgrade_prob_range = execute_query(conn, db_type, f"""
        SELECT MIN(upgrade_probability), MAX(upgrade_probability)
        FROM {SCHEMA}.customer_tier_transitions
    """)
    upr = upgrade_prob_range[0]
    require(float(upr[0]) >= 0 and float(upr[1]) <= 1,
            f"upgrade_probability out of range: {upr[0]}-{upr[1]} (expected 0-1)")
    print("  upgrade_probability is in valid range (0-1)")

    # 9. Validate Diamond tier has 0 upgrade_probability
    diamond_upgrade_check = execute_query(conn, db_type, f"""
        SELECT customer_id, current_tier, upgrade_probability
        FROM {SCHEMA}.customer_tier_transitions
        WHERE current_tier = 'Diamond' AND upgrade_probability > 0.0
    """)
    require(len(diamond_upgrade_check) == 0, f"Diamond tier should have 0 upgrade_probability: {diamond_upgrade_check[:3]}")
    print("  Diamond tier correctly has 0 upgrade_probability")

    # 10. Validate recommended_action values
    valid_actions = {
        'immediate_outreach', 'win_back_campaign', 'loyalty_program_upgrade',
        'retention_offer', 'engagement_program', 'vip_treatment',
        'nurture_sequence', 'standard_marketing'
    }
    action_values = execute_query(conn, db_type, f"""
        SELECT DISTINCT recommended_action FROM {SCHEMA}.customer_tier_transitions
    """)
    for action in action_values:
        require(action[0] in valid_actions, f"Invalid recommended_action: {action[0]}")
    print("  All recommended_action values are valid")

    # 11. Validate recommended_action logic for key cases
    action_logic_check = execute_query(conn, db_type, f"""
        SELECT t.customer_id, t.at_risk_flag, t.current_tier, t.recommended_action
        FROM {SCHEMA}.customer_tier_transitions t
        WHERE UPPER(CAST(t.at_risk_flag AS VARCHAR)) IN ('1', 'TRUE', 'T', 'YES')
          AND t.current_tier IN ('Diamond', 'Platinum')
          AND t.recommended_action != 'immediate_outreach'
    """)
    require(len(action_logic_check) == 0, f"recommended_action logic incorrect for at-risk high-value: {action_logic_check[:3]}")
    print("  recommended_action logic validated for key cases")


def validate_channel_revenue_attribution(conn, db_type):
    """Validate channel_revenue_attribution table structure and logic."""
    required_cols = {
        'channel', 'attributed_orders', 'raw_revenue', 'weighted_revenue',
        'revenue_share_pct', 'unique_customers', 'avg_customer_value',
        'channel_efficiency', 'yoy_growth_rate', 'channel_rank',
        'customer_acquisition_rate', 'repeat_purchase_rate',
        'avg_basket_size', 'channel_contribution_margin'
    }
    validate_columns(conn, db_type, 'channel_revenue_attribution', required_cols)

    rows = execute_query(conn, db_type, f"""
        SELECT * FROM {SCHEMA}.channel_revenue_attribution
        ORDER BY channel_rank
    """)

    require(len(rows) > 0, "channel_revenue_attribution is empty")
    require(len(rows) >= 2, f"channel_revenue_attribution has too few channels: {len(rows)}")
    print(f"  channel_revenue_attribution has {len(rows)} rows")

    # 1. Validate revenue_share_pct sums to approximately 100
    pct_sum = execute_scalar(conn, db_type, f"""
        SELECT SUM(revenue_share_pct) FROM {SCHEMA}.channel_revenue_attribution
    """)
    require(abs(float(pct_sum) - 100.0) < 0.5, f"revenue_share_pct should sum to ~100, got {pct_sum}")
    print("  revenue_share_pct sums to approximately 100%")

    # 2. Validate channel_rank is sequential starting from 1
    ranks = execute_query(conn, db_type, f"""
        SELECT channel_rank FROM {SCHEMA}.channel_revenue_attribution ORDER BY channel_rank
    """)
    expected_rank = 1
    for r in ranks:
        require(int(r[0]) == expected_rank, f"Expected rank {expected_rank}, got {r[0]}")
        expected_rank += 1
    print("  channel_rank is sequential")

    # 3. Validate avg_customer_value calculation
    avg_check = execute_query(conn, db_type, f"""
        SELECT channel, raw_revenue, unique_customers, avg_customer_value,
            ROUND(raw_revenue / unique_customers, 2) as expected_avg
        FROM {SCHEMA}.channel_revenue_attribution
        WHERE ABS(avg_customer_value - (raw_revenue / unique_customers)) > 0.01
    """)
    require(len(avg_check) == 0, f"avg_customer_value calculation mismatch: {avg_check}")
    print("  avg_customer_value calculation is correct")

    # 4. Validate channel_efficiency calculation
    eff_check = execute_query(conn, db_type, f"""
        SELECT channel, weighted_revenue, attributed_orders, channel_efficiency,
            ROUND(weighted_revenue / attributed_orders, 2) as expected_eff
        FROM {SCHEMA}.channel_revenue_attribution
        WHERE ABS(channel_efficiency - (weighted_revenue / attributed_orders)) > 0.01
    """)
    require(len(eff_check) == 0, f"channel_efficiency calculation mismatch: {eff_check}")
    print("  channel_efficiency calculation is correct")

    # 5. Validate customer_acquisition_rate sums to approximately 100
    acq_sum = execute_scalar(conn, db_type, f"""
        SELECT SUM(customer_acquisition_rate) FROM {SCHEMA}.channel_revenue_attribution
    """)
    require(abs(float(acq_sum) - 100.0) < 1.0, f"customer_acquisition_rate should sum to ~100, got {acq_sum}")
    print("  customer_acquisition_rate sums to approximately 100%")

    # 6. Validate repeat_purchase_rate is in range 0-100
    repeat_range = execute_query(conn, db_type, f"""
        SELECT MIN(repeat_purchase_rate), MAX(repeat_purchase_rate)
        FROM {SCHEMA}.channel_revenue_attribution
    """)
    rr = repeat_range[0]
    require(float(rr[0]) >= 0 and float(rr[1]) <= 100,
            f"repeat_purchase_rate out of range: {rr[0]}-{rr[1]} (expected 0-100)")
    print("  repeat_purchase_rate is in valid range (0-100)")

    # 7. Validate avg_basket_size is positive
    basket_check = execute_query(conn, db_type, f"""
        SELECT channel, avg_basket_size
        FROM {SCHEMA}.channel_revenue_attribution
        WHERE avg_basket_size <= 0
    """)
    require(len(basket_check) == 0, f"avg_basket_size should be positive: {basket_check}")
    print("  avg_basket_size is positive for all channels")

    # 8. Validate channel_contribution_margin is reasonable (positive and < 150%)
    margin_range = execute_query(conn, db_type, f"""
        SELECT MIN(channel_contribution_margin), MAX(channel_contribution_margin)
        FROM {SCHEMA}.channel_revenue_attribution
    """)
    mr = margin_range[0]
    require(float(mr[0]) >= 0 and float(mr[1]) <= 150,
            f"channel_contribution_margin out of reasonable range: {mr[0]}-{mr[1]}")
    print("  channel_contribution_margin is in reasonable range")


def validate_customer_cohort_analysis(conn, db_type):
    """Validate customer_cohort_analysis table structure and logic."""
    required_cols = {
        'cohort_month', 'cohort_size', 'months_since_acquisition',
        'active_customers', 'retention_rate', 'cohort_revenue',
        'cumulative_revenue', 'avg_revenue_per_customer', 'orders_count',
        'avg_order_frequency', 'churn_rate', 'cohort_ltv'
    }
    validate_columns(conn, db_type, 'customer_cohort_analysis', required_cols)

    rows = execute_query(conn, db_type, f"""
        SELECT * FROM {SCHEMA}.customer_cohort_analysis
        ORDER BY cohort_month, months_since_acquisition
    """)

    require(len(rows) > 0, "customer_cohort_analysis is empty")
    require(len(rows) >= 12, f"customer_cohort_analysis has too few rows: {len(rows)} (expected at least 12)")
    print(f"  customer_cohort_analysis has {len(rows)} rows")

    # 1. Validate cohort_month format (YYYY-MM)
    # Use a cross-compatible check instead of regexp_matches
    cohort_format_check = execute_query(conn, db_type, f"""
        SELECT DISTINCT cohort_month FROM {SCHEMA}.customer_cohort_analysis
        WHERE LENGTH(cohort_month) != 7
           OR SUBSTRING(cohort_month, 5, 1) != '-'
    """)
    require(len(cohort_format_check) == 0, f"Invalid cohort_month format: {cohort_format_check}")
    print("  cohort_month format is valid (YYYY-MM)")

    # 2. Validate months_since_acquisition starts from 0
    min_months = execute_scalar(conn, db_type, f"""
        SELECT MIN(months_since_acquisition) FROM {SCHEMA}.customer_cohort_analysis
    """)
    require(int(min_months) == 0, f"months_since_acquisition should start from 0, got {min_months}")
    print("  months_since_acquisition starts from 0")

    # 3. Validate retention_rate is in range 0-100
    retention_range = execute_query(conn, db_type, f"""
        SELECT MIN(retention_rate), MAX(retention_rate)
        FROM {SCHEMA}.customer_cohort_analysis
    """)
    rr = retention_range[0]
    require(float(rr[0]) >= 0 and float(rr[1]) <= 100,
            f"retention_rate out of range: {rr[0]}-{rr[1]} (expected 0-100)")
    print("  retention_rate is in valid range (0-100)")

    # 4. Validate retention_rate calculation
    retention_calc_check = execute_query(conn, db_type, f"""
        SELECT cohort_month, months_since_acquisition, cohort_size, active_customers, retention_rate,
            ROUND((CAST(active_customers AS DOUBLE) / CAST(cohort_size AS DOUBLE)) * 100, 2) as expected_retention
        FROM {SCHEMA}.customer_cohort_analysis
        WHERE cohort_size > 0 AND ABS(retention_rate - ((CAST(active_customers AS DOUBLE) / CAST(cohort_size AS DOUBLE)) * 100)) > 0.1
    """)
    require(len(retention_calc_check) == 0, f"retention_rate calculation mismatch: {retention_calc_check[:3]}")
    print("  retention_rate calculation is correct")

    # 5. Validate churn_rate is in range 0-100
    churn_range = execute_query(conn, db_type, f"""
        SELECT MIN(churn_rate), MAX(churn_rate)
        FROM {SCHEMA}.customer_cohort_analysis
        WHERE churn_rate IS NOT NULL
    """)
    if churn_range and churn_range[0][0] is not None:
        cr = churn_range[0]
        require(float(cr[0]) >= 0 and float(cr[1]) <= 100,
                f"churn_rate out of range: {cr[0]}-{cr[1]} (expected 0-100)")
    print("  churn_rate is in valid range (0-100)")

    # 6. Validate month 0 has churn_rate = 0
    month0_churn_check = execute_query(conn, db_type, f"""
        SELECT cohort_month, churn_rate
        FROM {SCHEMA}.customer_cohort_analysis
        WHERE months_since_acquisition = 0 AND churn_rate != 0
    """)
    require(len(month0_churn_check) == 0, f"Month 0 should have churn_rate = 0: {month0_churn_check[:3]}")
    print("  Month 0 correctly has churn_rate = 0")

    # 7. Validate cumulative_revenue is non-decreasing within cohort
    cumulative_check = execute_query(conn, db_type, f"""
        WITH ranked AS (
            SELECT cohort_month, months_since_acquisition, cumulative_revenue,
                LAG(cumulative_revenue) OVER (PARTITION BY cohort_month ORDER BY months_since_acquisition) as prev_cumulative
            FROM {SCHEMA}.customer_cohort_analysis
        )
        SELECT * FROM ranked
        WHERE prev_cumulative IS NOT NULL AND cumulative_revenue < prev_cumulative
    """)
    require(len(cumulative_check) == 0, f"cumulative_revenue should be non-decreasing: {cumulative_check[:3]}")
    print("  cumulative_revenue is non-decreasing within cohorts")

    # 8. Validate cohort_ltv calculation
    ltv_calc_check = execute_query(conn, db_type, f"""
        SELECT cohort_month, months_since_acquisition, cumulative_revenue, cohort_size, cohort_ltv,
            ROUND(cumulative_revenue / cohort_size, 2) as expected_ltv
        FROM {SCHEMA}.customer_cohort_analysis
        WHERE cohort_size > 0 AND ABS(cohort_ltv - (cumulative_revenue / cohort_size)) > 0.1
    """)
    require(len(ltv_calc_check) == 0, f"cohort_ltv calculation mismatch: {ltv_calc_check[:3]}")
    print("  cohort_ltv calculation is correct")

    # 9. Validate active_customers <= cohort_size
    active_check = execute_query(conn, db_type, f"""
        SELECT cohort_month, months_since_acquisition, active_customers, cohort_size
        FROM {SCHEMA}.customer_cohort_analysis
        WHERE active_customers > cohort_size
    """)
    require(len(active_check) == 0, f"active_customers should be <= cohort_size: {active_check[:3]}")
    print("  active_customers <= cohort_size for all rows")


def validate_data_relationships(conn, db_type):
    """Validate relationships between tables."""
    # All customers in tier_transitions should be in rfm_scores
    orphan_check = execute_query(conn, db_type, f"""
        SELECT t.customer_id
        FROM {SCHEMA}.customer_tier_transitions t
        LEFT JOIN {SCHEMA}.customer_rfm_scores r ON t.customer_id = r.customer_id
        WHERE r.customer_id IS NULL
    """)
    require(len(orphan_check) == 0, f"Orphan customers in tier_transitions: {orphan_check}")
    print("  All tier_transitions customers exist in rfm_scores")

    # Current tier in transitions should match assigned_tier in rfm_scores
    tier_match = execute_query(conn, db_type, f"""
        SELECT t.customer_id, t.current_tier, r.assigned_tier
        FROM {SCHEMA}.customer_tier_transitions t
        JOIN {SCHEMA}.customer_rfm_scores r ON t.customer_id = r.customer_id
        WHERE t.current_tier != r.assigned_tier
    """)
    require(len(tier_match) == 0, f"Tier mismatch between tables: {tier_match[:5]}")
    print("  current_tier matches assigned_tier across tables")


@pytest.fixture(scope="session")
def setup_database():
    """Connect to database to validate outputs."""
    print("=" * 60)
    print("RFM Customer Tiering Task Verification")
    print("=" * 60)
    print("\nConnecting to database to validate outputs...\n")

    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


def test_customer_rfm_scores(setup_database):
    """Test customer_rfm_scores table structure and logic."""
    conn, db_type = setup_database
    print("[1/5] Validating customer_rfm_scores...")
    validate_customer_rfm_scores(conn, db_type)
    print()


def test_customer_tier_transitions(setup_database):
    """Test customer_tier_transitions table structure and logic."""
    conn, db_type = setup_database
    print("[2/5] Validating customer_tier_transitions...")
    validate_customer_tier_transitions(conn, db_type)
    print()


def test_channel_revenue_attribution(setup_database):
    """Test channel_revenue_attribution table structure and logic."""
    conn, db_type = setup_database
    print("[3/5] Validating channel_revenue_attribution...")
    validate_channel_revenue_attribution(conn, db_type)
    print()


def test_customer_cohort_analysis(setup_database):
    """Test customer_cohort_analysis table structure and logic."""
    conn, db_type = setup_database
    print("[4/5] Validating customer_cohort_analysis...")
    validate_customer_cohort_analysis(conn, db_type)
    print()


def test_data_relationships(setup_database):
    """Test relationships between tables."""
    conn, db_type = setup_database
    print("[5/5] Validating data relationships...")
    validate_data_relationships(conn, db_type)
    print()
    print("=" * 60)
    print("All tests passed successfully!")
    print("=" * 60)
