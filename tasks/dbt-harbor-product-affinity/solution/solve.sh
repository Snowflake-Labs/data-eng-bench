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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Pre-create required schemas in Snowflake before dbt runs
    # dbt may fail to create schemas if the agent role lacks CREATE SCHEMA privilege
    echo "Pre-creating required schemas in Snowflake..."
    python3 << 'PYSCHEMA' || echo "Warning: Schema pre-creation had issues, continuing anyway..."
import os, sys, base64, traceback
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization
import snowflake.connector

try:
    private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
    private_key_pem = base64.b64decode(private_key_b64)
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    p_key = serialization.load_pem_private_key(private_key_pem, password=passphrase_bytes, backend=default_backend())
    pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

    db = os.environ['SNOWFLAKE_DATABASE']
    # Try admin role first, fall back to agent role
    admin_role = os.environ.get('SNOWFLAKE_ADMIN_ROLE', '')
    agent_role = os.environ.get('SNOWFLAKE_ROLE', '')
    role = admin_role if admin_role else agent_role
    print(f"  Using role: {role} (admin={admin_role}, agent={agent_role})")
    print(f"  Database: {db}")

    conn = snowflake.connector.connect(
        account=os.environ['SNOWFLAKE_ACCOUNT'],
        **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
        user=os.environ['SNOWFLAKE_USER'],
        private_key=pkb,
        warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
        role=role if role else None,
        database=db,
    )
    cur = conn.cursor()
    for schema_name in ['MAIN_STAGING', 'MAIN_INTERMEDIATE', 'MAIN_MARTS']:
        try:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}")
            print(f"  Created/verified schema: {schema_name}")
        except Exception as e:
            print(f"  Warning creating schema {schema_name} with role {role}: {e}")
            # Try with agent role if admin role failed
            if role == admin_role and agent_role and agent_role != admin_role:
                try:
                    cur.execute(f"USE ROLE {agent_role}")
                    cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}")
                    print(f"  Created schema {schema_name} with agent role")
                except Exception as e2:
                    print(f"  Warning: Could not create schema {schema_name} with agent role either: {e2}")

    # Also grant permissions on new schemas to agent role if using admin role
    if admin_role and agent_role and admin_role != agent_role:
        try:
            cur.execute(f"USE ROLE {admin_role}")
        except:
            pass
        for schema_name in ['MAIN_STAGING', 'MAIN_INTERMEDIATE', 'MAIN_MARTS']:
            for priv in ['USAGE', 'CREATE TABLE', 'CREATE VIEW']:
                try:
                    cur.execute(f"GRANT {priv} ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
                except Exception as e:
                    print(f"  Warning granting {priv} on {schema_name}: {e}")
            # Grant DML on future and existing tables
            for priv in ['SELECT', 'INSERT', 'UPDATE', 'DELETE']:
                try:
                    cur.execute(f"GRANT {priv} ON FUTURE TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
                except:
                    pass
                try:
                    cur.execute(f"GRANT {priv} ON ALL TABLES IN SCHEMA {db}.{schema_name} TO ROLE {agent_role}")
                except:
                    pass

    conn.close()
    print("Schema pre-creation complete.")

except Exception as e:
    print(f"Warning: Schema pre-creation failed: {e}")
    traceback.print_exc()
    # Don't exit with error - let dbt try to create schemas itself
PYSCHEMA
    echo "Schema pre-creation step finished."

else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"

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
echo "Using dbt project: $DBT_PROJECT_DIR"

# Override schema naming to use custom schemas directly
cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- set target_name = target.name -%}

    {# If custom schema is provided, use it directly #}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}

{%- endmacro %}
EOF

# Create directory structure for models
mkdir -p "$DBT_PROJECT_DIR/models/staging/basket"
mkdir -p "$DBT_PROJECT_DIR/models/intermediate/affinity"
mkdir -p "$DBT_PROJECT_DIR/models/marts/merchandising"

# Model 1: Staging - Order Products
cat > "$DBT_PROJECT_DIR/models/staging/basket/stg_basket__order_products.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='main_staging'
) }}

with order_lines as (
    select
        ol.ORDER_ID as order_id,
        ol.PRODUCT_ID as product_id
    from {{ source('orders', 'ORDER_LINES') }} ol
    where ol.PRODUCT_ID is not null
),

products as (
    select
        p.PRODUCT_ID as product_id,
        p.PRODUCT_NAME as product_name,
        p.PRIMARY_CATEGORY_ID as category_id
    from {{ source('product', 'PRODUCTS') }} p
),

categories as (
    select
        c.CATEGORY_ID as category_id,
        c.CATEGORY_NAME as category_name
    from {{ source('product', 'PRODUCT_CATEGORIES') }} c
),

final as (
    select
        ol.order_id,
        ol.product_id,
        p.product_name,
        p.category_id,
        c.category_name
    from order_lines ol
    inner join products p on ol.product_id = p.product_id
    inner join categories c on p.category_id = c.category_id
)

select * from final
EOF

# Model 2: Intermediate - Product Pairs
cat > "$DBT_PROJECT_DIR/models/intermediate/affinity/int_affinity__product_pairs.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='main_intermediate'
) }}

with order_products as (
    select distinct
        order_id,
        product_id,
        product_name,
        category_id,
        category_name
    from {{ ref('stg_basket__order_products') }}
),

