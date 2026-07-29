#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Create custom schema using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schema using admin role..."
    python3 << 'CREATE_SCHEMA_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'attribution_analytics'
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
db = os.environ['SNOWFLAKE_DATABASE']
try:
    cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema}")
    cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    print(f"Successfully created schema {schema} and granted permissions to {agent_role}")
except Exception as e:
    print(f"Warning: Failed to create schema {schema}: {e}")
conn.close()
CREATE_SCHEMA_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

cd /app

# Create dbt project structure
mkdir -p attribution_project/{models/staging,models/intermediate,models/marts}

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > ~/.dbt/profiles.yml <<PROFILES
attribution_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: attribution_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > ~/.dbt/profiles.yml << 'EOF'
attribution_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: attribution_analytics
EOF
    echo "Configured DuckDB profile"
fi

# Create dbt_project.yml
cat > attribution_project/dbt_project.yml << 'EOF'
name: 'attribution_project'
version: '1.0.0'
config-version: 2
profile: 'attribution_project'

model-paths: ["models"]

models:
  attribution_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
EOF

# Create sources configuration
cat > attribution_project/models/staging/_sources.yml << 'EOF'
version: 2

sources:
  - name: marketing
    schema: MARKETING
    tables:
      - name: CAMPAIGN_PERFORMANCE
      - name: MARKETING_CAMPAIGNS
      - name: CAMPAIGN_CHANNELS
  - name: orders
    schema: ORDERS
    tables:
      - name: ORDERS
EOF

# Create staging model for campaign performance
# Using Jinja to handle SQL dialect differences
cat > attribution_project/models/staging/stg_campaign_performance.sql << 'EOF'
{{ config(materialized='view') }}

/*
    Staging model for campaign performance with decay weight calculations.
    Reference (as-of) date is data-relative: the latest METRIC_DATE in the
    source (do NOT use CURRENT_DATE — the data may not reach the present day).
    Lookback: 30 days.
*/

with ref_date as (

    select max(cast(METRIC_DATE as date)) as ref_date
    from {{ source('marketing', 'CAMPAIGN_PERFORMANCE') }}

),

source as (

    select
        trim(CAMPAIGN_ID) as campaign_id,
        cast(METRIC_DATE as date) as metric_date,
        cast(REVENUE as decimal(18,2)) as revenue,
        cast(CONVERSIONS as integer) as conversions,
        cast(IMPRESSIONS as integer) as impressions,
        cast(CLICKS as integer) as clicks
    from {{ source('marketing', 'CAMPAIGN_PERFORMANCE') }}
    where METRIC_DATE >= {{ dbt.dateadd('day', -30, '(select ref_date from ref_date)') }}
      and METRIC_DATE <= (select ref_date from ref_date)
),

with_decay as (
    select
        campaign_id,
        metric_date,
        revenue,
        conversions,
        impressions,
        clicks,
        {{ dbt.datediff('metric_date', '(select ref_date from ref_date)', 'day') }} as days_ago,
        -- Exponential decay: weight = 2^(-days_ago / 7)
        pow(2, -{{ dbt.datediff('metric_date', '(select ref_date from ref_date)', 'day') }} / 7.0) as exponential_weight,
        -- Linear decay: weight = max(0, 1 - days_ago / 30)
        greatest(0, 1.0 - {{ dbt.datediff('metric_date', '(select ref_date from ref_date)', 'day') }} / 30.0) as linear_weight,
        -- Position tracking for position-based model
        row_number() over (partition by campaign_id order by metric_date asc) as touchpoint_position,
        count(*) over (partition by campaign_id) as total_touchpoints
    from source
)

select * from with_decay
EOF

# Create staging model for channels with fallback
cat > attribution_project/models/staging/stg_campaign_channels.sql << 'EOF'
{{ config(materialized='view') }}

/*
    Campaign channel mapping with fallback to campaign_type.
*/

with channels as (
    select
        trim(CAMPAIGN_ID) as campaign_id,
        trim(CHANNEL_TYPE) as channel_type
    from {{ source('marketing', 'CAMPAIGN_CHANNELS') }}
),

campaigns as (
    select
        trim(CAMPAIGN_ID) as campaign_id,
        trim(CAMPAIGN_TYPE) as campaign_type
    from {{ source('marketing', 'MARKETING_CAMPAIGNS') }}
),

