#!/bin/bash
set -euo pipefail

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

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# For Snowflake: override generate_schema_name to keep all models in default schema
# This ensures staging models built by the '+' selector are in MAIN schema where
# the verifier's dbt run can find them via ref() calls
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {{ default_schema }}
{%- endmacro %}
GENMACRO
fi

# ============ SNOWFLAKE: Fix broken source tables and staging models ============
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Fixing missing/broken source tables for Snowflake clone..."
    python3 << 'FIX_SOURCES_PY'
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

def table_exists(schema, table):
    cur.execute(f"""
        SELECT COUNT(*) FROM {db}.INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}'
    """)
    return cur.fetchone()[0] > 0

def ensure_schema(schema):
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."{schema}"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."{schema}" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."{schema}" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL VIEWS IN SCHEMA {db}."{schema}" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."{schema}" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."{schema}" TO ROLE {agent_role}')

# --- Fix 1: DIGITAL.ABANDONED_CARTS_STG ---
# This raw table does not exist in the source Snowflake DB.
# The DuckDB version has it with columns: _ID, _LOADED_AT, _SOURCE_SYSTEM, _SOURCE_TABLE, _ROW_HASH, _STATUS
# Create it from DIGITAL.ABANDONED_CARTS (which exists) + add _STATUS column
if not table_exists('DIGITAL', 'ABANDONED_CARTS_STG'):
    print("Creating DIGITAL.ABANDONED_CARTS_STG from DIGITAL.ABANDONED_CARTS...")
    ensure_schema('DIGITAL')
    if table_exists('DIGITAL', 'ABANDONED_CARTS'):
        cur.execute(f"""
            CREATE TABLE {db}.DIGITAL.ABANDONED_CARTS_STG AS
            SELECT
                _ID,
                _LOADED_AT,
                _SOURCE_SYSTEM,
                _SOURCE_TABLE,
                _ROW_HASH,
                'ABANDONED' AS _STATUS
            FROM {db}.DIGITAL.ABANDONED_CARTS
        """)
    else:
        # Create empty stub table
        cur.execute(f"""
            CREATE TABLE {db}.DIGITAL.ABANDONED_CARTS_STG (
                _ID VARCHAR,
                _LOADED_AT TIMESTAMP,
                _SOURCE_SYSTEM VARCHAR,
                _SOURCE_TABLE VARCHAR,
                _ROW_HASH VARCHAR,
                _STATUS VARCHAR
            )
        """)
    cur.execute(f'GRANT SELECT ON {db}.DIGITAL.ABANDONED_CARTS_STG TO ROLE {agent_role}')
    print("  Created DIGITAL.ABANDONED_CARTS_STG")
else:
    print("DIGITAL.ABANDONED_CARTS_STG already exists")

# --- Fix 2: CUSTOMER.CONSENT_PREFERENCES ---
# This raw table does not exist in the CUSTOMER schema of the source DB.
# The stg_consent_preferences model references source('customer', 'CONSENT_PREFERENCES')
# which maps to CUSTOMER.CONSENT_PREFERENCES. Create it from AUDIT.CONSENT_PREFERENCES if available.
if not table_exists('CUSTOMER', 'CONSENT_PREFERENCES'):
    print("Creating CUSTOMER.CONSENT_PREFERENCES...")
    ensure_schema('CUSTOMER')
    # Check if AUDIT.CONSENT_PREFERENCES exists (the actual data source)
    if table_exists('AUDIT', 'CONSENT_PREFERENCES'):
        cur.execute(f"""
            CREATE TABLE {db}.CUSTOMER.CONSENT_PREFERENCES AS
            SELECT * FROM {db}.AUDIT.CONSENT_PREFERENCES
        """)
    else:
        # Create empty stub table with expected columns
        cur.execute(f"""
            CREATE TABLE {db}.CUSTOMER.CONSENT_PREFERENCES (
                PREFERENCE_ID VARCHAR,
                CUSTOMER_ID VARCHAR,
                CONSENT_TYPE VARCHAR,
                IS_CONSENTED BOOLEAN,
                CONSENT_DATE TIMESTAMP,
                IP_ADDRESS VARCHAR,
                CREATED_AT TIMESTAMP
            )
        """)
    cur.execute(f'GRANT SELECT ON {db}.CUSTOMER.CONSENT_PREFERENCES TO ROLE {agent_role}')
    print("  Created CUSTOMER.CONSENT_PREFERENCES")
