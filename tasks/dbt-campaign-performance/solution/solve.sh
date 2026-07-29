#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: main
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"

    # Create marketing tables in Snowflake (these are normally created during Docker build for DuckDB only)
    echo "Creating marketing tables in Snowflake..."
    python3 << 'PYEOF'
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
import os

private_key_path = "/tmp/snowflake_private_key.p8"
with open(private_key_path, "rb") as key_file:
    p_key = serialization.load_pem_private_key(
        key_file.read(),
        password=os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "").encode() if os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE") else None,
        backend=default_backend()
    )
pkb = p_key.private_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)

conn = snowflake.connector.connect(
    user=os.environ["SNOWFLAKE_USER"],
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    host=os.environ.get("SNOWFLAKE_HOST") or None,
    private_key=pkb,
    database=os.environ["SNOWFLAKE_DATABASE"],
    schema="MAIN",
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    role=os.environ.get("SNOWFLAKE_ROLE", "")
)
cur = conn.cursor()

# Create campaigns table
cur.execute("""
CREATE TABLE IF NOT EXISTS MAIN._RAW_MARKETING_CAMPAIGNS (
    campaign_id VARCHAR PRIMARY KEY,
    campaign_name VARCHAR,
    channel VARCHAR,
    start_date DATE,
    end_date DATE,
    budget DECIMAL(18,4),
    status VARCHAR,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
""")

cur.execute("""
INSERT INTO MAIN._RAW_MARKETING_CAMPAIGNS (campaign_id, campaign_name, channel, start_date, end_date, budget, status) VALUES
('camp-001', 'Summer Sale 2025', 'EMAIL', '2025-06-01', '2025-06-30', 5000.00, 'COMPLETED'),
('camp-002', 'Back to School', 'EMAIL', '2025-08-01', '2025-08-31', 7500.00, 'COMPLETED'),
('camp-003', 'Black Friday Deals', 'EMAIL', '2025-11-20', '2025-11-30', 15000.00, 'COMPLETED'),
('camp-004', 'Holiday Gift Guide', 'EMAIL', '2025-12-01', '2025-12-24', 12000.00, 'COMPLETED'),
('camp-005', 'New Year Clearance', 'EMAIL', '2026-01-01', '2026-01-15', 8000.00, 'ACTIVE'),
('camp-006', 'Spring Collection Launch', 'EMAIL', '2025-03-15', '2025-04-15', 6000.00, 'COMPLETED'),
('camp-007', 'VIP Exclusive Offers', 'EMAIL', '2025-05-01', '2025-05-31', 3000.00, 'COMPLETED'),
('camp-008', 'Flash Sale Weekend', 'EMAIL', '2025-07-10', '2025-07-12', 2000.00, 'COMPLETED'),
('camp-009', 'Loyalty Rewards', 'EMAIL', '2025-09-01', '2025-09-30', 4500.00, 'COMPLETED'),
('camp-010', 'Product Launch - Electronics', 'EMAIL', '2025-10-15', '2025-10-31', 9000.00, 'COMPLETED'),
('camp-011', 'Winter Warmers', 'EMAIL', '2025-11-01', '2025-11-15', 5500.00, 'COMPLETED'),
('camp-012', 'Cyber Monday Special', 'EMAIL', '2025-12-01', '2025-12-02', 10000.00, 'COMPLETED')
""")

# Create email events table
cur.execute("""
CREATE TABLE IF NOT EXISTS MAIN._RAW_MARKETING_EMAIL_EVENTS (
    event_id VARCHAR PRIMARY KEY,
    customer_id VARCHAR,
    campaign_id VARCHAR,
    event_type VARCHAR,
    event_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
""")

# Get customer IDs
cur.execute("""
CREATE TEMPORARY TABLE temp_customers AS
SELECT customer_id, ROW_NUMBER() OVER (ORDER BY customer_id) as rn
FROM MAIN.STG_CUSTOMER__CUSTOMERS
WHERE status = 'ACTIVE'
LIMIT 500
""")

