#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema and source views for Snowflake
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema and source views..."
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
# Create main schema and grant access
for schema_ref in ['"main"', 'MAIN']:
    try:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_ref}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_ref} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_ref} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_ref} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema_ref} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema_ref} TO ROLE {agent_role}')
        print(f'Created/granted schema {schema_ref} in {db}')
    except Exception as e:
        print(f'Warning with schema {schema_ref}: {e}')
# Create web_analytics schema
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.web_analytics')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}.web_analytics TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.web_analytics TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.web_analytics TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.web_analytics TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.web_analytics TO ROLE {agent_role}')
    print(f'Created schema web_analytics in {db}')
except Exception as e:
    print(f'Warning creating web_analytics: {e}')
# Create views in main for source tables that live in other schemas
for table_name, possible_schemas in [('WEB_SESSIONS', ['DIGITAL', 'RAW_GA']), ('PAGEVIEWS', ['RAW_GA', 'DIGITAL'])]:
    try:
        cur.execute(f"""
            SELECT TABLE_SCHEMA FROM {db}.INFORMATION_SCHEMA.TABLES
            WHERE TABLE_NAME = '{table_name}' AND TABLE_TYPE = 'BASE TABLE'
            LIMIT 1
        """)
        row = cur.fetchone()
        if row:
            src_schema = row[0]
            cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.{table_name} AS SELECT * FROM {db}.{src_schema}.{table_name}')
            cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.{table_name} TO ROLE {agent_role}')
            print(f'Created view main.{table_name} -> {src_schema}.{table_name}')
        else:
            print(f'WARNING: Table {table_name} not found in any schema')
    except Exception as e:
        print(f'Warning creating view for {table_name}: {e}')
conn.close()
PRECREATE_PY
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

cd /app

# Create dbt project structure
mkdir -p dbt_project/{models/staging,models/intermediate,models/marts,macros/utils}

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > dbt_project/profiles.yml <<PROFILES
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
      schema: web_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > dbt_project/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: web_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="/app/dbt_project"

# Create dbt_project.yml
cat > dbt_project/dbt_project.yml << 'EOF'
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

# Create generate_schema_name macro to use schema from profiles.yml directly
cat > dbt_project/macros/utils/generate_schema_name.sql << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Create sources.yml
cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: WEB_SESSIONS
      - name: PAGEVIEWS
EOF