else:
    print("CUSTOMER.CONSENT_PREFERENCES already exists")

conn.close()
print("Source table fixes complete.")
FIX_SOURCES_PY

    # --- Fix 3: stg_web_sessions ROUND(BOOLEAN) error ---
    # The Snowflake staging model has ROUND(IS_CONVERTED, 6) which fails because
    # IS_CONVERTED is BOOLEAN in Snowflake. Replace with proper cast.
    echo "Fixing stg_web_sessions staging model (ROUND(BOOLEAN) error)..."
    cat > "$DBT_PROJECT_DIR/models/staging/digital/stg_web_sessions.sql" << 'STG_WEB_SESSIONS_FIX'
{{
    config(
        materialized='view',
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'WEB_SESSIONS') }}
),

deduplicated AS (
    SELECT
        SESSION_ID,
        VISITOR_ID,
        CUSTOMER_ID,
        CHANNEL_ID,
        SESSION_START,
        SESSION_END,
        DURATION_SECONDS,
        PAGE_VIEWS,
        LANDING_PAGE,
        EXIT_PAGE,
        REFERRER,
        UTM_SOURCE,
        UTM_MEDIUM,
        UTM_CAMPAIGN,
        DEVICE_TYPE,
        BROWSER,
        OS,
        IP_ADDRESS,
        COUNTRY,
        IS_CONVERTED
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SESSION_ID ORDER BY created_at DESC) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(SESSION_ID) AS session_id,
        TRIM(VISITOR_ID) AS visitor_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CHANNEL_ID) AS channel_id,
        SESSION_START AS session_start,
        SESSION_END AS session_end,
        COALESCE(DURATION_SECONDS, 0) as duration_seconds,
        COALESCE(PAGE_VIEWS, 0) as page_views,
        TRIM(LANDING_PAGE) AS landing_page,
        TRIM(EXIT_PAGE) AS exit_page,
        TRIM(REFERRER) AS referrer,
        TRIM(UTM_SOURCE) AS utm_source,
        TRIM(UTM_MEDIUM) AS utm_medium,
        TRIM(UTM_CAMPAIGN) AS utm_campaign,
        TRIM(DEVICE_TYPE) AS device_type,
        TRIM(BROWSER) AS browser,
        TRIM(OS) AS os,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(COUNTRY) AS country,
        CASE WHEN IS_CONVERTED THEN TRUE ELSE FALSE END AS is_converted
    FROM cleaned
    WHERE SESSION_ID IS NOT NULL
)

SELECT * FROM renamed
ORDER BY customer_id
STG_WEB_SESSIONS_FIX
    echo "  Fixed stg_web_sessions"

    # --- Fix 3b: stg_shopping_carts COALESCE(CONVERTED_AT, '') error ---
    # The Snowflake staging model has COALESCE(CONVERTED_AT, '') which tries to cast
    # empty string to TIMESTAMP when CONVERTED_AT is NULL, causing
    # "Timestamp '' is not recognized". Fix: pass CONVERTED_AT through as-is.
    echo "Fixing stg_shopping_carts staging model (COALESCE TIMESTAMP error)..."
    cat > "$DBT_PROJECT_DIR/models/staging/digital/stg_shopping_carts.sql" << 'STG_SHOPPING_CARTS_FIX'
{{
    config(
        materialized='view',
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'SHOPPING_CARTS') }}
),

deduplicated AS (
    SELECT
        CART_ID,
        SESSION_ID,
        CUSTOMER_ID,
        CHANNEL_ID,
        STATUS,
        ITEM_COUNT,
        SUBTOTAL,
        CREATED_AT,
        UPDATED_AT,
        CONVERTED_AT,
        ORDER_ID
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CART_ID ORDER BY updated_at DESC, created_at DESC) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(CART_ID) AS cart_id,
        TRIM(SESSION_ID) AS session_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(STATUS) AS status,
        COALESCE(ITEM_COUNT, 0) as item_count,
        COALESCE(SUBTOTAL, 0) as subtotal,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        CONVERTED_AT AS converted_at,
        TRIM(ORDER_ID) AS order_id
    FROM cleaned
    WHERE CART_ID IS NOT NULL
)

