#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create schemas using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating schemas using admin role..."
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

# dbt generate_schema_name in dev target produces: main_staging, main_marts
# We also need lowercase "main" for the test verifier views
schemas_to_create = ['"main"', 'MAIN_STAGING', 'MAIN_MARTS']

try:
    for schema in schemas_to_create:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL VIEWS IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        print(f"Successfully pre-created schema {schema} in {db}")
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
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
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

# Install dbt package dependencies
dbt deps

mkdir -p models/marts

cat > models/marts/three_way_match.sql << 'EOF'
/*
Three-Way Purchase Order Matching Model with Risk Scoring

This model implements three-way matching between:
1. Purchase Order lines (what was ordered)
2. Receipt lines (what was received)
3. Supplier Invoice lines (what was billed)

It calculates variances, applies tolerance rules, computes risk scores,
and recommends actions.
*/

with po_lines as (
    -- Get PO line details with PO header info
    select
        pol.po_line_id,
        pol.po_id,
        po.po_number,
        po.supplier_id,
        pol.variant_id,
        pol.sku,
        pol.quantity_ordered as po_quantity,
        pol.unit_price as po_unit_price,
        pol.line_total as po_line_total,
        po.ordered_at
    from {{ ref('stg_procurement__purchase_order_lines') }} pol
    inner join {{ ref('stg_procurement__purchase_orders') }} po
        on pol.po_id = po.po_id
),

suppliers as (
    -- Get supplier names and ratings
    select
        supplier_id,
        supplier_name,
        rating as supplier_rating
    from {{ ref('stg_procurement__suppliers') }}
),

receipt_aggregates as (
    -- Aggregate receipts per PO line with counts
    select
        prl.po_line_id,
        sum(coalesce(prl.quantity_received, 0)) as receipt_quantity,
        sum(coalesce(prl.quantity_accepted, 0)) as accepted_quantity,
        sum(coalesce(prl.quantity_rejected, 0)) as rejected_quantity,
        min(por.received_at) as first_receipt_date,
        count(distinct por.receipt_id) as receipt_count
    from {{ ref('stg_procurement__purchase_order_receipt_lines') }} prl
    inner join {{ ref('stg_procurement__purchase_order_receipts') }} por
        on prl.receipt_id = por.receipt_id
    group by prl.po_line_id
),

invoice_aggregates as (
    -- Aggregate invoice lines per PO line with counts
    select
        sil.po_line_id,
        sum(coalesce(sil.quantity, 0)) as invoice_quantity,
        sum(coalesce(sil.line_total, 0)) as invoice_line_total,
        -- Weighted average price
        case
            when sum(coalesce(sil.quantity, 0)) > 0
            then sum(coalesce(sil.line_total, 0)) / sum(coalesce(sil.quantity, 0))
            else null
        end as invoice_unit_price,
        min(si.invoice_date) as invoice_date,
        count(distinct si.invoice_id) as invoice_count
    from {{ ref('stg_procurement__supplier_invoice_lines') }} sil
    inner join {{ ref('stg_procurement__supplier_invoices') }} si
        on sil.invoice_id = si.invoice_id
    where sil.po_line_id is not null
    group by sil.po_line_id
),

matched_records as (
    -- Join all sources together
    select
        pol.po_line_id as match_id,
        pol.po_id,
        pol.po_number,
        pol.po_line_id,
        pol.supplier_id,
        s.supplier_name,
        s.supplier_rating,
        pol.variant_id,
        pol.sku,
        pol.po_quantity,
        pol.po_unit_price,
        pol.po_line_total,
        coalesce(ra.receipt_quantity, 0) as receipt_quantity,
        coalesce(ra.accepted_quantity, 0) as accepted_quantity,
        coalesce(ra.rejected_quantity, 0) as rejected_quantity,
        coalesce(ra.receipt_count, 0) as receipt_count,
        ia.invoice_quantity,
        ia.invoice_unit_price,
        ia.invoice_line_total,
        ia.invoice_count,
        pol.ordered_at,
        ra.first_receipt_date,
        ia.invoice_date
    from po_lines pol
    left join suppliers s on pol.supplier_id = s.supplier_id
    left join receipt_aggregates ra on pol.po_line_id = ra.po_line_id
    inner join invoice_aggregates ia on pol.po_line_id = ia.po_line_id
),

