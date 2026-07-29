#!/bin/bash
# Solution script for Supplier Performance Scorecard task
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
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project
else
    DBT_PROJECT_DIR="/app/dbt_project"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # Create new dbt project
    mkdir -p "$DBT_PROJECT_DIR"
    cd "$DBT_PROJECT_DIR"

    cat > dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2

profile: 'dbt_project'

model-paths: ["models"]
macro-paths: ["macros"]

models:
  dbt_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: view
    marts:
      +materialized: table
EOF

    # DuckDB profile (write to project dir so DBT_PROFILES_DIR works)
    cat > "$DBT_PROJECT_DIR/profiles.yml" << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: supplier_analytics
EOF
    # Also write to ~/.dbt for fallback
    mkdir -p ~/.dbt
    cp "$DBT_PROJECT_DIR/profiles.yml" ~/.dbt/profiles.yml
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create directory structure
mkdir -p "$DBT_PROJECT_DIR/models/staging"
mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
mkdir -p "$DBT_PROJECT_DIR/models/marts"
mkdir -p "$DBT_PROJECT_DIR/macros"

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================================
    # SNOWFLAKE: Create staging models using base project source definitions.
    # The base project already has _sources.yml defining procurement source.
    # Create staging models in a subdirectory to avoid conflicts.
    # ============================================================

    mkdir -p "$DBT_PROJECT_DIR/models/staging/supplier_perf"

    # Use prefixed names to avoid conflicts with base project's stg_suppliers etc.
    STG_SUPPLIERS="stg_sp__suppliers"
    STG_PURCHASE_ORDERS="stg_sp__purchase_orders"
    STG_PURCHASE_ORDER_RECEIPTS="stg_sp__purchase_order_receipts"
    STG_PURCHASE_ORDER_RECEIPT_LINES="stg_sp__purchase_order_receipt_lines"
    STG_SUPPLIER_INVOICES="stg_sp__supplier_invoices"

    cat > "$DBT_PROJECT_DIR/models/staging/supplier_perf/stg_sp__suppliers.sql" << 'EOF'
{{ config(materialized='view') }}

select
    SUPPLIER_ID as supplier_id,
    SUPPLIER_CODE as supplier_code,
    SUPPLIER_NAME as supplier_name,
    SUPPLIER_TYPE as supplier_type,
    LEAD_TIME_DAYS as lead_time_days,
    STATUS as status
from {{ source('procurement', 'SUPPLIERS') }}
where STATUS = 'ACTIVE'
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/supplier_perf/stg_sp__purchase_orders.sql" << 'EOF'
{{ config(materialized='view') }}

select
    PO_ID as po_id,
    PO_NUMBER as po_number,
    SUPPLIER_ID as supplier_id,
    WAREHOUSE_ID as warehouse_id,
    STATUS as status,
    TOTAL_AMOUNT as total_amount,
    EXPECTED_DATE as expected_date,
    ORDERED_AT as ordered_at
from {{ source('procurement', 'PURCHASE_ORDERS') }}
where STATUS not in ('DRAFT', 'CANCELLED')
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/supplier_perf/stg_sp__purchase_order_receipts.sql" << 'EOF'
{{ config(materialized='view') }}

select
    RECEIPT_ID as receipt_id,
    RECEIPT_NUMBER as receipt_number,
    PO_ID as po_id,
    cast(RECEIVED_AT as date) as received_date,
    RECEIVED_AT as received_at,
    STATUS as status