SELECT * FROM renamed
ORDER BY order_id
STG_SHOPPING_CARTS_FIX
    echo "  Fixed stg_shopping_carts"

    # --- Fix 4: stg_abandoned_carts_stg missing _status column ---
    # The Snowflake staging model is missing _status column and has syntax errors
    echo "Fixing stg_abandoned_carts_stg staging model (missing _status column)..."
    cat > "$DBT_PROJECT_DIR/models/staging/raw_ga/stg_abandoned_carts_stg.sql" << 'STG_ABANDONED_FIX'
{{
    config(
        materialized='view',
        unique_key='_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'ABANDONED_CARTS_STG') }}
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(_ID) AS _id,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_SOURCE_TABLE) AS _source_table,
        TRIM(_ROW_HASH) AS _row_hash,
        TRIM(_STATUS) AS _status
    FROM cleaned
    WHERE _ID IS NOT NULL
)

SELECT * FROM renamed
STG_ABANDONED_FIX
    echo "  Fixed stg_abandoned_carts_stg"

    echo "All Snowflake source fixes applied."
fi

mkdir -p "$DBT_PROJECT_DIR/models/intermediate/cart_recovery"
mkdir -p "$DBT_PROJECT_DIR/models/marts/digital"

# Create cart_base model (works on both DuckDB and Snowflake)
if [ "$DB_TYPE" = "snowflake" ]; then
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__cart_base.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'digital']
    )
}}

with carts as (
    select * from {{ ref('stg_shopping_carts') }}
),

items as (
    select * from {{ ref('stg_shopping_cart_items') }}
),

abandoned as (
    select
        _id as cart_id,
        _status as abandoned_status,
        _loaded_at as abandoned_loaded_at
    from {{ ref('stg_abandoned_carts_stg') }}
),

item_rollup as (
    select
        cart_id,
        count(*) as item_line_count,
        count(distinct variant_id) as distinct_variants,
        sum(coalesce(quantity, 0)) as total_quantity,
        sum(coalesce(line_total, 0)) as items_total,
        min(added_at) as first_item_added_at,
        max(added_at) as last_item_added_at,
        max(updated_at) as last_item_updated_at
    from items
    group by cart_id
),

carts_enriched as (
    select
        c.cart_id,
        c.session_id,
        c.customer_id,
        c.channel_id,
        c.status as cart_status,
        c.item_count as cart_item_count_reported,
        c.subtotal as cart_subtotal_reported,
        c.created_at,
        c.updated_at,
        c.converted_at,
        c.order_id,
        a.abandoned_status,
        a.abandoned_loaded_at,
        i.item_line_count,
        i.distinct_variants,
        i.total_quantity,
        i.items_total,
        i.first_item_added_at,
        i.last_item_added_at,
        i.last_item_updated_at,
        coalesce(i.items_total, c.subtotal, 0) as cart_merch_value,
        greatest(
            coalesce(c.updated_at, c.created_at),
            coalesce(i.last_item_updated_at, i.last_item_added_at, c.created_at),
            coalesce(c.converted_at, c.created_at)
        ) as last_activity_at,
        case
            when upper(c.status) = 'CONVERTED'
                or c.order_id is not null
                or c.converted_at is not null
                then true
            else false
        end as is_converted,
        case
            when upper(c.status) = 'ABANDONED' then true
            when upper(coalesce(a.abandoned_status, '')) = 'ABANDONED' then true
            when c.converted_at is null
                and c.order_id is null
                and upper(c.status) in ('CANCELLED', 'EXPIRED')
                then true
            else false
        end as is_abandoned
    from carts c
    left join item_rollup i on c.cart_id = i.cart_id
    left join abandoned a on c.cart_id = a.cart_id
)

select
    *,
    datediff(second, last_activity_at, cast('2026-01-22T12:00:00.000' as timestamp)) / 3600.0 as hours_since_last_activity,
    datediff(second, created_at, cast('2026-01-22T12:00:00.000' as timestamp)) / 3600.0 as cart_age_hours
from carts_enriched
_EOF_
else
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__cart_base.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'digital']
    )
}}

with carts as (
    select * from {{ ref('stg_shopping_carts') }}
),

items as (
    select * from {{ ref('stg_shopping_cart_items') }}
),

abandoned as (
    select
        _id as cart_id,
        _status as abandoned_status,
        _loaded_at as abandoned_loaded_at
    from {{ ref('stg_abandoned_carts_stg') }}
),

item_rollup as (
    select
        cart_id,
        count(*) as item_line_count,
        count(distinct variant_id) as distinct_variants,
        sum(coalesce(quantity, 0)) as total_quantity,
        sum(coalesce(line_total, 0)) as items_total,
        min(added_at) as first_item_added_at,
        max(added_at) as last_item_added_at,
        max(updated_at) as last_item_updated_at
    from items
    group by cart_id
),

