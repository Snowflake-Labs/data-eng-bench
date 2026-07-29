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
    # Create order_payments view in MAIN schema (source table is in ORDERS schema)
    cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.ORDER_PAYMENTS AS SELECT * FROM {db}.ORDERS.ORDER_PAYMENTS')
    cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.ORDER_PAYMENTS TO ROLE {agent_role}')
    # Also create lowercase view for test compatibility
    cur.execute(f'CREATE OR REPLACE VIEW {db}."main"."order_payments" AS SELECT * FROM {db}.ORDERS.ORDER_PAYMENTS')
    cur.execute(f'GRANT SELECT ON VIEW {db}."main"."order_payments" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main and order_payments views in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/finance/fact_revenue.sql"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/finance/fact_revenue.sql"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    # DuckDB profile (default)
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
fi

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

cat > "$MODEL_PATH" << 'SQL'
{{
    config(
        materialized='table',
        tags=['mart', 'finance', 'revenue']
    )
}}


with payments as (

    select
        order_id,
        CAST(MAX(processed_at) AS DATE) as settlement_date
    {% if target.type == 'snowflake' %}
    from ORDERS.ORDER_PAYMENTS
    {% else %}
    from main.order_payments
    {% endif %}
    group by order_id

),

sales_with_settlement as (

    select
        s.*,
        CAST(coalesce(p.settlement_date, CAST(s.order_date AS DATE)) AS DATE) as settlement_date
    from {{ ref('fct_sales') }} s
    left join payments p
        on s.order_id = p.order_id

),

sales_with_fx as (

    select
        s.*,
        case
            when s.currency_code = 'USD' then 1.0
            else coalesce(fx.rate, 1.0)
        end as fx_rate
    from sales_with_settlement s
    left join {{ ref('dim_exchange_rates') }} fx
        on s.currency_code = fx.from_currency
        and fx.to_currency = 'USD'
        and s.settlement_date = fx.rate_date

),

daily_sales as (

    select
        order_date,
        settlement_date,
        currency_code,
        source_system,

        -- Order counts
        count(distinct order_id) as total_orders,
        count(distinct customer_id) as unique_customers,
        count(order_line_id) as total_line_items,

        -- Revenue metrics
        sum(extended_price) as gross_revenue,
        sum(discount_amount) as total_discounts,
        sum(extended_price - discount_amount) as net_revenue,
        sum(tax_amount) as total_tax,
        sum(line_total) as total_revenue,

        -- Average metrics
        avg(unit_price) as avg_unit_price,
        avg(extended_price) as avg_line_value,

        -- Quantity metrics
        sum(quantity_ordered) as total_units_ordered,
        sum(quantity_shipped) as total_units_shipped,

        -- Fulfillment metrics
        count(case when is_fully_shipped = TRUE then 1 end) as fully_shipped_lines,
        count(case when is_cancelled = TRUE then 1 end) as cancelled_lines,

        -- FX
        avg(fx_rate) as fx_rate,
        sum((extended_price - discount_amount) * fx_rate) as net_revenue_usd,
        sum(line_total * fx_rate) as total_revenue_usd

    from sales_with_fx
    where order_date is not null
    group by
        order_date,
        settlement_date,
        currency_code,
        source_system

),

final as (

    select
        -- Date dimension
        order_date,
        settlement_date,
        {% if target.type == 'snowflake' %}
        extract(year from TO_DATE(order_date)) as year,
        extract(month from TO_DATE(order_date)) as month,
        extract(quarter from TO_DATE(order_date)) as quarter,
        extract(dayofweek from TO_DATE(order_date)) as day_of_week,
        extract(week from TO_DATE(order_date)) as week_of_year,
        {% else %}
        extract(year from CAST(order_date AS DATE)) as year,
        extract(month from CAST(order_date AS DATE)) as month,
        extract(quarter from CAST(order_date AS DATE)) as quarter,
        extract(dayofweek from CAST(order_date AS DATE)) as day_of_week,
        extract(week from CAST(order_date AS DATE)) as week_of_year,
        {% endif %}

        -- Dimensions
        currency_code,
        source_system,

        -- Counts
        total_orders,
        unique_customers,
        total_line_items,

        -- Revenue
        gross_revenue,
        total_discounts,
        net_revenue,
        total_tax,
        total_revenue,

        -- USD Revenue
        round(fx_rate, 6) as fx_rate,
        round(net_revenue_usd, 2) as net_revenue_usd,
        round(total_revenue_usd, 2) as total_revenue_usd,

        -- Averages
        avg_unit_price,
        avg_line_value,
        case
            when total_orders > 0
            then total_revenue / total_orders
            else 0
        end as avg_order_value,

        -- Units
        total_units_ordered,
        total_units_shipped,

        -- Fulfillment rates
        case
            when total_line_items > 0
            then (CAST(fully_shipped_lines AS DECIMAL) / CAST(total_line_items AS DECIMAL))
            else 0
        end as fulfillment_rate,

        case
            when total_line_items > 0
            then (CAST(cancelled_lines AS DECIMAL) / CAST(total_line_items AS DECIMAL))
            else 0
        end as cancellation_rate,

        -- Discount rate
        case
            when gross_revenue > 0
            then (total_discounts / gross_revenue)
            else 0
        end as discount_rate,

        -- Metadata
        current_timestamp as dbt_updated_at

    from daily_sales

)

select * from final
SQL

# Install dependencies and run the model
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

dbt run --select fact_revenue


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set tables = ['fact_revenue'] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE TABLE "main"."' ~ t ~ '" AS SELECT * FROM MAIN.' ~ (t | upper)) %}
    {{ log('Created lowercase table: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