variance_calculations as (
    -- Calculate all variances
    select
        *,
        -- Rejection rate
        case
            when receipt_quantity > 0
            then round(cast(rejected_quantity as double precision) / cast(receipt_quantity as double precision) * 100, 2)
            else 0
        end as rejection_rate,
        -- Quantity variance
        invoice_quantity - accepted_quantity as quantity_variance,
        -- Quantity variance percentage
        case
            when accepted_quantity > 0
            then round(cast(invoice_quantity - accepted_quantity as double precision) / cast(accepted_quantity as double precision) * 100, 2)
            else null
        end as quantity_variance_pct,
        -- Price variance
        invoice_unit_price - po_unit_price as price_variance,
        -- Price variance percentage
        case
            when po_unit_price > 0
            then round(cast(invoice_unit_price - po_unit_price as double precision) / cast(po_unit_price as double precision) * 100, 2)
            else null
        end as price_variance_pct,
        -- Total variance
        invoice_line_total - (accepted_quantity * po_unit_price) as total_variance,
        -- Expected amount
        accepted_quantity * po_unit_price as expected_amount,
        -- Days calculations
        {% if target.type == 'snowflake' %}
        case
            when invoice_date is not null and ordered_at is not null
            then datediff(day, cast(ordered_at as date), cast(invoice_date as date))
            else null
        end as days_to_invoice,
        case
            when invoice_date is not null and first_receipt_date is not null
            then datediff(day, cast(first_receipt_date as date), cast(invoice_date as date))
            else null
        end as days_receipt_to_invoice
        {% else %}
        case
            when invoice_date is not null and ordered_at is not null
            then cast(invoice_date - cast(ordered_at as date) as integer)
            else null
        end as days_to_invoice,
        case
            when invoice_date is not null and first_receipt_date is not null
            then cast(invoice_date - cast(first_receipt_date as date) as integer)
            else null
        end as days_receipt_to_invoice
        {% endif %}
    from matched_records
),

status_determination as (
    -- Determine match statuses
    select
        *,
        -- Quantity match status (follow precedence order from instructions)
        case
            -- Priority 1: NO_RECEIPT
            when receipt_quantity = 0 or receipt_quantity is null then 'NO_RECEIPT'
            -- Priority 2: EXACT_MATCH
            when invoice_quantity = accepted_quantity then 'EXACT_MATCH'
            -- Priority 3: WITHIN_TOLERANCE
            when abs(quantity_variance_pct) <= 2.0
                 and abs(invoice_quantity - accepted_quantity) <= 5.0 then 'WITHIN_TOLERANCE'
            -- Priority 4: OVER_BILLED
            when invoice_quantity > accepted_quantity then 'OVER_BILLED'
            -- Priority 5: UNDER_BILLED
            when invoice_quantity < accepted_quantity then 'UNDER_BILLED'
            -- Priority 6: PARTIAL_RECEIPT (checked last)
            when receipt_quantity < po_quantity then 'PARTIAL_RECEIPT'
            else 'UNDER_BILLED'
        end as quantity_match_status,
        -- Price match status (follow precedence order from instructions)
        case
            -- Priority 1: NO_PO_PRICE
            when po_unit_price is null or po_unit_price = 0 then 'NO_PO_PRICE'
            -- Priority 2: EXACT_MATCH
            when invoice_unit_price = po_unit_price then 'EXACT_MATCH'
            -- Priority 3: WITHIN_TOLERANCE
            when abs(price_variance_pct) <= 1.0
                 and abs(invoice_unit_price - po_unit_price) <= 0.50 then 'WITHIN_TOLERANCE'
            -- Priority 4: PRICE_INCREASE
            when invoice_unit_price > po_unit_price then 'PRICE_INCREASE'
            -- Priority 5: PRICE_DECREASE
            when invoice_unit_price < po_unit_price then 'PRICE_DECREASE'
            else 'PRICE_INCREASE'
        end as price_match_status
    from variance_calculations
),

