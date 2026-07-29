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



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
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

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps

cat > macros/data_quality/add_dq_flags.sql <<'SQL'
{% macro add_dq_flags(required_columns=[]) %}
    -- Data Quality Flags
    CASE
        WHEN {% for col in required_columns %}{{ col }} IS NULL OR TRIM(CAST({{ col }} AS VARCHAR)) = ''{% if not loop.last %} OR {% endif %}{% endfor %}
        THEN FALSE
        ELSE TRUE
    END AS dq_is_valid,

    CASE
        WHEN {% for col in required_columns %}{{ col }} IS NULL OR TRIM(CAST({{ col }} AS VARCHAR)) = ''{% if not loop.last %} OR {% endif %}{% endfor %}
        THEN TRUE
        ELSE FALSE
    END AS dq_missing_required,

    FALSE AS dq_format_corrected,
    FALSE AS dq_duplicate_suspected,
    FALSE AS dq_late_arriving
{% endmacro %}
SQL

python - <<'PY'
from pathlib import Path

path = Path("macros/data_quality/dq_checks.sql")
text = path.read_text()

# Replace regex function with conditional logic for cross-database compatibility
# Find and replace REGEXP_LIKE/REGEXP_MATCHES with conditional macro
text = text.replace("REGEXP_LIKE", "{% if target.type == 'duckdb' %}REGEXP_MATCHES{% else %}REGEXP_LIKE{% endif %}")
text = text.replace("regexp_like", "{% if target.type == 'duckdb' %}regexp_matches{% else %}regexp_like{% endif %}")

# Replace dq_flag_iqr_outlier macro with cross-database conditional version
macro_start = text.find("{% macro dq_flag_iqr_outlier")
if macro_start != -1:
    macro_end = text.find("{% endmacro %}", macro_start)
    if macro_end != -1:
        macro_end += len("{% endmacro %}")
        new_macro = """{% macro dq_flag_iqr_outlier(value_col, partition_cols=none, multiplier=1.5) %}
{% set partition_clause = 'PARTITION BY ' ~ partition_cols | join(', ') if partition_cols else '' %}
{% if target.type == 'duckdb' %}
    CASE
        WHEN {{ value_col }} < (
            quantile_cont({{ value_col }}, 0.25) OVER ({{ partition_clause }})
            - {{ multiplier }} * (
                quantile_cont({{ value_col }}, 0.75) OVER ({{ partition_clause }})
                - quantile_cont({{ value_col }}, 0.25) OVER ({{ partition_clause }})
            )
        ) THEN 'LOW_OUTLIER'
        WHEN {{ value_col }} > (
            quantile_cont({{ value_col }}, 0.75) OVER ({{ partition_clause }})
            + {{ multiplier }} * (
                quantile_cont({{ value_col }}, 0.75) OVER ({{ partition_clause }})
                - quantile_cont({{ value_col }}, 0.25) OVER ({{ partition_clause }})
            )
        ) THEN 'HIGH_OUTLIER'
        ELSE NULL
    END
{% else %}
    CASE
        WHEN {{ value_col }} < (
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            - {{ multiplier }} * (
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
                - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            )
        ) THEN 'LOW_OUTLIER'
        WHEN {{ value_col }} > (
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            + {{ multiplier }} * (
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
                - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            )
        ) THEN 'HIGH_OUTLIER'
        ELSE NULL
    END
{% endif %}
{% endmacro %}"""
        text = text[:macro_start] + new_macro + text[macro_end:]

path.write_text(text)
PY

cat > models/marts/sales/fct_order_line_detail.sql <<'SQL'
-- Sales Order Line Detail
-- Detailed order line analysis

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
),