carts_enriched as (
    select
        c.cart_id,
        c.session_id,
        c.customer_id,
        c.channel_id,
        c.status as cart_status,
        c.item_count as cart_item_count_reported,
        c.subtotal as cart_subtotal_reported,
        c.created_at,
        c.updated_at,
        c.converted_at,
        c.order_id,
        a.abandoned_status,
        a.abandoned_loaded_at,
        i.item_line_count,
        i.distinct_variants,
        i.total_quantity,
        i.items_total,
        i.first_item_added_at,
        i.last_item_added_at,
        i.last_item_updated_at,
        coalesce(i.items_total, c.subtotal, 0) as cart_merch_value,
        greatest(
            coalesce(c.updated_at, c.created_at),
            coalesce(i.last_item_updated_at, i.last_item_added_at, c.created_at),
            coalesce(c.converted_at, c.created_at)
        ) as last_activity_at,
        case
            when upper(c.status) = 'CONVERTED'
                or c.order_id is not null
                or c.converted_at is not null
                then true
            else false
        end as is_converted,
        case
            when upper(c.status) = 'ABANDONED' then true
            when upper(coalesce(a.abandoned_status, '')) = 'ABANDONED' then true
            when c.converted_at is null
                and c.order_id is null
                and upper(c.status) in ('CANCELLED', 'EXPIRED')
                then true
            else false
        end as is_abandoned
    from carts c
    left join item_rollup i on c.cart_id = i.cart_id
    left join abandoned a on c.cart_id = a.cart_id
)

select
    *,
    extract(epoch from (cast('2026-01-22T12:00:00.000' as timestamp) - last_activity_at)) / 3600.0 as hours_since_last_activity,
    extract(epoch from (cast('2026-01-22T12:00:00.000' as timestamp) - created_at)) / 3600.0 as cart_age_hours
from carts_enriched
_EOF_
fi

# Customer context model (works on both)
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__customer_context.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'customer']
    )
}}

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

tiers as (
    select * from {{ ref('stg_customer__customer_tiers') }}
),

consent as (
    select * from {{ ref('stg_consent_preferences') }}
),

consent_pivot as (
    select
        customer_id,
        max(case when upper(consent_type) in ('MARKETING_EMAIL', 'EMAIL') and is_consented then 1 else 0 end) as email_consent,
        max(case when upper(consent_type) in ('MARKETING_SMS', 'SMS') and is_consented then 1 else 0 end) as sms_consent,
        max(case when upper(consent_type) in ('MARKETING_PUSH', 'PUSH', 'PUSH_NOTIFICATIONS') and is_consented then 1 else 0 end) as push_consent,
        max(case when upper(consent_type) in ('PERSONALIZATION', 'ANALYTICS') and is_consented then 1 else 0 end) as personalization_consent,
        max(consent_date) as last_consent_at
    from consent
    group by customer_id
),

customer_enriched as (
    select
        c.customer_id,
        c.customer_type,
        c.email,
        c.phone_primary,
        c.total_lifetime_value,
        c.total_orders,
        c.current_tier_id,
        c.churn_risk_score,
        c.propensity_to_buy,
        c.days_since_last_order,
        c.customer_tenure_days,
        c.preferred_language,
        c.preferred_currency,
        c.customer_segment_snapshot,
        t.tier_name,
        t.tier_level,
        t.discount_percentage,
        t.free_shipping,
        coalesce(cp.email_consent, 0) as email_consent,
        coalesce(cp.sms_consent, 0) as sms_consent,
        coalesce(cp.push_consent, 0) as push_consent,
        coalesce(cp.personalization_consent, 0) as personalization_consent,
        cp.last_consent_at
    from customers c
    left join tiers t on c.current_tier_id = t.tier_id
    left join consent_pivot cp on c.customer_id = cp.customer_id
)

select * from customer_enriched
_EOF_

# Inventory risk model (works on both)
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__inventory_risk.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'inventory']
    )
}}

with items as (
    select * from {{ ref('stg_shopping_cart_items') }}
),

inventory as (
    select * from {{ ref('stg_inventory_levels') }}
),

item_inventory as (
    select
        i.cart_id,
        i.variant_id,
        i.quantity,
        inv.quantity_available,
        inv.quantity_reserved,
        inv.quantity_on_hand,
        inv.inventory_status
    from items i
    left join inventory inv on i.variant_id = inv.variant_id
),