# Campaign event data: (campaign_id, prefix, base_ts, interval_unit, sent_max, open_max, click_max, conv_max, offset_min, offset_max for sent)
campaigns = [
    ('camp-001', 'evt-001', '2025-06-01 10:00:00', '2025-06-01 12:00:00', '2025-06-01 14:00:00', '2025-06-02 10:00:00', 1, 2, 3, 5, 200, 120, 60, 25, 1, 200),
    ('camp-002', 'evt-002', '2025-08-01 09:00:00', '2025-08-01 11:00:00', '2025-08-01 13:00:00', '2025-08-02 10:00:00', 1, 2, 3, 5, 250, 100, 35, 12, 1, 250),
    ('camp-003', 'evt-003', '2025-11-20 08:00:00', '2025-11-20 10:00:00', '2025-11-20 12:00:00', '2025-11-21 10:00:00', 1, 1, 2, 3, 400, 300, 180, 80, 1, 400),
    ('camp-005', 'evt-005', '2026-01-01 10:00:00', '2026-01-01 12:00:00', '2026-01-01 15:00:00', '2026-01-02 10:00:00', 1, 2, 3, 5, 180, 70, 20, 5, 1, 180),
    ('camp-007', 'evt-007', '2025-05-01 09:00:00', '2025-05-01 11:00:00', '2025-05-01 13:00:00', '2025-05-02 10:00:00', 1, 2, 2, 5, 80, 65, 50, 30, 1, 80),
    ('camp-008', 'evt-008', '2025-07-10 08:00:00', '2025-07-10 09:00:00', '2025-07-10 10:00:00', '2025-07-10 12:00:00', 0.5, 1, 1, 2, 100, 85, 70, 45, 1, 100),
    ('camp-010', 'evt-010', '2025-10-15 09:00:00', '2025-10-15 11:00:00', '2025-10-15 14:00:00', '2025-10-16 10:00:00', 1, 2, 3, 5, 300, 90, 15, 8, 1, 300),
]

for camp_id, prefix, sent_ts, open_ts, click_ts, conv_ts, sent_int, open_int, click_int, conv_int, sent_max, open_max, click_max, conv_max, rn_min, rn_max in campaigns:
    for event_type, base_ts, interval_min, max_rn in [('sent', sent_ts, sent_int, sent_max), ('open', open_ts, open_int, open_max), ('click', click_ts, click_int, click_max), ('conv', conv_ts, conv_int, conv_max)]:
        evt_type = {'sent': 'SENT', 'open': 'OPENED', 'click': 'CLICKED', 'conv': 'CONVERTED'}[event_type]
        cur.execute(f"""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    '{prefix}-' || rn || '-{event_type}',
    customer_id,
    '{camp_id}',
    '{evt_type}',
    DATEADD(second, rn * {interval_min} * 60, '{base_ts}'::TIMESTAMP)
FROM temp_customers WHERE rn >= {rn_min} AND rn <= {max_rn}
""")

# Campaigns with range-based customer selection
# camp-004: rn BETWEEN 50 AND 350/230/130/100
for event_type, base_ts, interval_min, rn_min, rn_max in [
    ('sent', '2025-12-01 09:00:00', 1, 50, 350),
    ('open', '2025-12-01 11:00:00', 2, 50, 230),
    ('click', '2025-12-01 14:00:00', 2, 50, 130),
    ('conv', '2025-12-02 10:00:00', 5, 50, 100),
]:
    evt_type = {'sent': 'SENT', 'open': 'OPENED', 'click': 'CLICKED', 'conv': 'CONVERTED'}[event_type]
    cur.execute(f"""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-004-' || rn || '-{event_type}',
    customer_id,
    'camp-004',
    '{evt_type}',
    DATEADD(second, rn * {interval_min} * 60, '{base_ts}'::TIMESTAMP)
FROM temp_customers WHERE rn BETWEEN {rn_min} AND {rn_max}
""")

# camp-006: Spring Collection - Only SENT and OPENED (no clicks/conversions)
cur.execute("""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT 'evt-006-' || rn || '-sent', customer_id, 'camp-006', 'SENT',
    DATEADD(second, rn * 60, '2025-03-15 10:00:00'::TIMESTAMP)
FROM temp_customers WHERE rn BETWEEN 100 AND 250
""")
cur.execute("""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT 'evt-006-' || rn || '-open', customer_id, 'camp-006', 'OPENED',
    DATEADD(second, rn * 3 * 60, '2025-03-15 14:00:00'::TIMESTAMP)
FROM temp_customers WHERE rn BETWEEN 100 AND 130
""")

# camp-009: Loyalty Rewards (rn BETWEEN 200 AND X)
for event_type, base_ts, interval_min, rn_max in [
    ('sent', '2025-09-01 10:00:00', 1, 400),
    ('open', '2025-09-01 12:00:00', 2, 320),
    ('click', '2025-09-01 15:00:00', 3, 260),
    ('conv', '2025-09-02 10:00:00', 5, 225),
]:
    evt_type = {'sent': 'SENT', 'open': 'OPENED', 'click': 'CLICKED', 'conv': 'CONVERTED'}[event_type]
    cur.execute(f"""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-009-' || rn || '-{event_type}',
    customer_id,
    'camp-009',
    '{evt_type}',
    DATEADD(second, rn * {interval_min} * 60, '{base_ts}'::TIMESTAMP)
FROM temp_customers WHERE rn BETWEEN 200 AND {rn_max}
""")