joined as (
    select
        ol.order_line_id,
        o.order_id,
        o.order_number,
        coalesce(nullif(trim(pv.sku), ''), nullif(trim(ol.sku), '')) as sku,
        case
            when nullif(trim(pv.sku), '') is null and nullif(trim(ol.sku), '') is not null then true
            else false
        end as sku_fallback,
        pv.variant_name,
        coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), '')) as product_name,
        case
            when nullif(trim(p.product_name), '') is null and nullif(trim(ol.product_name), '') is not null then true
            else false
        end as product_name_fallback,
        case
            when pc.category_path is not null and trim(pc.category_path) != ''
                then trim({% if target.type == 'duckdb' %}regexp_extract(pc.category_path, '([^>]+)$', 1){% else %}REGEXP_SUBSTR(pc.category_path, '[^>]+$'){% endif %})
            when pc.category_name is not null and trim(pc.category_name) != ''
                then trim(pc.category_name)
            else coalesce(nullif(trim(p.product_name), ''), nullif(trim(ol.product_name), ''))
        end as product_category_leaf,
        p.primary_category_id,
        pc.category_id as category_id,
        pc.category_name as category_name,
        ol.unit_price,
        ol.discount_amount,
        ol.tax_amount,
        ol.line_total as line_total_raw,
        ol.quantity_ordered,
        ol.quantity_shipped,
        ol.quantity_returned,
        ol.product_id,
        pv.cost_price,
        ol.status as line_status,
        {% if target.type == 'snowflake' %}TRY_TO_TIMESTAMP(ol.created_at){% else %}ol.created_at{% endif %} as line_created_at,
        {% if target.type == 'snowflake' %}TRY_TO_TIMESTAMP(ol.updated_at){% else %}ol.updated_at{% endif %} as line_updated_at,
        {% if target.type == 'snowflake' %}TRY_TO_TIMESTAMP(o.ordered_at){% else %}o.ordered_at{% endif %} as order_ordered_at,
        o.grand_total,
        o.notes,
        o.analyst_notes
    from order_lines ol
    left join orders o on ol.order_id = o.order_id
    left join product_variants pv on ol.variant_id = pv.variant_id
    left join products p on pv.product_id = p.product_id
    left join product_categories pc on p.primary_category_id = pc.category_id
),

calculated as (
    select
        *,
        (quantity_ordered * unit_price - discount_amount + tax_amount) as calc_line_total,
        case
            when abs((quantity_ordered * unit_price - discount_amount + tax_amount) - line_total_raw) > 0.01 then true
            else false
        end as line_total_corrected,
        round((quantity_ordered * unit_price - discount_amount + tax_amount) / nullif(quantity_ordered, 0), 2) as net_unit_price,
        case
            when abs(round((quantity_ordered * unit_price - discount_amount + tax_amount) / nullif(quantity_ordered, 0), 2) - unit_price) > 0.01 then true
            else false
        end as unit_price_net_corrected,
        (quantity_ordered * unit_price - discount_amount + tax_amount)
            - quantity_ordered * coalesce(cost_price, 0) as line_profit,
        discount_amount / nullif(unit_price * quantity_ordered, 0) as discount_rate,
        case
            when line_status in ('CREDIT','RETURNED')
                then abs(quantity_ordered * unit_price - discount_amount + tax_amount)
            else (quantity_ordered * unit_price - discount_amount + tax_amount)
        end as normalized_amount,
        case
            when line_status in ('CREDIT','RETURNED') then abs(quantity_ordered)
            else quantity_ordered
        end as normalized_qty,
        case
            when line_status = 'CREDIT' then 0
            else (quantity_ordered * unit_price - discount_amount + tax_amount)
        end as adjusted_line_total,
        case
            when line_status in ('CREDIT','RETURNED') then null
            else round((quantity_ordered * unit_price - discount_amount + tax_amount) / nullif(quantity_ordered, 0), 2)
        end as net_unit_price_for_iqr
    from joined
),

dq_stage as (
    select
        *,
        {{ add_dq_flags(required_columns=[
            'order_line_id',
            'order_id',
            'order_number',
            'sku',
            'product_name',
            'product_category_leaf',
            'quantity_ordered',
            'unit_price',
            'calc_line_total',
            'net_unit_price'
        ]) }},
        {{ dq_flag_revenue_anomaly('normalized_amount', 'order_ordered_at') }} as dq_revenue_flag,
        {{ dq_flag_quantity_anomaly('normalized_qty') }} as dq_quantity_flag,
        {{ dq_flag_potential_duplicate(
            partition_cols=['order_id', 'product_id'],
            order_col='line_updated_at'
        ) }} as dq_duplicate_flag,
        {{ dq_check_shipped_vs_ordered('quantity_shipped', 'quantity_ordered', tolerance_pct=5) }} as dq_shipped_vs_ordered_valid,
        {{ dq_check_shipped_vs_ordered('quantity_returned', 'quantity_shipped', tolerance_pct=0) }} as dq_return_vs_shipped_valid_raw,
        {{ dq_flag_iqr_outlier('net_unit_price_for_iqr', partition_cols=['product_id'], multiplier=1.5) }} as dq_unit_price_iqr_flag,
        {{ dq_check_order_total_matches_lines('grand_total', 'adjusted_line_total', 'order_id', tolerance=0.01) }} as dq_order_total_match,
        {{ dq_flag_potential_pii('coalesce(notes, analyst_notes)') }} as dq_pii_flag,
        {{ dq_check_range('calc_line_total', min_val=0, allow_null=true) }} as dq_line_total_nonnegative_raw,
        {{ dq_check_date_sequence(['order_ordered_at', 'line_created_at', 'line_updated_at']) }} as dq_line_dates_valid,
        case
            when primary_category_id is null then true
            when category_id is null then true
            when category_name is null or trim(category_name) = '' then true
            else false
        end as dq_category_missing,
        case
            when line_status in ('CREDIT','RETURNED') then null
            when discount_rate is null then null
            when discount_rate < 0 then 'NEGATIVE_DISCOUNT'
            when discount_rate > 1 then 'DISCOUNT_EXCEEDS_PRICE'
            when discount_rate > 0.70 then 'HIGH_DISCOUNT'
            else null
        end as dq_discount_rate_flag,
        case
            when line_status in ('CREDIT','RETURNED') then null
            when calc_line_total = 0 then 'ZERO_REVENUE'
            when line_profit < 0 then 'NEGATIVE_MARGIN'
            when line_profit / nullif(calc_line_total, 0) > 0.80 then 'EXCESS_MARGIN'
            else null
        end as dq_margin_flag
    from calculated
),