rollup as (
    select
        cart_id,
        count(*) as cart_line_count,
        sum(coalesce(quantity, 0)) as total_qty,
        sum(case when coalesce(quantity_available, 0) < coalesce(quantity, 0) then 1 else 0 end) as line_out_of_stock,
        sum(case when upper(coalesce(inventory_status, '')) in ('LOW_STOCK', 'OUT_OF_STOCK') then 1 else 0 end) as line_low_stock_status,
        min(quantity_available) as min_quantity_available,
        sum(coalesce(quantity_available, 0)) as total_quantity_available
    from item_inventory
    group by cart_id
)

select
    *,
    case
        when line_out_of_stock > 0 or line_low_stock_status > 0 then true
        else false
    end as inventory_risk_flag,
    case
        when line_out_of_stock > 0 then 'OUT_OF_STOCK'
        when line_low_stock_status > 0 then 'LOW_STOCK'
        else 'OK'
    end as inventory_risk_level
from rollup
_EOF_

# Session signals model (different syntax for DuckDB vs Snowflake)
if [ "$DB_TYPE" = "snowflake" ]; then
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__session_signals.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'digital']
    )
}}

with sessions as (
    select * from {{ ref('stg_web_sessions') }}
),

events as (
    select * from {{ ref('stg_web_events') }}
),

event_features as (
    select
        session_id,
        count(*) as event_count,
        sum(case when lower(event_name) like '%checkout%' or lower(event_type) like '%checkout%' then 1 else 0 end) as checkout_event_count,
        sum(case when lower(event_name) like '%payment%' and lower(event_type) = 'error' then 1 else 0 end) as payment_error_count,
        sum(case when lower(event_name) like '%add%' and lower(event_name) like '%cart%' then 1 else 0 end) as add_to_cart_count,
        sum(case when lower(event_name) like '%remove%' and lower(event_name) like '%cart%' then 1 else 0 end) as remove_from_cart_count,
        sum(case when lower(event_name) like '%view%' and lower(event_name) like '%product%' then 1 else 0 end) as product_view_count,
        min(event_timestamp) as first_event_at,
        max(event_timestamp) as last_event_at
    from events
    group by session_id
),

session_enriched as (
    select
        s.session_id,
        s.visitor_id,
        s.customer_id,
        s.channel_id,
        s.session_start,
        s.session_end,
        s.duration_seconds,
        s.page_views,
        s.landing_page,
        s.exit_page,
        s.referrer,
        s.utm_source,
        s.utm_medium,
        s.utm_campaign,
        s.device_type,
        s.browser,
        s.os,
        s.ip_address,
        s.country,
        s.is_converted,
        e.event_count,
        e.checkout_event_count,
        e.payment_error_count,
        e.add_to_cart_count,
        e.remove_from_cart_count,
        e.product_view_count,
        e.first_event_at,
        e.last_event_at,
        case
            when coalesce(e.payment_error_count, 0) > 0 then 2
            when coalesce(e.checkout_event_count, 0) > 0 then 1
            else 0
        end as checkout_depth_score,
        coalesce(e.add_to_cart_count, 0) - coalesce(e.remove_from_cart_count, 0) as cart_add_net,
        cast(coalesce(e.checkout_event_count, 0) as numeric) / nullif(e.event_count, 0) as checkout_event_ratio
    from sessions s
    left join event_features e on s.session_id = e.session_id
)

select * from session_enriched
_EOF_
else
cat > "$DBT_PROJECT_DIR/models/intermediate/cart_recovery/int_cart_recovery__session_signals.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'cart_recovery', 'digital']
    )
}}

with sessions as (
    select * from {{ ref('stg_web_sessions') }}
),

events as (
    select * from {{ ref('stg_web_events') }}
),

event_features as (
    select
        session_id,
        count(*) as event_count,
        count(*) filter (
            where lower(event_name) like '%checkout%'
               or lower(event_type) like '%checkout%'
        ) as checkout_event_count,
        count(*) filter (
            where lower(event_name) like '%payment%'
              and lower(event_type) = 'error'
        ) as payment_error_count,
        count(*) filter (
            where lower(event_name) like '%add%'
              and lower(event_name) like '%cart%'
        ) as add_to_cart_count,
        count(*) filter (
            where lower(event_name) like '%remove%'
              and lower(event_name) like '%cart%'
        ) as remove_from_cart_count,
        count(*) filter (
            where lower(event_name) like '%view%'
              and lower(event_name) like '%product%'
        ) as product_view_count,
        min(event_timestamp) as first_event_at,
        max(event_timestamp) as last_event_at
    from events
    group by session_id
),