# Create staging model for web sessions
# IS_CONVERTED may be VARCHAR in Snowflake - use UPPER(CAST()) pattern
cat > dbt_project/models/staging/stg_web__sessions.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(SESSION_ID) as session_id,
    trim(VISITOR_ID) as visitor_id,
    SESSION_START as session_start,
    SESSION_END as session_end,
    DURATION_SECONDS as duration_seconds,
    PAGE_VIEWS as page_views,
    trim(LANDING_PAGE) as landing_page,
    trim(EXIT_PAGE) as exit_page,
    trim(DEVICE_TYPE) as device_type,
    {% if target.type == 'snowflake' %}
    CASE WHEN UPPER(CAST(IS_CONVERTED AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES') THEN 1 ELSE 0 END as is_converted
    {% else %}
    CASE WHEN IS_CONVERTED THEN 1 ELSE 0 END as is_converted
    {% endif %}
from {{ source('main', 'WEB_SESSIONS') }}
EOF

# Create staging model for pageviews
cat > dbt_project/models/staging/stg_web__pageviews.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(PAGEVIEW_ID) as pageview_id,
    trim(SESSION_ID) as session_id,
    trim(PAGE_URL) as page_url,
    VIEWED_AT as viewed_at,
    TIME_ON_PAGE as time_on_page,
    trim(DEVICE_TYPE) as device_type
from {{ source('main', 'PAGEVIEWS') }}
EOF

# Create intermediate session metrics model
# Use integer-based boolean (1/0) for cross-DB compatibility
cat > dbt_project/models/intermediate/int_session_metrics.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    session_id,
    visitor_id,
    session_start,
    session_end,
    duration_seconds,
    page_views,
    landing_page,
    exit_page,
    device_type,
    is_converted,
    case when page_views = 1 then 1 else 0 end as is_bounce,
    -- Visit number per visitor
    row_number() over (
        partition by visitor_id
        order by session_start, session_id
    ) as visit_number
from {{ ref('stg_web__sessions') }}
EOF

# Create session quality scoring model with all new columns
# Uses integer-based booleans (1/0) and CAST AS DOUBLE for division
cat > dbt_project/models/marts/fct_session_quality.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with session_metrics as (
    select * from {{ ref('int_session_metrics') }}
),

scored as (
    select
        session_id,
        visitor_id,
        session_start,
        duration_seconds,
        page_views,
        is_bounce,
        is_converted,
        device_type,
        visit_number,
        case when visit_number > 1 then 1 else 0 end as is_returning_visitor,
        ntile(5) over (order by page_views, session_id) as engagement_score,
        ntile(5) over (order by duration_seconds, session_id) as duration_score,
        -- Engagement velocity: pages per minute
        case
            when duration_seconds < 60 then 0.0
            else round(cast(page_views as double) / (cast(duration_seconds as double) / 60.0), 4)
        end as engagement_velocity
    from session_metrics
),

with_categories as (
    select
        *,
        case
            when engagement_score >= 4 and duration_score >= 4 then 'Premium'
            when engagement_score >= 4 or duration_score >= 4 then 'High'
            when engagement_score >= 2 and duration_score >= 2 then 'Medium'
            else 'Low'
        end as quality_tier,
        case
            when duration_seconds < 60 then null
            when engagement_velocity > 2 then 'Fast'
            when engagement_velocity >= 1 then 'Normal'
            else 'Slow'
        end as velocity_category
    from scored
)

select
    session_id,
    visitor_id,
    session_start,
    duration_seconds,
    page_views,
    is_bounce,
    is_converted,
    device_type,
    engagement_score,
    duration_score,
    quality_tier,
    engagement_velocity,
    velocity_category,
    visit_number,
    is_returning_visitor
from with_categories
order by session_id
EOF

# Create session summary report model with new columns
# Uses integer-based booleans (= 1) for cross-DB compat
cat > dbt_project/models/marts/rpt_session_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with session_quality as (
    select * from {{ ref('fct_session_quality') }}
)

select
    device_type,
    count(*) as total_sessions,
    sum(case when is_converted = 1 then 1 else 0 end) as total_conversions,
    round(cast(sum(case when is_converted = 1 then 1 else 0 end) as double) / nullif(cast(count(*) as double), 0), 4) as conversion_rate,
    round(avg(cast(duration_seconds as double)), 2) as avg_duration,
    round(avg(cast(page_views as double)), 2) as avg_page_views,
    round(cast(sum(case when is_bounce = 1 then 1 else 0 end) as double) / nullif(cast(count(*) as double), 0), 4) as bounce_rate,
    sum(case when quality_tier = 'Premium' then 1 else 0 end) as premium_sessions,
    sum(case when quality_tier = 'High' then 1 else 0 end) as high_sessions,
    round(cast(sum(case when is_returning_visitor = 1 then 1 else 0 end) as double) / nullif(cast(count(*) as double), 0), 4) as returning_visitor_rate,
    round(avg(case when velocity_category is not null then engagement_velocity else null end), 4) as avg_engagement_velocity
from session_quality
group by device_type
order by device_type
EOF

# Create visitor segments report model
# Uses integer-based booleans (= 1) for cross-DB compat
cat > dbt_project/models/marts/rpt_visitor_segments.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with session_quality as (
    select * from {{ ref('fct_session_quality') }}
),

visitor_stats as (
    select
        visitor_id,
        count(*) as session_count,
        sum(case when is_converted = 1 then 1 else 0 end) as conversions
    from session_quality
    group by visitor_id
),

visitor_segments as (
    select
        visitor_id,
        session_count,
        conversions,
        case
            when session_count >= 5 then 'Power User'
            when session_count >= 2 then 'Regular'
            else 'One-Time'
        end as visitor_segment
    from visitor_stats
)

select
    visitor_segment,
    count(*) as visitor_count,
    sum(session_count) as total_sessions,
    round(cast(sum(session_count) as double) / nullif(cast(count(*) as double), 0), 2) as avg_sessions_per_visitor,
    sum(conversions) as total_conversions,
    round(cast(sum(conversions) as double) / nullif(cast(sum(session_count) as double), 0), 4) as conversion_rate
from visitor_segments
group by visitor_segment
order by visitor_segment
EOF

cd dbt_project
dbt deps || echo "dbt deps completed"
dbt run

echo "Solution complete!"