-- Get distinct channels per campaign, with fallback
channel_mapping as (
    select distinct
        c.campaign_id,
        coalesce(ch.channel_type, c.campaign_type) as channel,
        count(distinct ch.channel_type) over (partition by c.campaign_id) as channel_count
    from campaigns c
    left join channels ch on c.campaign_id = ch.campaign_id
)

select
    campaign_id,
    channel,
    case when channel_count = 0 then 1 else channel_count end as channel_count
from channel_mapping
EOF

# Create staging model for orders (customer journeys)
cat > attribution_project/models/staging/stg_orders_journeys.sql << 'EOF'
{{ config(materialized='view') }}

/*
    Staging for customer journey analysis from orders.
*/

with ref_date as (
    select max(cast(ORDERED_AT as date)) as ref_date
    from {{ source('orders', 'ORDERS') }}
),

orders as (
    select
        trim(ORDER_ID) as order_id,
        trim(CUSTOMER_ID) as customer_id,
        trim(CHANNEL_ID) as channel_id,
        cast(ORDERED_AT as timestamp) as ordered_at,
        cast(GRAND_TOTAL as decimal(18,2)) as grand_total
    from {{ source('orders', 'ORDERS') }}
    where ORDERED_AT >= {{ dbt.dateadd('day', -30, '(select ref_date from ref_date)') }}
      and ORDERED_AT <= (select ref_date from ref_date)
      and (TEST_ORDER_FLAG IS NULL OR UPPER(CAST(TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      and CUSTOMER_ID is not null
),

with_journey_position as (
    select
        order_id,
        customer_id,
        channel_id,
        ordered_at,
        grand_total,
        row_number() over (partition by customer_id order by ordered_at asc) as journey_position,
        count(*) over (partition by customer_id) as journey_length
    from orders
)

select * from with_journey_position
EOF

# Create intermediate model for position-based weights
cat > attribution_project/models/intermediate/int_position_weights.sql << 'EOF'
{{ config(materialized='view') }}

/*
    Calculate position-based weights for campaign touchpoints.
    First: 40%, Last: 40%, Middle: split 20% equally
*/

with touchpoints as (
    select * from {{ ref('stg_campaign_performance') }}
),

with_position_weight as (
    select
        campaign_id,
        metric_date,
        revenue,
        conversions,
        days_ago,
        exponential_weight,
        linear_weight,
        touchpoint_position,
        total_touchpoints,
        case
            when total_touchpoints = 1 then 1.0
            when touchpoint_position = 1 then 0.4  -- First touch
            when touchpoint_position = total_touchpoints then 0.4  -- Last touch
            else 0.2 / greatest(1, total_touchpoints - 2)  -- Middle touches split 20%
        end as position_weight
    from touchpoints
)

select * from with_position_weight
EOF

# Create intermediate model for customer journey attribution
cat > attribution_project/models/intermediate/int_journey_attribution.sql << 'EOF'
{{ config(materialized='view') }}

/*
    Calculate position-based attribution for customer journeys.
*/

with journeys as (
    select * from {{ ref('stg_orders_journeys') }}
),

with_attribution as (
    select
        order_id,
        customer_id,
        channel_id,
        ordered_at,
        grand_total,
        journey_position,
        journey_length,
        case
            when journey_length = 1 then grand_total  -- Single order: 100%
            when journey_position = 1 then grand_total * 0.4  -- First: 40%
            when journey_position = journey_length then grand_total * 0.4  -- Last: 40%
            else grand_total * 0.2 / greatest(1, journey_length - 2)  -- Middle: split 20%
        end as attributed_revenue,
        case
            when journey_position = 1 then TRUE else FALSE
        end as is_first_touch,
        case
            when journey_position = journey_length then TRUE else FALSE
        end as is_last_touch,
        case
            when journey_position > 1 and journey_position < journey_length then TRUE else FALSE
        end as is_middle_touch
    from journeys
)

select * from with_attribution
EOF

# Create mart: decay_model_comparison
cat > attribution_project/models/marts/decay_model_comparison.sql << 'EOF'
{{ config(materialized='table') }}

/*
    Compare three attribution models: Exponential, Linear, Position-based.
*/

with weighted_performance as (
    select * from {{ ref('int_position_weights') }}
),

channel_map as (
    select * from {{ ref('stg_campaign_channels') }}
),

campaign_aggregates as (
    select
        wp.campaign_id,
        -- Exponential model
        sum(wp.revenue * wp.exponential_weight) as exponential_revenue_raw,
        sum(wp.conversions * wp.exponential_weight) as exponential_conversions_raw,
        -- Linear model
        sum(wp.revenue * wp.linear_weight) as linear_revenue_raw,
        sum(wp.conversions * wp.linear_weight) as linear_conversions_raw,
        -- Position-based model
        sum(wp.revenue * wp.position_weight) as position_revenue_raw,
        sum(wp.conversions * wp.position_weight) as position_conversions_raw,
        -- Metadata
        count(*) as touchpoint_count,
        sum(wp.exponential_weight) as total_weight
    from weighted_performance wp
    group by wp.campaign_id
    having sum(wp.exponential_weight) > 0
),

with_channels as (
    select
        ca.campaign_id,
        cm.channel,
        cm.channel_count,
        ca.exponential_revenue_raw,
        ca.exponential_conversions_raw,
        ca.linear_revenue_raw,
        ca.linear_conversions_raw,
        ca.position_revenue_raw,
        ca.position_conversions_raw,
        ca.touchpoint_count,
        ca.total_weight
    from campaign_aggregates ca
    join channel_map cm on ca.campaign_id = cm.campaign_id
)

select
    campaign_id,
    channel,
    round(exponential_revenue_raw / channel_count, 2) as exponential_revenue,
    round(linear_revenue_raw / channel_count, 2) as linear_revenue,
    round(position_revenue_raw / channel_count, 2) as position_revenue,
    round(exponential_conversions_raw / channel_count, 2) as exponential_conversions,
    round(linear_conversions_raw / channel_count, 2) as linear_conversions,
    round(position_conversions_raw / channel_count, 2) as position_conversions,
    touchpoint_count,
    round(total_weight, 4) as total_weight
from with_channels
order by exponential_revenue desc, campaign_id asc
EOF

# Create mart: customer_journey_attribution
cat > attribution_project/models/marts/customer_journey_attribution.sql << 'EOF'
{{ config(materialized='table') }}

/*
    Customer journey attribution aggregated by channel.
*/

with journey_data as (
    select * from {{ ref('int_journey_attribution') }}
),

channel_map as (
    select distinct
        cc.CHANNEL_TYPE as channel_id,
        cc.CAMPAIGN_ID as campaign_id
    from {{ source('marketing', 'CAMPAIGN_CHANNELS') }} cc
),

-- Aggregate by channel
channel_attribution as (
    select
        coalesce(cm.campaign_id, 'UNKNOWN') as campaign_id,
        jd.channel_id as channel,
        round(sum(jd.attributed_revenue), 2) as journey_attributed_revenue,
        count(distinct jd.customer_id) as unique_customers,
        round(avg(jd.journey_length), 2) as avg_journey_length,
        round(sum(case when jd.is_first_touch then jd.attributed_revenue else 0 end), 2) as first_touch_revenue,
        round(sum(case when jd.is_last_touch then jd.attributed_revenue else 0 end), 2) as last_touch_revenue,
        round(sum(case when jd.is_middle_touch then jd.attributed_revenue else 0 end), 2) as middle_touch_revenue
    from journey_data jd
    left join channel_map cm on jd.channel_id = cm.channel_id
    group by coalesce(cm.campaign_id, 'UNKNOWN'), jd.channel_id
)

select * from channel_attribution
order by journey_attributed_revenue desc
EOF

# Create mart: channel_interaction_effects
cat > attribution_project/models/marts/channel_interaction_effects.sql << 'EOF'
{{ config(materialized='table') }}

/*
    Channel interaction analysis - identify synergistic channel pairs.
*/

with journey_data as (
    select * from {{ ref('int_journey_attribution') }}
),

-- Get customers who used multiple channels
customer_channels as (
    select
        customer_id,
        channel_id,
        sum(grand_total) as customer_revenue
    from journey_data
    group by customer_id, channel_id
),

-- Find channel pairs per customer
channel_pairs as (
    select
        cc1.channel_id as channel_a,
        cc2.channel_id as channel_b,
        cc1.customer_id,
        cc1.customer_revenue + cc2.customer_revenue as combined_revenue
    from customer_channels cc1
    join customer_channels cc2
        on cc1.customer_id = cc2.customer_id
        and cc1.channel_id < cc2.channel_id  -- Avoid duplicates
),

-- Aggregate by channel pair
pair_stats as (
    select
        channel_a,
        channel_b,
        count(distinct customer_id) as shared_customers,
        round(sum(combined_revenue), 2) as combined_revenue
    from channel_pairs
    group by channel_a, channel_b
    having count(distinct customer_id) >= 5  -- Minimum 5 shared customers
),

-- Calculate expected revenue (single channel only)
single_channel_revenue as (
    select
        channel_id,
        round(sum(customer_revenue), 2) as channel_only_revenue
    from (
        select
            cc.customer_id,
            cc.channel_id,
            cc.customer_revenue
        from customer_channels cc
        join (
            select customer_id
            from customer_channels
            group by customer_id
            having count(distinct channel_id) = 1
        ) single_cust on cc.customer_id = single_cust.customer_id
    ) single_channel_customers
    group by channel_id
),

-- Calculate lift
with_lift as (
    select
        ps.channel_a,
        ps.channel_b,
        ps.shared_customers,
        ps.combined_revenue,
        coalesce(sca.channel_only_revenue, 0) + coalesce(scb.channel_only_revenue, 0) as expected_revenue,
        case
            when coalesce(sca.channel_only_revenue, 0) + coalesce(scb.channel_only_revenue, 0) > 0
            then round(ps.combined_revenue / (coalesce(sca.channel_only_revenue, 0) + coalesce(scb.channel_only_revenue, 0)), 4)
            else 0
        end as interaction_lift
    from pair_stats ps
    left join single_channel_revenue sca on ps.channel_a = sca.channel_id
    left join single_channel_revenue scb on ps.channel_b = scb.channel_id
)

select
    channel_a,
    channel_b,
    shared_customers,
    combined_revenue,
    expected_revenue,
    interaction_lift,
    case when interaction_lift > 1.1 then TRUE else FALSE end as has_synergy
from with_lift
order by interaction_lift desc
EOF

# Create mart: attribution_confidence
cat > attribution_project/models/marts/attribution_confidence.sql << 'EOF'
{{ config(materialized='table') }}

/*
    Attribution confidence scoring based on sample size, recency, and model consistency.
*/

with decay_comparison as (
    select * from {{ ref('decay_model_comparison') }}
),

-- Calculate confidence factors
confidence_calc as (
    select
        campaign_id,
        channel,
        touchpoint_count,
        total_weight,
        exponential_revenue,
        linear_revenue,
        position_revenue,
        -- Sample size factor: sqrt(touchpoints / 100) capped at 1.0
        least(1.0, sqrt(touchpoint_count / 100.0)) as sample_factor,
        -- Recency factor: average exponential weight (higher = more recent data)
        total_weight / greatest(1, touchpoint_count) as recency_score,
        -- Consistency: 1 - (stddev / avg) of the three model revenues
        case
            when (exponential_revenue + linear_revenue + position_revenue) / 3.0 = 0 then 0
            else 1.0 - (
                sqrt(
                    (pow(exponential_revenue - (exponential_revenue + linear_revenue + position_revenue) / 3.0, 2) +
                     pow(linear_revenue - (exponential_revenue + linear_revenue + position_revenue) / 3.0, 2) +
                     pow(position_revenue - (exponential_revenue + linear_revenue + position_revenue) / 3.0, 2)) / 3.0
                ) / ((exponential_revenue + linear_revenue + position_revenue) / 3.0)
            )
        end as consistency_score
    from decay_comparison
)

select
    campaign_id,
    channel,
    round(sample_factor, 4) as sample_factor,
    round(recency_score, 4) as recency_score,
    round(greatest(0, consistency_score), 4) as consistency_score,
    round((sample_factor * 0.3 + recency_score * 0.3 + greatest(0, consistency_score) * 0.4) * 100, 2) as confidence_score
from confidence_calc
order by confidence_score desc, campaign_id asc
EOF

cd attribution_project
dbt run


# Snowflake note: Tests use lower(table_schema) with 'attribution_analytics' schema
# and query FROM attribution_analytics.<table> - both work naturally with Snowflake's
# uppercase storage. No lowercase views needed.

echo "Solution complete!"