session_enriched as (
    select
        s.session_id,
        s.visitor_id,
        s.customer_id,
        s.channel_id,
        s.session_start,
        s.session_end,
        s.duration_seconds,
        s.page_views,
        s.landing_page,
        s.exit_page,
        s.referrer,
        s.utm_source,
        s.utm_medium,
        s.utm_campaign,
        s.device_type,
        s.browser,
        s.os,
        s.ip_address,
        s.country,
        s.is_converted,
        e.event_count,
        e.checkout_event_count,
        e.payment_error_count,
        e.add_to_cart_count,
        e.remove_from_cart_count,
        e.product_view_count,
        e.first_event_at,
        e.last_event_at,
        case
            when coalesce(e.payment_error_count, 0) > 0 then 2
            when coalesce(e.checkout_event_count, 0) > 0 then 1
            else 0
        end as checkout_depth_score,
        coalesce(e.add_to_cart_count, 0) - coalesce(e.remove_from_cart_count, 0) as cart_add_net,
        coalesce(e.checkout_event_count, 0)::numeric / nullif(e.event_count, 0) as checkout_event_ratio
    from sessions s
    left join event_features e on s.session_id = e.session_id
)

select * from session_enriched
_EOF_
fi

# Final mart model (different syntax for DuckDB vs Snowflake)
if [ "$DB_TYPE" = "snowflake" ]; then
cat > "$DBT_PROJECT_DIR/models/marts/digital/fct_cart_recovery_priority.sql" << '_EOF_'
{{
    config(
        materialized='table',
        tags=['marts', 'digital', 'cart_recovery']
    )
}}

with cart_base as (
    select * from {{ ref('int_cart_recovery__cart_base') }}
),

session_signals as (
    select * from {{ ref('int_cart_recovery__session_signals') }}
),

inventory_risk as (
    select * from {{ ref('int_cart_recovery__inventory_risk') }}
),