product_pairs as (
    select
        a.order_id,
        a.product_id as product_a_id,
        a.product_name as product_a_name,
        b.product_id as product_b_id,
        b.product_name as product_b_name,
        a.category_id as category_a_id,
        b.category_id as category_b_id
    from order_products a
    inner join order_products b
        on a.order_id = b.order_id
        and a.product_id < b.product_id
)

select * from product_pairs
EOF

# Model 3: Intermediate - Association Rules
cat > "$DBT_PROJECT_DIR/models/intermediate/affinity/int_affinity__association_rules.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='main_intermediate'
) }}

with product_pairs as (
    select
        product_a_id,
        product_a_name,
        product_b_id,
        product_b_name,
        order_id
    from {{ ref('int_affinity__product_pairs') }}
),

order_products as (
    select distinct
        order_id,
        product_id
    from {{ ref('stg_basket__order_products') }}
),

total_orders as (
    select count(distinct order_id) as total_order_count
    from order_products
),

pair_counts as (
    select
        product_a_id,
        product_a_name,
        product_b_id,
        product_b_name,
        count(distinct order_id) as orders_with_both
    from product_pairs
    group by product_a_id, product_a_name, product_b_id, product_b_name
),

product_counts as (
    select
        product_id,
        count(distinct order_id) as orders_with_product
    from order_products
    group by product_id
),

directional_pairs as (
    select
        product_a_id,
        product_a_name,
        product_b_id,
        product_b_name,
        orders_with_both
    from pair_counts
    union all
    select
        product_b_id as product_a_id,
        product_b_name as product_a_name,
        product_a_id as product_b_id,
        product_a_name as product_b_name,
        orders_with_both
    from pair_counts
),

metrics as (
    select
        dp.product_a_id,
        dp.product_a_name,
        dp.product_b_id,
        dp.product_b_name,
        dp.orders_with_both,
        pa.orders_with_product as orders_with_a,
        pb.orders_with_product as orders_with_b,
        t.total_order_count as total_orders,
        -- Support: P(A and B)
        CAST(dp.orders_with_both AS DOUBLE) / CAST(t.total_order_count AS DOUBLE) as support,
        -- Confidence: P(B|A)
        CAST(dp.orders_with_both AS DOUBLE) / CAST(pa.orders_with_product AS DOUBLE) as confidence,
        -- Lift: P(B|A) / P(B)
        (CAST(dp.orders_with_both AS DOUBLE) / CAST(pa.orders_with_product AS DOUBLE)) /
        (CAST(pb.orders_with_product AS DOUBLE) / CAST(t.total_order_count AS DOUBLE)) as lift,
        -- Conviction: (1 - P(B)) / (1 - Confidence)
        (1.0 - (CAST(pb.orders_with_product AS DOUBLE) / CAST(t.total_order_count AS DOUBLE))) /
        nullif(1.0 - (CAST(dp.orders_with_both AS DOUBLE) / CAST(pa.orders_with_product AS DOUBLE)), 0) as conviction
    from directional_pairs dp
    inner join product_counts pa on dp.product_a_id = pa.product_id
    inner join product_counts pb on dp.product_b_id = pb.product_id
    cross join total_orders t
)

select * from metrics
EOF

# Model 4: Fact - Product Affinity Matrix
cat > "$DBT_PROJECT_DIR/models/marts/merchandising/fct_product_affinity_matrix.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='main_marts'
) }}

with association_rules as (
    select * from {{ ref('int_affinity__association_rules') }}
),

products as (
    select
        PRODUCT_ID as product_id,
        PRIMARY_CATEGORY_ID as category_id
    from {{ source('product', 'PRODUCTS') }}
),

filtered_affinity as (
    select
        ar.product_a_id,
        ar.product_a_name,
        ar.product_b_id,
        ar.product_b_name,
        pa.category_id as category_a_id,
        pb.category_id as category_b_id,
        ar.support,
        ar.confidence,
        ar.lift,
        ar.conviction,
        ar.orders_with_both
    from association_rules ar
    inner join products pa
        on ar.product_a_id = pa.product_id
    inner join products pb
        on ar.product_b_id = pb.product_id
    where ar.lift >= 1.2
        and pa.category_id != pb.category_id
)

select * from filtered_affinity
EOF

# Model 5: Report - Recommended Bundles
cat > "$DBT_PROJECT_DIR/models/marts/merchandising/rpt_recommended_bundles.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='main_marts'
) }}

with affinity_matrix as (
    select * from {{ ref('fct_product_affinity_matrix') }}
),

ranked_bundles as (
    select
        row_number() over (
            order by
                lift desc,
                confidence desc,
                orders_with_both desc,
                product_a_id asc,
                product_b_id asc
        ) as bundle_rank,
        product_a_id,
        product_a_name,
        product_b_id,
        product_b_name,
        lift,
        confidence,
        orders_with_both
    from affinity_matrix
)

select * from ranked_bundles
where bundle_rank <= 50
EOF

# Run dbt models
cd "$DBT_PROJECT_DIR"
dbt deps
dbt run --select stg_basket__order_products int_affinity__product_pairs int_affinity__association_rules fct_product_affinity_matrix rpt_recommended_bundles

echo "All models created and executed successfully"