# camp-011: Winter Warmers (rn BETWEEN 150 AND X)
for event_type, base_ts, interval_min, rn_max in [
    ('sent', '2025-11-01 10:00:00', 1, 350),
    ('open', '2025-11-01 12:00:00', 2, 280),
    ('click', '2025-11-01 14:00:00', 2, 210),
    ('conv', '2025-11-02 10:00:00', 5, 180),
]:
    evt_type = {'sent': 'SENT', 'open': 'OPENED', 'click': 'CLICKED', 'conv': 'CONVERTED'}[event_type]
    cur.execute(f"""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-011-' || rn || '-{event_type}',
    customer_id,
    'camp-011',
    '{evt_type}',
    DATEADD(second, rn * {interval_min} * 60, '{base_ts}'::TIMESTAMP)
FROM temp_customers WHERE rn BETWEEN 150 AND {rn_max}
""")

# camp-012: Cyber Monday (rn <= X)
for event_type, base_ts, interval_sec, max_rn in [
    ('sent', '2025-12-01 06:00:00', 30, 450),
    ('open', '2025-12-01 08:00:00', 60, 320),
    ('click', '2025-12-01 10:00:00', 60, 200),
    ('conv', '2025-12-01 14:00:00', 120, 90),
]:
    evt_type = {'sent': 'SENT', 'open': 'OPENED', 'click': 'CLICKED', 'conv': 'CONVERTED'}[event_type]
    cur.execute(f"""
INSERT INTO MAIN._RAW_MARKETING_EMAIL_EVENTS (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-012-' || rn || '-{event_type}',
    customer_id,
    'camp-012',
    '{evt_type}',
    DATEADD(second, rn * {interval_sec}, '{base_ts}'::TIMESTAMP)
FROM temp_customers WHERE rn <= {max_rn}
""")

cur.execute("DROP TABLE IF EXISTS temp_customers")

# Verify
cur.execute("SELECT 'campaigns' as t, COUNT(*) as c FROM MAIN._RAW_MARKETING_CAMPAIGNS UNION ALL SELECT 'email_events', COUNT(*) FROM MAIN._RAW_MARKETING_EMAIL_EVENTS")
for row in cur.fetchall():
    print(f"  {row[0]}: {row[1]} rows")

cur.close()
conn.close()
print("Marketing tables created successfully!")
PYEOF

    # Override staging models to point to renamed raw tables (avoid circular reference)
    echo "Overriding staging models to reference raw tables..."
    mkdir -p "$DBT_PROJECT_DIR/models/staging/marketing"

    cat > "$DBT_PROJECT_DIR/models/staging/marketing/stg_marketing__campaigns.sql" << 'STGEOF'
{{ config(materialized='view', tags=['staging', 'marketing']) }}
SELECT * FROM MAIN._RAW_MARKETING_CAMPAIGNS
STGEOF

    cat > "$DBT_PROJECT_DIR/models/staging/marketing/stg_marketing__email_events.sql" << 'STGEOF'
{{ config(materialized='view', tags=['staging', 'marketing']) }}
SELECT * FROM MAIN._RAW_MARKETING_EMAIL_EVENTS
STGEOF

else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"

    # Rename existing marketing tables/views to _raw prefix to avoid circular reference
    echo "Renaming marketing tables to avoid circular reference..."
    python3 << 'PYEOF'
import duckdb
conn = duckdb.connect('/app/database/retail.duckdb')
for name, raw in [('stg_marketing__campaigns', '_raw_marketing_campaigns'), ('stg_marketing__email_events', '_raw_marketing_email_events')]:
    try:
        conn.execute(f"ALTER TABLE main.{name} RENAME TO {raw}")
        print(f"  Renamed table {name} -> {raw}")
    except:
        try:
            conn.execute(f"CREATE TABLE main.{raw} AS SELECT * FROM main.{name}")
            conn.execute(f"DROP VIEW IF EXISTS main.{name}")
            print(f"  Materialized view {name} -> table {raw}")
        except Exception as e:
            print(f"  Warning: Could not rename {name}: {e}")
