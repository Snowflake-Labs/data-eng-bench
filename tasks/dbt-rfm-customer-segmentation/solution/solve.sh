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
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
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
    for schema in ['"main"', 'rfm_analytics']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        print(f"Successfully created schema {schema} in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

cd /app

# Create dbt project structure
mkdir -p dbt_project/{models/staging,models/intermediate,models/marts}

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > ~/.dbt/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: rfm_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > ~/.dbt/profiles.yml << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: rfm_analytics
EOF
    echo "Configured DuckDB profile"
fi

# Create dbt_project.yml
cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'

model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
EOF

# Create sources.yml for accessing existing tables
cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: main
    schema: "{{ 'ORDERS' if target.type == 'snowflake' else 'main' }}"
    tables:
      - name: orders
  - name: customer_data
    schema: "{{ 'CUSTOMER' if target.type == 'snowflake' else 'main' }}"
    tables:
      - name: customers
EOF

# Create staging model for orders
cat > dbt_project/models/staging/stg_orders__orders.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    ordered_at,
    grand_total,
    trim(status) as status
{% if target.type == 'snowflake' %}
from ORDERS.ORDERS
{% else %}
from {{ source('main', 'orders') }}
{% endif %}
where ordered_at >= '2023-01-01'
  and ordered_at < '2024-12-01'
EOF

# Create staging model for customers
cat > dbt_project/models/staging/stg_customer__customers.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(customer_id) as customer_id,
    trim(customer_number) as customer_number,
    trim(first_name) as first_name,
    trim(last_name) as last_name,
    trim(status) as status
{% if target.type == 'snowflake' %}
from CUSTOMER.CUSTOMERS
{% else %}
from {{ source('customer_data', 'customers') }}
{% endif %}
EOF

# Create intermediate RFM metrics model
# Use DATEDIFF syntax that works on both DuckDB and Snowflake
cat > dbt_project/models/intermediate/int_rfm_metrics.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Calculate RFM metrics per customer.
    - Recency: Days since last order (from analysis date 2024-12-01)
    - Frequency: Number of valid orders in analysis period
    - Monetary: Total spend in analysis period
*/

with valid_orders as (
    select
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('stg_orders__orders') }}
    where status not in ('CANCELLED', 'RETURNED', 'FAILED')
),

rfm_metrics as (
    select
        customer_id,
        -- Recency: days between analysis date and most recent order
        -- DATEDIFF syntax works on both DuckDB and Snowflake
        datediff('day', cast(max(ordered_at) as date), date '2024-12-01') as recency_days,
        -- Frequency: count of orders
        count(*) as frequency,
        -- Monetary: total spend (rounded to 2 decimal places)
        round(cast(sum(grand_total) as decimal(18,2)), 2) as monetary
    from valid_orders
    group by customer_id
)

select * from rfm_metrics
EOF

# Create RFM scores model
cat > dbt_project/models/marts/rfm_scores.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Assign RFM scores using NTILE(5).
    - Recency: Score 5 = most recent (lowest days), Score 1 = least recent
    - Frequency: Score 5 = most frequent, Score 1 = least frequent
    - Monetary: Score 5 = highest spend, Score 1 = lowest spend
*/

with rfm_metrics as (
    select * from {{ ref('int_rfm_metrics') }}
),

scored as (
    select
        customer_id,
        recency_days,
        frequency,
        monetary,
        -- Higher score = more recent (lower recency_days)
        -- Add customer_id as secondary sort for deterministic results
        ntile(5) over (order by recency_days desc, customer_id) as r_score,
        -- Higher score = more frequent
        ntile(5) over (order by frequency, customer_id) as f_score,
        -- Higher score = more monetary
        ntile(5) over (order by monetary, customer_id) as m_score
    from rfm_metrics
)

select * from scored
EOF

# Create final RFM segments model
# Use CONCAT for string concatenation (works on both DuckDB and Snowflake)
cat > dbt_project/models/marts/rfm_segments.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Final RFM segmentation model.
    Assigns customer segments based on RFM score combinations.

    Segment priority (first match wins):
    1. Champions
    2. Cannot Lose
    3. Loyal Customers
    4. At Risk
    5. Potential Loyalists
    6. Recent Customers
    7. Promising
    8. Need Attention
    9. About to Sleep
    10. Hibernating
    11. Lost
    12. Other
*/

with scores as (
    select * from {{ ref('rfm_scores') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

with_customer_info as (
    select
        s.customer_id,
        concat(coalesce(c.first_name, ''), ' ', coalesce(c.last_name, '')) as customer_name,
        s.recency_days,
        s.frequency,
        s.monetary,
        s.r_score,
        s.f_score,
        s.m_score,
        concat(cast(s.r_score as varchar), cast(s.f_score as varchar), cast(s.m_score as varchar)) as rfm_score
    from scores s
    left join customers c on s.customer_id = c.customer_id
),

with_segments as (
    select
        customer_id,
        customer_name,
        recency_days,
        frequency,
        monetary,
        r_score,
        f_score,
        m_score,
        rfm_score,
        case
            -- 1. Champions: High on all dimensions
            when r_score >= 4 and f_score >= 4 and m_score >= 4 then 'Champions'

            -- 2. Cannot Lose: Low recency but high frequency and monetary
            when r_score <= 2 and f_score >= 4 and m_score >= 4 then 'Cannot Lose'

            -- 3. Loyal Customers: High frequency and decent monetary
            when f_score >= 4 and m_score >= 3 then 'Loyal Customers'

            -- 4. At Risk: Low recency but decent frequency and monetary
            when r_score <= 2 and f_score >= 3 and m_score >= 3 then 'At Risk'

            -- 5. Potential Loyalists: Recent with moderate frequency
            when r_score >= 4 and f_score >= 2 and f_score <= 4 then 'Potential Loyalists'

            -- 6. Recent Customers: Very recent but low frequency
            when r_score >= 4 and f_score = 1 then 'Recent Customers'

            -- 7. Promising: Somewhat recent, low frequency, decent monetary
            when r_score >= 3 and f_score <= 2 and m_score >= 2 then 'Promising'

            -- 8. Need Attention: Middle ground on recency and frequency
            when r_score >= 2 and r_score <= 3 and f_score >= 2 and f_score <= 3 then 'Need Attention'

            -- 9. About to Sleep: Recency=2 with low frequency
            when r_score = 2 and f_score <= 2 then 'About to Sleep'

            -- 10. Hibernating: Low on all dimensions
            when r_score <= 2 and f_score <= 2 and m_score <= 2 then 'Hibernating'

            -- 11. Lost: Worst on recency and frequency
            when r_score = 1 and f_score = 1 then 'Lost'

            -- 12. Other: All remaining combinations
            else 'Other'
        end as rfm_segment
    from with_customer_info
)

select * from with_segments
order by customer_id
EOF

cd dbt_project
dbt run


# Snowflake note: Tests use lower(table_schema) and unquoted schema references,
# which work naturally with Snowflake's uppercase storage. No lowercase views needed.

echo "Solution complete!"
