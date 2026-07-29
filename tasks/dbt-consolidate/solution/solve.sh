#!/bin/bash
# Solution script for dbt_consolidate task

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
    DBT_PROJECT_DIR="/app/dbt_consolidate"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

    # Create project structure
    mkdir -p "$DBT_PROJECT_DIR"/{models/staging,models/int,macros/utils,seeds}

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
      schema: analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Override schema naming macro so all models go to 'analytics' schema
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
MACRO

else
    DBT_PROJECT_DIR="/app/dbt_consolidate"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # Create project structure
    mkdir -p "$DBT_PROJECT_DIR"/{models/staging,models/int,macros,seeds}

    # DuckDB profile
    cat > "$DBT_PROJECT_DIR/profiles.yml" << 'EOF'
retail_dw_master:
  outputs:
    dev:
      type: duckdb
      path: /app/consolidate.duckdb
      schema: analytics
      threads: 2
  target: dev
EOF
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Copy seed files
cp /app/data/googleads.csv "$DBT_PROJECT_DIR/seeds/googleads.csv"
cp /app/data/metaads.csv "$DBT_PROJECT_DIR/seeds/metaads.csv"
cp /app/data/tiktokads.csv "$DBT_PROJECT_DIR/seeds/tiktokads.csv"

# Create dbt_project.yml
cat > "$DBT_PROJECT_DIR/dbt_project.yml" << 'EOF'
name: 'dbt_consolidate'
version: '1.0.0'

profile: 'retail_dw_master'

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

clean-targets:
  - "target"
  - "dbt_packages"

models:
  dbt_consolidate:
    staging:
      +materialized: view
    int:
      +materialized: table
EOF

cat > "$DBT_PROJECT_DIR/packages.yml" << 'EOF'
packages:
  - package: dbt-labs/dbt_utils
    version: 1.2.0
EOF

# Create staging models

cat > "$DBT_PROJECT_DIR/models/staging/staging.yml" << 'EOF'
version: 2

models:
  - name: stg__ads_googleads
  - name: stg__ads_metaads
  - name: stg__ads_tiktokads
EOF

cat > "$DBT_PROJECT_DIR/models/staging/stg__ads_googleads.sql" << 'EOF'
with source as (
	select ad_date
		, clicks
		, impressions
		, views as views
		, conversions
	from {{ ref('googleads') }}
)
select * from source
qualify row_number()
    over
        (partition by ad_date
                    , clicks
                    , impressions
                    , views
                    , conversions
                    order by ad_date
                ) = 1
EOF

cat > "$DBT_PROJECT_DIR/models/staging/stg__ads_metaads.sql" << 'EOF'
with source as (
	select ad_date
		, clicks
		, impressions
		, views_1 + views_2 as views
		, conversions
	from {{ ref('metaads') }}
)
select * from source
qualify row_number()
    over
        (partition by ad_date
                    , clicks
                    , impressions
                    , views
                    , conversions
                    order by ad_date
                ) = 1
EOF

cat > "$DBT_PROJECT_DIR/models/staging/stg__ads_tiktokads.sql" << 'EOF'
with source as (
	select ad_date
		, clicks
		, impressions
		, views_1 as views
		, conversions
	from {{ ref('tiktokads') }}
)
select * from source
qualify row_number()
    over
        (partition by ad_date
                    , clicks
                    , impressions
                    , views
                    , conversions
                    order by ad_date
                ) = 1
EOF

# Create unioned int model
cat > "$DBT_PROJECT_DIR/models/int/int.yml" << 'EOF'
version: 2

models:
  - name: int__ads_unified
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - source
            - ad_date
EOF

cat > "$DBT_PROJECT_DIR/models/int/int__ads_unified.sql" << 'EOF'
with unioned as (
    select 'google' as source, *
    from {{ ref('stg__ads_googleads') }}
    union all
    select 'meta' as source, *
    from {{ ref('stg__ads_metaads') }}
    union all
    select 'tiktok' as source, *
    from {{ ref('stg__ads_tiktokads') }}
)
select * from unioned
EOF

# Run dbt
cd "$DBT_PROJECT_DIR"
dbt deps --project-dir "$DBT_PROJECT_DIR" --profiles-dir "$DBT_PROJECT_DIR"
dbt seed --project-dir "$DBT_PROJECT_DIR" --profiles-dir "$DBT_PROJECT_DIR"
dbt run --select stg__ads_googleads stg__ads_metaads stg__ads_tiktokads int__ads_unified --project-dir "$DBT_PROJECT_DIR" --profiles-dir "$DBT_PROJECT_DIR"
dbt test --project-dir "$DBT_PROJECT_DIR" --profiles-dir "$DBT_PROJECT_DIR"

echo "Solution deployment complete"