conn.close()
PYEOF

    # Override staging models to reference renamed raw tables
    echo "Overriding staging models for DuckDB..."
    mkdir -p "$DBT_PROJECT_DIR/models/staging/marketing"

    cat > "$DBT_PROJECT_DIR/models/staging/marketing/stg_marketing__campaigns.sql" << 'STGEOF'
{{ config(materialized='view', tags=['staging', 'marketing']) }}
SELECT * FROM main._raw_marketing_campaigns
STGEOF

    cat > "$DBT_PROJECT_DIR/models/staging/marketing/stg_marketing__email_events.sql" << 'STGEOF'
{{ config(materialized='view', tags=['staging', 'marketing']) }}
SELECT * FROM main._raw_marketing_email_events
STGEOF
fi

# Create the marketing marts directory if it doesn't exist
mkdir -p "$DBT_PROJECT_DIR/models/marts/marketing"

cat > "$DBT_PROJECT_DIR/models/marts/marketing/rpt_campaign_performance.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['mart', 'marketing', 'campaigns']
    )
}}

with campaigns as (
    select
        campaign_id,
        campaign_name,
        channel,
        start_date,
        end_date,
        -- Calculate campaign duration in days (at least 1 to avoid division by zero)
        GREATEST(1, DATEDIFF('day', start_date, end_date)) as campaign_days
    from {{ ref('stg_marketing__campaigns') }}
    where campaign_id is not null
),

email_events as (
    select
        event_id,
        customer_id,
        campaign_id,
        event_type,
        event_at
    from {{ ref('stg_marketing__email_events') }}
    where campaign_id is not null
),

orders as (
    select
        ORDER_ID as order_id,
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('int_sales__orders_enriched') }}
    where UPPER(status) NOT IN ('CANCELLED', 'C')
      and ORDER_ID is not null
),

-- Get conversion events with their dates
conversions as (
    select
        customer_id,
        campaign_id,
        event_at as converted_at
    from email_events
    where event_type = 'CONVERTED'
),

-- Attribute revenue: orders within 30 days of conversion
attributed_orders as (
    select
        c.campaign_id,
        c.customer_id,
        o.grand_total
    from conversions c
    inner join orders o
        on c.customer_id = o.customer_id
        and o.ordered_at >= c.converted_at
        and o.ordered_at <= c.converted_at + interval '30 days'
),

-- Aggregate email metrics per campaign
campaign_email_metrics as (
    select
        campaign_id,
        count(case when event_type = 'SENT' then 1 end) as emails_sent,
        count(case when event_type = 'OPENED' then 1 end) as emails_opened,
        count(case when event_type = 'CLICKED' then 1 end) as emails_clicked,
        count(case when event_type = 'CONVERTED' then 1 end) as conversions,
        count(distinct customer_id) as unique_recipients
    from email_events
    group by campaign_id
),

-- Aggregate attributed revenue per campaign
campaign_revenue as (
    select
        campaign_id,
        coalesce(sum(grand_total), 0) as attributed_revenue
    from attributed_orders
    group by campaign_id
),

-- Calculate base rates and assign channel_category
campaign_rates as (
    select
        c.campaign_id,
        c.campaign_name,
        c.channel,
        c.campaign_days,
        coalesce(m.emails_sent, 0) as emails_sent,
        coalesce(m.emails_opened, 0) as emails_opened,
        coalesce(m.emails_clicked, 0) as emails_clicked,
        coalesce(m.conversions, 0) as conversions,
        coalesce(m.unique_recipients, 0) as unique_recipients,

        -- Safe division for rates
        coalesce(m.emails_opened * 1.0 / NULLIF(m.emails_sent, 0), 0) as open_rate,
        coalesce(m.emails_clicked * 1.0 / NULLIF(m.emails_opened, 0), 0) as click_rate,
        coalesce(m.conversions * 1.0 / NULLIF(m.unique_recipients, 0), 0) as conversion_rate,

        coalesce(r.attributed_revenue, 0) as attributed_revenue,
        r.attributed_revenue * 1.0 / NULLIF(m.conversions, 0) as revenue_per_conversion,

        -- Determine channel_category based on channel name
        case
            when UPPER(c.channel) LIKE '%PPC%'
                 OR UPPER(c.channel) LIKE '%PAID%'
                 OR UPPER(c.channel) LIKE '%ADS%'
                 OR UPPER(c.channel) LIKE '%SPONSORED%'
                 OR UPPER(c.channel) LIKE '%CPC%'
                 OR UPPER(c.channel) LIKE '%DISPLAY%' then 'PAID'
            when UPPER(c.channel) LIKE '%EMAIL%'
                 OR UPPER(c.channel) LIKE '%NEWSLETTER%'
                 OR UPPER(c.channel) LIKE '%SMS%'
                 OR UPPER(c.channel) LIKE '%PUSH%'
                 OR UPPER(c.channel) LIKE '%BLOG%'
                 OR UPPER(c.channel) LIKE '%WEBSITE%' then 'OWNED'
            when UPPER(c.channel) LIKE '%SOCIAL%'
                 OR UPPER(c.channel) LIKE '%REFERRAL%'
                 OR UPPER(c.channel) LIKE '%ORGANIC%'
                 OR UPPER(c.channel) LIKE '%VIRAL%'
                 OR UPPER(c.channel) LIKE '%WORD%' then 'EARNED'
            else 'OTHER'
        end as channel_category

    from campaigns c
    left join campaign_email_metrics m on c.campaign_id = m.campaign_id
    left join campaign_revenue r on c.campaign_id = r.campaign_id
    where m.campaign_id is not null  -- Only campaigns with email events
),