final_flags as (
    select
        order_line_id,
        order_id,
        order_number,
        sku,
        variant_name,
        product_name,
        product_category_leaf,
        unit_price,
        discount_amount,
        calc_line_total as line_total,
        line_profit,
        line_total_corrected,
        net_unit_price,
        unit_price_net_corrected,
        dq_missing_required,
        case
            when line_total_corrected or unit_price_net_corrected or sku_fallback or product_name_fallback then true
            else false
        end as dq_format_corrected,
        case when dq_duplicate_flag is not null then true else false end as dq_duplicate_suspected,
        case
            when line_status in ('CREDIT','RETURNED') then false
            when line_updated_at is null or order_ordered_at is null then false
            when line_updated_at > order_ordered_at + interval '2 days' then true
            else false
        end as dq_late_arriving,
        dq_revenue_flag,
        dq_quantity_flag,
        dq_duplicate_flag,
        dq_shipped_vs_ordered_valid,
        case
            when line_status = 'RETURNED' then dq_return_vs_shipped_valid_raw
            else true
        end as dq_return_vs_shipped_valid,
        case
            when line_status = 'PENDING' then (coalesce(quantity_shipped, 0) = 0 and coalesce(quantity_returned, 0) = 0)
            when line_status = 'SHIPPED' then quantity_shipped > 0
            when line_status = 'RETURNED' then quantity_returned > 0
            when line_status = 'CREDIT' then quantity_ordered < 0 and calc_line_total < 0
            else true
        end as dq_status_qty_valid,
        dq_unit_price_iqr_flag,
        dq_order_total_match,
        dq_pii_flag,
        case when line_status = 'CREDIT' then true else dq_line_total_nonnegative_raw end as dq_line_total_nonnegative,
        dq_discount_rate_flag,
        dq_margin_flag,
        dq_line_dates_valid,
        dq_category_missing
    from dq_stage
)

select
    order_line_id,
    order_id,
    order_number,
    sku,
    variant_name,
    product_name,
    product_category_leaf,
    unit_price,
    discount_amount,
    line_total,
    line_profit,
    line_total_corrected,
    net_unit_price,
    unit_price_net_corrected,
    case
        when dq_missing_required = true then false
        when dq_line_total_nonnegative = false then false
        when dq_shipped_vs_ordered_valid = false then false
        when dq_return_vs_shipped_valid = false then false
        when dq_status_qty_valid = false then false
        when dq_order_total_match = false then false
        when dq_line_dates_valid = false then false
        when dq_category_missing = true then false
        when dq_revenue_flag is not null then false
        when dq_quantity_flag is not null then false
        when dq_unit_price_iqr_flag is not null then false
        when dq_pii_flag is not null then false
        when dq_discount_rate_flag is not null then false
        when dq_margin_flag is not null then false
        when dq_duplicate_suspected = true then false
        else true
    end as dq_is_valid,
    dq_missing_required,
    dq_format_corrected,
    dq_duplicate_suspected,
    dq_late_arriving,
    dq_revenue_flag,
    dq_quantity_flag,
    dq_duplicate_flag,
    dq_shipped_vs_ordered_valid,
    dq_return_vs_shipped_valid,
    dq_status_qty_valid,
    dq_unit_price_iqr_flag,
    dq_order_total_match,
    dq_pii_flag,
    dq_line_total_nonnegative,
    dq_discount_rate_flag,
    dq_margin_flag,
    dq_line_dates_valid,
    dq_category_missing
from final_flags
SQL

# Run the model

dbt run --select fct_order_line_detail


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% do run_query('USE DATABASE "' ~ db ~ '"') %}
  {% do run_query('CREATE SCHEMA IF NOT EXISTS "' ~ db ~ '"."main"') %}
  {% set tables = [
    'fct_order_line_detail'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