from {{ source('procurement', 'PURCHASE_ORDER_RECEIPTS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/supplier_perf/stg_sp__purchase_order_receipt_lines.sql" << 'EOF'
{{ config(materialized='view') }}

select
    RECEIPT_LINE_ID as receipt_line_id,
    RECEIPT_ID as receipt_id,
    PO_LINE_ID as po_line_id,
    coalesce(QUANTITY_RECEIVED, 0) as quantity_received,
    coalesce(QUANTITY_ACCEPTED, 0) as quantity_accepted,
    coalesce(QUANTITY_REJECTED, 0) as quantity_rejected,
    REJECT_REASON as reject_reason
from {{ source('procurement', 'PURCHASE_ORDER_RECEIPT_LINES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/supplier_perf/stg_sp__supplier_invoices.sql" << 'EOF'
{{ config(materialized='view') }}

select
    INVOICE_ID as invoice_id,
    INVOICE_NUMBER as invoice_number,
    SUPPLIER_ID as supplier_id,
    PO_ID as po_id,
    INVOICE_DATE as invoice_date,
    TOTAL_AMOUNT as total_amount,
    STATUS as status
from {{ source('procurement', 'SUPPLIER_INVOICES') }}
where STATUS != 'DISPUTED'
EOF

else
    # ============================================================
    # DUCKDB: Create staging models and sources from scratch
    # ============================================================

    # Create sources.yml
    cat > "$DBT_PROJECT_DIR/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: procurement
    schema: PROCUREMENT
    tables:
      - name: SUPPLIERS
      - name: PURCHASE_ORDERS
      - name: PURCHASE_ORDER_RECEIPTS
      - name: PURCHASE_ORDER_RECEIPT_LINES
      - name: SUPPLIER_INVOICES
EOF

    # Create staging models
    cat > "$DBT_PROJECT_DIR/models/staging/stg_suppliers.sql" << 'EOF'
select
    SUPPLIER_ID as supplier_id,
    SUPPLIER_CODE as supplier_code,
    SUPPLIER_NAME as supplier_name,
    SUPPLIER_TYPE as supplier_type,
    LEAD_TIME_DAYS as lead_time_days,
    STATUS as status
from {{ source('procurement', 'SUPPLIERS') }}
where STATUS = 'ACTIVE'
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_purchase_orders.sql" << 'EOF'
select
    PO_ID as po_id,
    PO_NUMBER as po_number,
    SUPPLIER_ID as supplier_id,
    WAREHOUSE_ID as warehouse_id,
    STATUS as status,
    TOTAL_AMOUNT as total_amount,
    EXPECTED_DATE as expected_date,
    ORDERED_AT as ordered_at
from {{ source('procurement', 'PURCHASE_ORDERS') }}
where STATUS not in ('DRAFT', 'CANCELLED')
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_purchase_order_receipts.sql" << 'EOF'
select
    RECEIPT_ID as receipt_id,
    RECEIPT_NUMBER as receipt_number,
    PO_ID as po_id,
    cast(RECEIVED_AT as date) as received_date,
    RECEIVED_AT as received_at,
    STATUS as status
from {{ source('procurement', 'PURCHASE_ORDER_RECEIPTS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_purchase_order_receipt_lines.sql" << 'EOF'
select
    RECEIPT_LINE_ID as receipt_line_id,
    RECEIPT_ID as receipt_id,
    PO_LINE_ID as po_line_id,
    coalesce(QUANTITY_RECEIVED, 0) as quantity_received,
    coalesce(QUANTITY_ACCEPTED, 0) as quantity_accepted,
    coalesce(QUANTITY_REJECTED, 0) as quantity_rejected,
    REJECT_REASON as reject_reason
from {{ source('procurement', 'PURCHASE_ORDER_RECEIPT_LINES') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_supplier_invoices.sql" << 'EOF'
select
    INVOICE_ID as invoice_id,
    INVOICE_NUMBER as invoice_number,
    SUPPLIER_ID as supplier_id,
    PO_ID as po_id,
    INVOICE_DATE as invoice_date,
    TOTAL_AMOUNT as total_amount,
    STATUS as status
from {{ source('procurement', 'SUPPLIER_INVOICES') }}
where STATUS != 'DISPUTED'
EOF

    # DuckDB: use original (non-prefixed) staging model names
    STG_SUPPLIERS="stg_suppliers"
    STG_PURCHASE_ORDERS="stg_purchase_orders"
    STG_PURCHASE_ORDER_RECEIPTS="stg_purchase_order_receipts"
    STG_PURCHASE_ORDER_RECEIPT_LINES="stg_purchase_order_receipt_lines"
    STG_SUPPLIER_INVOICES="stg_supplier_invoices"

fi

# ============================================================
# SHARED: safe_divide macro
# ============================================================

cat > "$DBT_PROJECT_DIR/macros/safe_divide.sql" << 'EOF'
{% macro safe_divide(numerator, denominator, default=0) %}
    case
        when {{ denominator }} = 0 or {{ denominator }} is null
        then {{ default }}
        else cast({{ numerator }} as double) / cast({{ denominator }} as double)
    end
{% endmacro %}
EOF

# ============================================================
# SHARED: Intermediate models (cross-backend compatible SQL)
# ============================================================

cat > "$DBT_PROJECT_DIR/models/intermediate/int_po_delivery_performance.sql" << EOF
{{ config(materialized='view') }}

with po_first_receipt as (
    select
        r.po_id,
        min(r.received_date) as first_receipt_date
    from {{ ref('${STG_PURCHASE_ORDER_RECEIPTS}') }} r
    group by r.po_id
)

select
    po.po_id,
    po.supplier_id,
    po.expected_date,
    pfr.first_receipt_date,
    case
        when pfr.first_receipt_date <= po.expected_date then 0
        else DATEDIFF('day', cast(po.expected_date as date), cast(pfr.first_receipt_date as date))
    end as days_late,
    case
        when pfr.first_receipt_date <= po.expected_date then true
        else false
    end as is_on_time
from {{ ref('${STG_PURCHASE_ORDERS}') }} po
inner join po_first_receipt pfr on po.po_id = pfr.po_id
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_po_quality_performance.sql" << EOF
{{ config(materialized='view') }}

with receipt_line_totals as (
    select
        r.po_id,
        sum(rl.quantity_received) as total_quantity_received,
        sum(rl.quantity_accepted) as total_quantity_accepted,
        sum(rl.quantity_rejected) as total_quantity_rejected
    from {{ ref('${STG_PURCHASE_ORDER_RECEIPTS}') }} r
    inner join {{ ref('${STG_PURCHASE_ORDER_RECEIPT_LINES}') }} rl on r.receipt_id = rl.receipt_id
    group by r.po_id
)

select
    po.po_id,
    po.supplier_id,
    rlt.total_quantity_received,
    rlt.total_quantity_accepted,
    rlt.total_quantity_rejected,
    round({{ safe_divide('rlt.total_quantity_accepted', 'rlt.total_quantity_received', 0) }}, 4) as acceptance_rate,
    round({{ safe_divide('rlt.total_quantity_rejected', 'rlt.total_quantity_received', 0) }}, 4) as defect_rate
from {{ ref('${STG_PURCHASE_ORDERS}') }} po
inner join receipt_line_totals rlt on po.po_id = rlt.po_id
where rlt.total_quantity_received > 0
EOF

cat > "$DBT_PROJECT_DIR/models/intermediate/int_po_cost_performance.sql" << EOF
{{ config(materialized='view') }}

with po_invoices as (
    select
        po_id,
        sum(total_amount) as invoice_total
    from {{ ref('${STG_SUPPLIER_INVOICES}') }}
    group by po_id
)

select
    po.po_id,
    po.supplier_id,
    po.total_amount as po_total,
    inv.invoice_total,
    inv.invoice_total - po.total_amount as cost_variance,
    round({{ safe_divide('(inv.invoice_total - po.total_amount)', 'po.total_amount', 0) }}, 4) as cost_variance_pct
from {{ ref('${STG_PURCHASE_ORDERS}') }} po
inner join po_invoices inv on po.po_id = inv.po_id
where po.total_amount > 0
EOF

# ============================================================
# SHARED: Mart models (cross-backend compatible SQL)
# ============================================================

cat > "$DBT_PROJECT_DIR/models/marts/fct_supplier_metrics.sql" << EOF
{{ config(materialized='table') }}

with delivery_metrics as (
    select
        supplier_id,
        count(*) as total_pos,
        sum(case when is_on_time = true then 1 else 0 end) as on_time_pos,
        round({{ safe_divide('sum(case when is_on_time = true then 1 else 0 end)', 'count(*)', 0) }}, 4) as on_time_delivery_rate,
        round(coalesce(avg(case when is_on_time = false then cast(days_late as double) end), 0), 2) as avg_days_late
    from {{ ref('int_po_delivery_performance') }}
    group by supplier_id
),

quality_metrics as (
    select
        supplier_id,
        sum(total_quantity_received) as total_quantity_received,
        sum(total_quantity_accepted) as total_quantity_accepted,
        sum(total_quantity_rejected) as total_quantity_rejected,
        round({{ safe_divide('sum(total_quantity_accepted)', 'sum(total_quantity_received)', 0) }}, 4) as overall_acceptance_rate,
        round({{ safe_divide('sum(total_quantity_rejected)', 'sum(total_quantity_received)', 0) }}, 4) as overall_defect_rate
    from {{ ref('int_po_quality_performance') }}
    group by supplier_id
),

cost_metrics as (
    select
        supplier_id,
        sum(po_total) as total_po_value,
        sum(invoice_total) as total_invoice_value,
        sum(cost_variance) as overall_cost_variance,
        round({{ safe_divide('sum(cost_variance)', 'sum(po_total)', 0) }}, 4) as overall_cost_variance_pct
    from {{ ref('int_po_cost_performance') }}
    group by supplier_id
)

select
    s.supplier_id,
    s.supplier_code,
    s.supplier_name,
    s.supplier_type,
    coalesce(dm.total_pos, 0) as total_pos,
    coalesce(dm.on_time_pos, 0) as on_time_pos,
    coalesce(dm.on_time_delivery_rate, 0) as on_time_delivery_rate,
    coalesce(dm.avg_days_late, 0) as avg_days_late,
    coalesce(qm.total_quantity_received, 0) as total_quantity_received,
    coalesce(qm.total_quantity_accepted, 0) as total_quantity_accepted,
    coalesce(qm.total_quantity_rejected, 0) as total_quantity_rejected,
    coalesce(qm.overall_acceptance_rate, 0) as overall_acceptance_rate,
    coalesce(qm.overall_defect_rate, 0) as overall_defect_rate,
    coalesce(cm.total_po_value, 0) as total_po_value,
    coalesce(cm.total_invoice_value, 0) as total_invoice_value,
    coalesce(cm.overall_cost_variance, 0) as overall_cost_variance,
    coalesce(cm.overall_cost_variance_pct, 0) as overall_cost_variance_pct
from {{ ref('${STG_SUPPLIERS}') }} s
inner join delivery_metrics dm on s.supplier_id = dm.supplier_id
left join quality_metrics qm on s.supplier_id = qm.supplier_id
left join cost_metrics cm on s.supplier_id = cm.supplier_id
where dm.total_pos > 0
EOF

cat > "$DBT_PROJECT_DIR/models/marts/fct_supplier_scorecard.sql" << 'EOF'
{{ config(materialized='table') }}

with scored_suppliers as (
    select
        supplier_id,
        supplier_code,
        supplier_name,
        supplier_type,
        on_time_delivery_rate,
        -- On-Time Score (Weight: 40%)
        round(on_time_delivery_rate * 100, 2) as on_time_score,
        overall_acceptance_rate as acceptance_rate,
        -- Quality Score (Weight: 35%)
        round(overall_acceptance_rate * 100, 2) as quality_score,
        overall_cost_variance_pct as cost_variance_pct,
        -- Cost Score (Weight: 25%)
        round(
            case
                when overall_cost_variance_pct <= -0.05 then 100.0
                when overall_cost_variance_pct >= 0.10 then 0.0
                else greatest(0, least(100, 100.0 - ((overall_cost_variance_pct + 0.05) / 0.15) * 100.0))
            end
        , 2) as cost_score
    from {{ ref('fct_supplier_metrics') }}
)

select
    supplier_id,
    supplier_code,
    supplier_name,
    supplier_type,
    on_time_delivery_rate,
    on_time_score,
    acceptance_rate,
    quality_score,
    cost_variance_pct,
    cost_score,
    round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2) as composite_score,
    case
        when round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2) >= 90 then 'PLATINUM'
        when round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2) >= 75 then 'GOLD'
        when round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2) >= 60 then 'SILVER'
        when round((on_time_score * 0.40) + (quality_score * 0.35) + (cost_score * 0.25), 2) >= 40 then 'BRONZE'
        else 'AT_RISK'
    end as performance_tier
from scored_suppliers
EOF

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps || true

echo "Running dbt models..."
if [ "$DB_TYPE" = "snowflake" ]; then
    dbt run --select stg_sp__suppliers stg_sp__purchase_orders stg_sp__purchase_order_receipts stg_sp__purchase_order_receipt_lines stg_sp__supplier_invoices int_po_delivery_performance int_po_quality_performance int_po_cost_performance fct_supplier_metrics fct_supplier_scorecard
else
    dbt run
fi

echo "Solution complete!"