-- Calculate peer comparison metrics (partitioned by channel_category)
with_peer_metrics as (
    select
        *,
        -- Rank by conversion rate within channel_category (1 = best, descending order)
        DENSE_RANK() OVER (PARTITION BY channel_category ORDER BY conversion_rate DESC) as category_conversion_rank,

        -- Total campaigns in channel_category
        COUNT(*) OVER (PARTITION BY channel_category) as category_campaign_count,

        -- Channel_category average conversion rate
        AVG(conversion_rate) OVER (PARTITION BY channel_category) as category_avg_conversion,

        -- Revenue percentile within channel_category
        PERCENT_RANK() OVER (PARTITION BY channel_category ORDER BY attributed_revenue) as category_revenue_percentile,

        -- Performance index percentile within channel_category (for tier calculation)
        PERCENT_RANK() OVER (PARTITION BY channel_category ORDER BY
            (open_rate * 0.25 + click_rate * 0.25 + conversion_rate * 0.30 +
             LEAST(attributed_revenue / NULLIF(campaign_days, 0) / 1000.0, 1.0) * 0.20)
        ) as perf_percentile_in_category

    from campaign_rates
),

-- Calculate performance index and above_category_avg
with_performance as (
    select
        *,
        -- Above channel_category average conversion (1/0 boolean)
        case when conversion_rate > category_avg_conversion then 1 else 0 end as above_category_avg_conversion,

        -- Performance index: weighted composite (0-100 scale)
        -- Weights: open_rate 25%, click_rate 25%, conversion_rate 30%, revenue efficiency 20%
        LEAST(100, GREATEST(0,
            (open_rate * 0.25 +
             click_rate * 0.25 +
             conversion_rate * 0.30 +
             LEAST(coalesce(attributed_revenue / NULLIF(campaign_days, 0) / 1000.0, 0), 1.0) * 0.20
            ) * 100
        )) as performance_index

    from with_peer_metrics
),

-- Assign campaign tiers using waterfall logic
final as (
    select
        campaign_id,
        campaign_name,
        channel,
        channel_category,
        emails_sent,
        emails_opened,
        emails_clicked,
        conversions,
        unique_recipients,
        open_rate,
        click_rate,
        conversion_rate,
        attributed_revenue,
        revenue_per_conversion,
        category_conversion_rank,
        category_campaign_count,
        above_category_avg_conversion,
        category_revenue_percentile,
        performance_index,

        -- Waterfall tier logic (check worst first)
        case
            -- ineffective: No conversions at all
            when conversions = 0 then 'ineffective'
            -- underperforming: Below category average conversion AND click_rate < 20%
            when above_category_avg_conversion = 0 and click_rate < 0.20 then 'underperforming'
            -- developing: Below category average conversion OR click_rate < 40%
            when above_category_avg_conversion = 0 or click_rate < 0.40 then 'developing'
            -- top_performer: Top 20% by performance_index within category AND conversion_rate > 10%
            when perf_percentile_in_category >= 0.80 and conversion_rate > 0.10 then 'top_performer'
            -- effective: Above category average AND performance_index >= 50
            when above_category_avg_conversion = 1 and performance_index >= 50 then 'effective'
            -- Fallback to developing
            else 'developing'
        end as campaign_tier

    from with_performance
)

select * from final
EOF

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps
dbt run -s stg_marketing__campaigns stg_marketing__email_events rpt_campaign_performance