risk_score_calculation as (
    -- Calculate risk score components
    select
        *,
        -- Quantity variance component (0-25 points)
        case
            when abs(coalesce(quantity_variance_pct, 0)) <= 2 then 0
            when abs(quantity_variance_pct) <= 5 then 5
            when abs(quantity_variance_pct) <= 10 then 15
            else 25
        end as risk_qty_points,
        -- Price variance component (0-25 points)
        case
            when abs(coalesce(price_variance_pct, 0)) <= 1 then 0
            when abs(price_variance_pct) <= 3 then 5
            when abs(price_variance_pct) <= 5 then 15
            else 25
        end as risk_price_points,
        -- Dollar amount component (0-15 points)
        case
            when abs(coalesce(total_variance, 0)) < 100 then 0
            when abs(total_variance) < 500 then 5
            when abs(total_variance) < 1000 then 10
            else 15
        end as risk_amount_points,
        -- Supplier rating component (0-15 points)
        case
            when supplier_rating >= 4.0 then 0
            when supplier_rating >= 3.0 then 5
            when supplier_rating >= 2.0 then 10
            else 15  -- includes NULL ratings
        end as risk_supplier_points,
        -- Invoice timing component (0-10 points)
        case
            when coalesce(days_receipt_to_invoice, 0) <= 14 then 0
            when days_receipt_to_invoice <= 30 then 3
            when days_receipt_to_invoice <= 60 then 7
            else 10
        end as risk_timing_points,
        -- Rejection rate component (0-10 points)
        case
            when rejection_rate = 0 then 0
            when rejection_rate <= 10 then 3
            when rejection_rate <= 25 then 7
            else 10
        end as risk_reject_points
    from status_determination
),

risk_totals as (
    -- Calculate total risk score and category
    select
        *,
        (risk_qty_points + risk_price_points + risk_amount_points +
         risk_supplier_points + risk_timing_points + risk_reject_points) as risk_score
    from risk_score_calculation
),

risk_categorized as (
    select
        *,
        case
            when risk_score <= 24 then 'LOW'
            when risk_score <= 49 then 'MEDIUM'
            when risk_score <= 79 then 'HIGH'
            else 'CRITICAL'
        end as risk_category
    from risk_totals
),

overall_status as (
    -- Determine overall match status
    select
        *,
        case
            when quantity_match_status is null or price_match_status is null then 'UNMATCHED'
            -- BLOCKED conditions (check these before PENDING_RECEIPT)
            when price_variance_pct > 5.0 then 'BLOCKED'
            when quantity_variance_pct > 10.0 then 'BLOCKED'
            when invoice_line_total > 1000
                 and (quantity_match_status not in ('EXACT_MATCH', 'WITHIN_TOLERANCE')
                      or price_match_status not in ('EXACT_MATCH', 'WITHIN_TOLERANCE')) then 'BLOCKED'
            when risk_score >= 80 then 'BLOCKED'
            when rejection_rate > 25 then 'BLOCKED'
            -- PENDING_RECEIPT (only if not blocked)
            when receipt_quantity = 0 or receipt_quantity is null then 'PENDING_RECEIPT'
            -- APPROVED
            when quantity_match_status in ('EXACT_MATCH', 'WITHIN_TOLERANCE')
                 and price_match_status in ('EXACT_MATCH', 'WITHIN_TOLERANCE') then 'APPROVED'
            -- REVIEW_REQUIRED
            else 'REVIEW_REQUIRED'
        end as overall_match_status
    from risk_categorized
),