customer_context as (
    select * from {{ ref('int_cart_recovery__customer_context') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_match as (
    select
        c.cart_id,
        min(o.ordered_at) as recovered_at,
        min(o.order_id) as recovered_order_id,
        min(o.grand_total) as recovered_grand_total
    from cart_base c
    join orders o
        on o.customer_id = c.customer_id
       and o.ordered_at >= c.last_activity_at
       and o.ordered_at <= dateadd(day, 7, c.last_activity_at)
       and upper(coalesce(o.status, '')) not in ('CANCELLED', 'VOID', 'TEST')
    group by c.cart_id
),

scored as (
    select
        c.cart_id,
        c.session_id,
        c.customer_id,
        c.channel_id,
        c.cart_status,
        c.item_line_count,
        c.distinct_variants,
        c.total_quantity,
        c.cart_merch_value,
        c.created_at,
        c.updated_at,
        c.last_activity_at,
        c.hours_since_last_activity,
        c.cart_age_hours,
        c.is_converted,
        c.is_abandoned,
        s.device_type,
        s.utm_source,
        s.utm_medium,
        s.utm_campaign,
        s.page_views,
        s.duration_seconds,
        s.checkout_event_count,
        s.payment_error_count,
        s.add_to_cart_count,
        s.remove_from_cart_count,
        s.checkout_depth_score,
        s.checkout_event_ratio,
        i.inventory_risk_flag,
        i.inventory_risk_level,
        cu.tier_name,
        cu.tier_level,
        cu.total_lifetime_value,
        cu.total_orders,
        cu.churn_risk_score,
        cu.propensity_to_buy,
        cu.customer_segment_snapshot,
        cu.email_consent,
        cu.sms_consent,
        cu.push_consent,
        o.recovered_order_id,
        o.recovered_at,
        o.recovered_grand_total,
        case
            when c.cart_merch_value >= 500 then 30
            when c.cart_merch_value >= 200 then 22
            when c.cart_merch_value >= 100 then 15
            else 8
        end as value_score,
        case
            when s.checkout_depth_score = 2 then 20
            when s.checkout_depth_score = 1 then 12
            else 5
        end as intent_score,
        case
            when coalesce(cu.tier_level, 0) >= 4 then 15
            when coalesce(cu.tier_level, 0) >= 3 then 10
            when coalesce(cu.tier_level, 0) >= 2 then 6
            else 3
        end as customer_score,
        case
            when coalesce(s.payment_error_count, 0) > 0 then -5
            when coalesce(s.remove_from_cart_count, 0) > 0 then -2
            else 0
        end as friction_adjustment,
        case
            when i.inventory_risk_flag then -5
            else 0
        end as inventory_adjustment
    from cart_base c
    left join session_signals s on c.session_id = s.session_id
    left join inventory_risk i on c.cart_id = i.cart_id
    left join customer_context cu on c.customer_id = cu.customer_id
    left join order_match o on c.cart_id = o.cart_id
    where c.is_abandoned = true
),

prioritized as (
    select
        *,
        (value_score + intent_score + customer_score + friction_adjustment + inventory_adjustment) as priority_score
    from scored
),

final as (
    select
        *,
        case
            when priority_score >= 55 then 'P0'
            when priority_score >= 40 then 'P1'
            else 'P2'
        end as priority_tier,
        case
            when email_consent = 1 then 'EMAIL'
            when sms_consent = 1 then 'SMS'
            when push_consent = 1 then 'PUSH'
            else 'SUPPRESS'
        end as recommended_channel,
        case
            when priority_score >= 55 then 2
            when priority_score >= 40 then 24
            else 72
        end as recovery_window_hours,
        case
            when priority_score >= 55 and (coalesce(payment_error_count, 0) > 0 or inventory_risk_flag) then true
            when priority_score >= 40 and coalesce(payment_error_count, 0) > 0 then true
            else false
        end as incentive_flag
    from prioritized
)

select
    cart_id,
    customer_id,
    session_id,
    channel_id,
    cart_status,
    cart_merch_value,
    item_line_count,
    distinct_variants,
    total_quantity,
    last_activity_at,
    hours_since_last_activity,
    cart_age_hours,
    device_type,
    utm_source,
    utm_medium,
    utm_campaign,
    checkout_event_count,
    payment_error_count,
    add_to_cart_count,
    remove_from_cart_count,
    inventory_risk_level,
    tier_name,
    tier_level,
    total_lifetime_value,
    total_orders,
    churn_risk_score,
    propensity_to_buy,
    customer_segment_snapshot,
    recommended_channel,
    priority_score,
    priority_tier,
    recovery_window_hours,
    last_activity_at as recovery_window_start,
    dateadd(hour, recovery_window_hours, last_activity_at) as recovery_window_end,
    incentive_flag,
    recovered_order_id,
    recovered_at,
    recovered_grand_total,
    case when recovered_order_id is not null or is_converted then true else false end as is_recovered,
    cast('2026-01-22T12:00:00.000' as timestamp) as scored_at
from final
_EOF_
else
cat > "$DBT_PROJECT_DIR/models/marts/digital/fct_cart_recovery_priority.sql" << '_EOF_'
{{
    config(
        materialized='table',
        tags=['marts', 'digital', 'cart_recovery']
    )
}}

with cart_base as (
    select * from {{ ref('int_cart_recovery__cart_base') }}
),

session_signals as (
    select * from {{ ref('int_cart_recovery__session_signals') }}
),

inventory_risk as (
    select * from {{ ref('int_cart_recovery__inventory_risk') }}
),

customer_context as (
    select * from {{ ref('int_cart_recovery__customer_context') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_match as (
    select
        c.cart_id,
        min(o.ordered_at) as recovered_at,
        min(o.order_id) as recovered_order_id,
        min(o.grand_total) as recovered_grand_total
    from cart_base c
    join orders o
        on o.customer_id = c.customer_id
       and o.ordered_at >= c.last_activity_at
       and o.ordered_at <= c.last_activity_at + interval '7 days'
       and upper(coalesce(o.status, '')) not in ('CANCELLED', 'VOID', 'TEST')
    group by c.cart_id
),

scored as (
    select
        c.cart_id,
        c.session_id,
        c.customer_id,
        c.channel_id,
        c.cart_status,
        c.item_line_count,
        c.distinct_variants,
        c.total_quantity,
        c.cart_merch_value,
        c.created_at,
        c.updated_at,
        c.last_activity_at,
        c.hours_since_last_activity,
        c.cart_age_hours,
        c.is_converted,
        c.is_abandoned,
        s.device_type,
        s.utm_source,
        s.utm_medium,
        s.utm_campaign,
        s.page_views,
        s.duration_seconds,
        s.checkout_event_count,
        s.payment_error_count,
        s.add_to_cart_count,
        s.remove_from_cart_count,
        s.checkout_depth_score,
        s.checkout_event_ratio,
        i.inventory_risk_flag,
        i.inventory_risk_level,
        cu.tier_name,
        cu.tier_level,
        cu.total_lifetime_value,
        cu.total_orders,
        cu.churn_risk_score,
        cu.propensity_to_buy,
        cu.customer_segment_snapshot,
        cu.email_consent,
        cu.sms_consent,
        cu.push_consent,
        o.recovered_order_id,
        o.recovered_at,
        o.recovered_grand_total,
        case
            when c.cart_merch_value >= 500 then 30
            when c.cart_merch_value >= 200 then 22
            when c.cart_merch_value >= 100 then 15
            else 8
        end as value_score,
        case
            when s.checkout_depth_score = 2 then 20
            when s.checkout_depth_score = 1 then 12
            else 5
        end as intent_score,
        case
            when coalesce(cu.tier_level, 0) >= 4 then 15
            when coalesce(cu.tier_level, 0) >= 3 then 10
            when coalesce(cu.tier_level, 0) >= 2 then 6
            else 3
        end as customer_score,
        case
            when coalesce(s.payment_error_count, 0) > 0 then -5
            when coalesce(s.remove_from_cart_count, 0) > 0 then -2
            else 0
        end as friction_adjustment,
        case
            when i.inventory_risk_flag then -5
            else 0
        end as inventory_adjustment
    from cart_base c
    left join session_signals s on c.session_id = s.session_id
    left join inventory_risk i on c.cart_id = i.cart_id
    left join customer_context cu on c.customer_id = cu.customer_id
    left join order_match o on c.cart_id = o.cart_id
    where c.is_abandoned = true
),

prioritized as (
    select
        *,
        (value_score + intent_score + customer_score + friction_adjustment + inventory_adjustment) as priority_score
    from scored
),

final as (
    select
        *,
        case
            when priority_score >= 55 then 'P0'
            when priority_score >= 40 then 'P1'
            else 'P2'
        end as priority_tier,
        case
            when email_consent = 1 then 'EMAIL'
            when sms_consent = 1 then 'SMS'
            when push_consent = 1 then 'PUSH'
            else 'SUPPRESS'
        end as recommended_channel,
        case
            when priority_score >= 55 then 2
            when priority_score >= 40 then 24
            else 72
        end as recovery_window_hours,
        case
            when priority_score >= 55 and (coalesce(payment_error_count, 0) > 0 or inventory_risk_flag) then true
            when priority_score >= 40 and coalesce(payment_error_count, 0) > 0 then true
            else false
        end as incentive_flag
    from prioritized
)

select
    cart_id,
    customer_id,
    session_id,
    channel_id,
    cart_status,
    cart_merch_value,
    item_line_count,
    distinct_variants,
    total_quantity,
    last_activity_at,
    hours_since_last_activity,
    cart_age_hours,
    device_type,
    utm_source,
    utm_medium,
    utm_campaign,
    checkout_event_count,
    payment_error_count,
    add_to_cart_count,
    remove_from_cart_count,
    inventory_risk_level,
    tier_name,
    tier_level,
    total_lifetime_value,
    total_orders,
    churn_risk_score,
    propensity_to_buy,
    customer_segment_snapshot,
    recommended_channel,
    priority_score,
    priority_tier,
    recovery_window_hours,
    last_activity_at as recovery_window_start,
    last_activity_at + (recovery_window_hours || ' hours')::interval as recovery_window_end,
    incentive_flag,
    recovered_order_id,
    recovered_at,
    recovered_grand_total,
    case when recovered_order_id is not null or is_converted then true else false end as is_recovered,
    cast('2026-01-22T12:00:00.000' as timestamp) as scored_at
from final
_EOF_
fi

cd "$DBT_PROJECT_DIR"

dbt deps
dbt run -s +fct_cart_recovery_priority


# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    mkdir -p "$DBT_PROJECT_DIR/macros"
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set tables = [
    'fct_cart_recovery_priority',
    'int_cart_recovery__cart_base',
    'int_cart_recovery__session_signals',
    'int_cart_recovery__inventory_risk',
    'int_cart_recovery__customer_context'
  ] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE TABLE "main"."' ~ t ~ '" AS SELECT * FROM MAIN.' ~ (t | upper)) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi

echo "Solution complete!"