exception_building as (
    -- Build exception reasons (always compute, even for APPROVED records)
    select
        *,
        {% if target.type == 'snowflake' %}
        coalesce(
            nullif(
                ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
                    case when quantity_match_status = 'OVER_BILLED' then 'QTY_OVER' end,
                    case when quantity_match_status = 'UNDER_BILLED' then 'QTY_UNDER' end,
                    case when quantity_match_status = 'PARTIAL_RECEIPT' then 'QTY_PARTIAL' end,
                    case when quantity_match_status = 'NO_RECEIPT' then 'QTY_NONE' end,
                    case when price_match_status = 'PRICE_INCREASE' then 'PRC_HIGH' end,
                    case when price_match_status = 'PRICE_DECREASE' then 'PRC_LOW' end,
                    case when price_match_status = 'NO_PO_PRICE' then 'PRC_MISSING' end,
                    case when abs(total_variance) > 500 then 'AMT_LARGE' end,
                    case when days_receipt_to_invoice > 30 then 'TIMING_LATE' end,
                    case when rejection_rate > 10 then 'HIGH_REJECT' end,
                    case when invoice_count > 1 then 'MULTI_INVOICE' end,
                    case when supplier_rating < 3.0 or supplier_rating is null then 'LOW_SUPPLIER_RATING' end
                )), '|'),
                ''
            ),
            'NONE'
        ) as exception_reasons
        {% else %}
        coalesce(
            nullif(
                concat_ws('|',
                    case when quantity_match_status = 'OVER_BILLED' then 'QTY_OVER' end,
                    case when quantity_match_status = 'UNDER_BILLED' then 'QTY_UNDER' end,
                    case when quantity_match_status = 'PARTIAL_RECEIPT' then 'QTY_PARTIAL' end,
                    case when quantity_match_status = 'NO_RECEIPT' then 'QTY_NONE' end,
                    case when price_match_status = 'PRICE_INCREASE' then 'PRC_HIGH' end,
                    case when price_match_status = 'PRICE_DECREASE' then 'PRC_LOW' end,
                    case when price_match_status = 'NO_PO_PRICE' then 'PRC_MISSING' end,
                    case when abs(total_variance) > 500 then 'AMT_LARGE' end,
                    case when days_receipt_to_invoice > 30 then 'TIMING_LATE' end,
                    case when rejection_rate > 10 then 'HIGH_REJECT' end,
                    case when invoice_count > 1 then 'MULTI_INVOICE' end,
                    case when supplier_rating < 3.0 or supplier_rating is null then 'LOW_SUPPLIER_RATING' end
                ),
                ''
            ),
            'NONE'
        ) as exception_reasons
        {% endif %}
    from overall_status
),

exception_counts as (
    select
        *,
        case
            when exception_reasons = 'NONE' then 0
            else length(exception_reasons) - length(replace(exception_reasons, '|', '')) + 1
        end as exception_count
    from exception_building
),

final as (
    -- Determine recommended action
    select
        match_id,
        po_id,
        po_number,
        po_line_id,
        supplier_id,
        supplier_name,
        supplier_rating,
        variant_id,
        sku,
        po_quantity,
        po_unit_price,
        po_line_total,
        receipt_quantity,
        accepted_quantity,
        rejected_quantity,
        rejection_rate,
        invoice_quantity,
        invoice_unit_price,
        invoice_line_total,
        quantity_variance,
        quantity_variance_pct,
        price_variance,
        price_variance_pct,
        total_variance,
        expected_amount,
        quantity_match_status,
        price_match_status,
        overall_match_status,
        exception_reasons,
        exception_count,
        risk_score,
        risk_category,
        case
            -- Priority 1: PENDING_RECEIPT
            when overall_match_status = 'PENDING_RECEIPT' then 'WAIT_FOR_RECEIPT'
            -- Priority 2: CRITICAL risk
            when risk_category = 'CRITICAL' then 'ESCALATE_TO_MANAGEMENT'
            -- Priority 3: APPROVED
            when overall_match_status = 'APPROVED' then 'PAY_IMMEDIATELY'
            -- Priority 4: OVER_BILLED
            when quantity_match_status = 'OVER_BILLED' then 'REQUEST_CREDIT_MEMO'
            -- Priority 5: PRICE_INCREASE
            when price_match_status = 'PRICE_INCREASE' then 'CONTACT_SUPPLIER'
            -- Priority 6: BLOCKED
            when overall_match_status = 'BLOCKED' then 'HOLD_FOR_REVIEW'
            -- Priority 7: Minor adjustments
            when quantity_match_status in ('UNDER_BILLED', 'WITHIN_TOLERANCE')
                 or price_match_status in ('PRICE_DECREASE', 'WITHIN_TOLERANCE') then 'PAY_WITH_ADJUSTMENT'
            -- Default
            else 'HOLD_FOR_REVIEW'
        end as recommended_action,
        days_to_invoice,
        days_receipt_to_invoice,
        receipt_count,
        invoice_count
    from exception_counts
)

select * from final
EOF

dbt run --select +three_way_match

# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set tables = [
    'three_way_match'
  ] %}
  {% for t in tables %}
    {% set src_table = t | upper %}
    {% set sql %}
      CREATE OR REPLACE VIEW "main"."{{ t }}" AS SELECT * FROM MAIN_MARTS.{{ src_table }}
    {% endset %}
    {% do run_query(sql) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

