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

echo "Preparing reference models..."
dbt deps || echo "deps already installed"
dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined || echo "reference run best effort"

echo "Setting up agent project..."
mkdir -p /app/dbt_project/models/marts/marketing

# Create agent project dbt_project.yml
cat > /app/dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]
EOF

# Create agent project profile based on DB_TYPE
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > /app/dbt_project/profiles.yml <<PROFILES
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
      schema: analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
    cat > /app/dbt_project/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH:-/app/database/retail.duckdb}'
      schema: analytics
      threads: 4
PROFILES
fi

cat > /app/dbt_project/models/marts/marketing/rpt_multi_touch_attribution_fixed.sql << 'SQLEOF'
{{
    config(
        materialized='table',
        tags=['marketing', 'multi_touch', 'ga4']
    )
}}
-- Fixed 91-day window: 2025-10-02 to 2025-12-31. Five attribution models + channel_group + assist_sessions.

{% set sessions_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__sessions') %}
{% set events_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_ga__events') %}
{% set joined_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sessions_events_joined') %}
{% set ns = namespace(has_joined_revenue=false) %}
{% if joined_rel %}
  {% for col in adapter.get_columns_in_relation(joined_rel) %}
    {% if col.name and col.name | lower == 't2_event_value' %}
      {% set ns.has_joined_revenue = true %}
    {% endif %}
  {% endfor %}
{% endif %}

WITH sessions_base AS (
    SELECT DISTINCT
        s.session_id,
        COALESCE(s.visitor_id, s.session_id) AS visitor_id,
        CAST(s.session_start AS DATE) AS attribution_date,
        COALESCE(s.utm_source, 'direct') AS channel,
        COALESCE(s.utm_medium, 'none') AS medium,
        COALESCE(s.utm_campaign, 'none') AS campaign,
        CASE
            WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('cpc','ppc','paid','cpm') THEN 'Paid'
            WHEN LOWER(TRIM(COALESCE(s.utm_medium,''))) = 'organic' THEN 'Organic'
            WHEN LOWER(TRIM(COALESCE(s.utm_source,''))) IN ('','direct')
                 AND LOWER(TRIM(COALESCE(s.utm_medium,''))) IN ('','none','(none)') THEN 'Direct'
            ELSE 'Referral'
        END AS channel_group,
        {% if target.type == 'snowflake' %}
        CASE WHEN UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES') THEN TRUE ELSE FALSE END AS is_converted,
        {% else %}
        s.is_converted,
        {% endif %}
        s.session_start
    FROM {{ sessions_rel }} s
    WHERE s.session_id IS NOT NULL
      AND s.session_start IS NOT NULL
      AND CAST(s.session_start AS DATE) BETWEEN CAST('2025-10-02' AS DATE) AND CAST('2025-12-31' AS DATE)
),

conversion_revenue AS (
    {% if ns.has_joined_revenue %}
    SELECT j.session_id, ROUND(SUM(COALESCE(CAST(j.t2_event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
    FROM {{ joined_rel }} j
    JOIN {{ sessions_rel }} s ON j.session_id = s.session_id
    WHERE
        {% if target.type == 'snowflake' %}
        UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')
        {% else %}
        s.is_converted = true
        {% endif %}
        AND CAST(s.session_start AS DATE) BETWEEN CAST('2025-10-02' AS DATE) AND CAST('2025-12-31' AS DATE)
        AND j.t2_event_name = 'purchase' AND j.t2_event_value IS NOT NULL
    GROUP BY j.session_id
    {% elif events_rel %}
    SELECT e.session_id, ROUND(SUM(COALESCE(CAST(e.event_value AS DECIMAL(12,2)), 0)), 2) AS conversion_value
    FROM {{ events_rel }} e
    JOIN {{ sessions_rel }} s ON e.session_id = s.session_id
    WHERE
        {% if target.type == 'snowflake' %}
        UPPER(CAST(s.is_converted AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')
        {% else %}
        s.is_converted = true
        {% endif %}
        AND CAST(s.session_start AS DATE) BETWEEN CAST('2025-10-02' AS DATE) AND CAST('2025-12-31' AS DATE)
        AND e.event_name = 'purchase' AND e.event_value IS NOT NULL
    GROUP BY e.session_id
    {% else %}
    SELECT CAST(NULL AS VARCHAR) AS session_id, CAST(0 AS DECIMAL(12,2)) AS conversion_value WHERE 1=0
    {% endif %}
),

assist_sessions_agg AS (
    SELECT
        sb.attribution_date,
        sb.channel,
        sb.medium,
        sb.campaign,
        COUNT(DISTINCT sb.session_id) AS assist_sessions
    FROM sessions_base sb
    WHERE EXISTS (
        SELECT 1 FROM sessions_base c
        WHERE c.visitor_id = sb.visitor_id AND c.is_converted = true AND c.session_start > sb.session_start
    )
    GROUP BY 1, 2, 3, 4
),

last_touch AS (
    SELECT
        sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
        'last_touch' AS attribution_model,
        COUNT(DISTINCT sb.session_id) AS sessions,
        SUM(CASE WHEN sb.is_converted THEN 1 ELSE 0 END) AS conversions,
        ROUND(COALESCE(SUM(cr.conversion_value), 0), 2) AS attributed_revenue
    FROM sessions_base sb
    LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
    GROUP BY 1, 2, 3, 4, 5
),

first_touch AS (
    WITH first_sessions AS (
        SELECT visitor_id, MIN(session_start) AS first_session_start
        FROM sessions_base GROUP BY 1
    ),
    user_totals AS (
        SELECT visitor_id, COUNT(DISTINCT session_id) AS total_sessions,
               SUM(CASE WHEN is_converted THEN 1 ELSE 0 END) AS total_conversions
        FROM sessions_base GROUP BY visitor_id
    ),
    user_revenue AS (
        SELECT sb.visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS total_revenue
        FROM sessions_base sb LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
        WHERE sb.is_converted GROUP BY sb.visitor_id
    ),
    first_attrs AS (
        SELECT sb.visitor_id, CAST(fs.first_session_start AS DATE) AS attribution_date,
               sb.channel, sb.medium, sb.campaign, sb.channel_group
        FROM sessions_base sb
        JOIN first_sessions fs ON sb.visitor_id = fs.visitor_id AND sb.session_start = fs.first_session_start
    )
    SELECT fa.attribution_date, fa.channel, fa.medium, fa.campaign, fa.channel_group,
           'first_touch' AS attribution_model,
           CAST(SUM(ut.total_sessions) AS INTEGER) AS sessions,
           CAST(SUM(ut.total_conversions) AS INTEGER) AS conversions,
           CAST(ROUND(COALESCE(SUM(ur.total_revenue), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue
    FROM first_attrs fa
    JOIN user_totals ut ON fa.visitor_id = ut.visitor_id
    LEFT JOIN user_revenue ur ON fa.visitor_id = ur.visitor_id
    GROUP BY 1, 2, 3, 4, 5
),

linear AS (
    WITH sc AS (SELECT visitor_id, COUNT(DISTINCT session_id) AS cnt FROM sessions_base GROUP BY 1),
         ut AS (SELECT visitor_id, SUM(CASE WHEN is_converted THEN 1 ELSE 0 END) AS tc FROM sessions_base GROUP BY 1),
         ur AS (SELECT sb.visitor_id, ROUND(SUM(COALESCE(cr.conversion_value, 0)), 2) AS tr
               FROM sessions_base sb LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id
               WHERE sb.is_converted GROUP BY sb.visitor_id)
    SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
           'linear' AS attribution_model,
           CAST(COUNT(DISTINCT sb.session_id) AS INTEGER) AS sessions,
           CAST(ROUND(COALESCE(SUM(ut.tc), 0) / NULLIF(MAX(sc.cnt), 0), 0) AS INTEGER) AS conversions,
           CAST(ROUND(COALESCE(SUM(ur.tr), 0) / NULLIF(MAX(sc.cnt), 0), 2) AS DECIMAL(12,2)) AS attributed_revenue
    FROM sessions_base sb
    JOIN sc ON sb.visitor_id = sc.visitor_id
    LEFT JOIN ut ON sb.visitor_id = ut.visitor_id
    LEFT JOIN ur ON sb.visitor_id = ur.visitor_id
    GROUP BY 1, 2, 3, 4, 5
),

time_decay_paths AS (
    SELECT
        sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
        conv.session_id AS conv_sid,
        conv.conversion_value,
        POW(2.0, -(DATEDIFF('day', sb.attribution_date, CAST(conv.session_start AS DATE)) / 7.0)) AS w
    FROM (SELECT sb.session_id, sb.visitor_id, sb.session_start, COALESCE(cr.conversion_value, 0) AS conversion_value
          FROM sessions_base sb LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id WHERE sb.is_converted) conv
    JOIN sessions_base sb ON conv.visitor_id = sb.visitor_id AND sb.session_start <= conv.session_start
),
time_decay_norm AS (
    SELECT *, w / SUM(w) OVER (PARTITION BY conv_sid) AS nw
    FROM time_decay_paths
),
time_decay_agg AS (
    SELECT attribution_date, channel, medium, campaign, channel_group,
           SUM(nw) AS sum_conv, ROUND(SUM(nw * conversion_value), 2) AS sum_rev
    FROM time_decay_norm GROUP BY 1, 2, 3, 4, 5
),
dims AS (
    SELECT attribution_date, channel, medium, campaign, channel_group, COUNT(DISTINCT session_id) AS sessions
    FROM sessions_base GROUP BY 1, 2, 3, 4, 5
),
time_decay AS (
    SELECT d.attribution_date, d.channel, d.medium, d.campaign, d.channel_group, 'time_decay' AS attribution_model,
           CAST(d.sessions AS INTEGER) AS sessions,
           CAST(ROUND(COALESCE(t.sum_conv, 0), 0) AS INTEGER) AS conversions,
           CAST(COALESCE(t.sum_rev, 0) AS DECIMAL(12,2)) AS attributed_revenue
    FROM dims d LEFT JOIN time_decay_agg t ON d.attribution_date = t.attribution_date AND d.channel = t.channel
      AND d.medium = t.medium AND d.campaign = t.campaign AND d.channel_group = t.channel_group
),

position_paths AS (
    SELECT sb.attribution_date, sb.channel, sb.medium, sb.campaign, sb.channel_group,
           conv.session_id AS conv_sid, conv.conversion_value,
           ROW_NUMBER() OVER (PARTITION BY conv.session_id ORDER BY sb.session_start) AS pos,
           COUNT(*) OVER (PARTITION BY conv.session_id) AS N
    FROM (SELECT sb.session_id, sb.visitor_id, sb.session_start, COALESCE(cr.conversion_value, 0) AS conversion_value
          FROM sessions_base sb LEFT JOIN conversion_revenue cr ON sb.session_id = cr.session_id WHERE sb.is_converted) conv
    JOIN sessions_base sb ON conv.visitor_id = sb.visitor_id AND sb.session_start <= conv.session_start
),
position_share AS (
    SELECT *, (CASE WHEN N=1 THEN 1.0 WHEN N=2 THEN 0.5 WHEN pos=1 THEN 0.4 WHEN pos=N THEN 0.4 ELSE 0.2/(N-2) END) AS sh
    FROM position_paths
),
position_agg AS (
    SELECT attribution_date, channel, medium, campaign, channel_group,
           SUM(sh) AS sum_conv, ROUND(SUM(sh * conversion_value), 2) AS sum_rev
    FROM position_share GROUP BY 1, 2, 3, 4, 5
),
position_based AS (
    SELECT d.attribution_date, d.channel, d.medium, d.campaign, d.channel_group, 'position_based' AS attribution_model,
           CAST(d.sessions AS INTEGER) AS sessions,
           CAST(ROUND(COALESCE(p.sum_conv, 0), 0) AS INTEGER) AS conversions,
           CAST(COALESCE(p.sum_rev, 0) AS DECIMAL(12,2)) AS attributed_revenue
    FROM dims d LEFT JOIN position_agg p ON d.attribution_date = p.attribution_date AND d.channel = p.channel
      AND d.medium = p.medium AND d.campaign = p.campaign AND d.channel_group = p.channel_group
),

all_models AS (
    SELECT attribution_date, channel, medium, campaign, channel_group, attribution_model, sessions, conversions, attributed_revenue FROM last_touch
    UNION ALL SELECT attribution_date, channel, medium, campaign, channel_group, attribution_model, sessions, conversions, attributed_revenue FROM first_touch
    UNION ALL SELECT attribution_date, channel, medium, campaign, channel_group, attribution_model, sessions, conversions, attributed_revenue FROM linear
    UNION ALL SELECT attribution_date, channel, medium, campaign, channel_group, attribution_model, sessions, conversions, attributed_revenue FROM time_decay
    UNION ALL SELECT attribution_date, channel, medium, campaign, channel_group, attribution_model, sessions, conversions, attributed_revenue FROM position_based
)

SELECT
    m.attribution_date, m.channel, m.medium, m.campaign, m.channel_group, m.attribution_model,
    CAST(m.sessions AS INTEGER) AS sessions,
    CAST(m.conversions AS INTEGER) AS conversions,
    CAST(m.attributed_revenue AS DECIMAL(12,2)) AS attributed_revenue,
    CAST(CASE WHEN m.sessions > 0 THEN ROUND(CAST(m.conversions AS DECIMAL(18,8)) / CAST(m.sessions AS DECIMAL(18,8)), 4) ELSE 0.0 END AS DECIMAL(10,4)) AS conversion_rate,
    CAST(COALESCE(a.assist_sessions, 0) AS INTEGER) AS assist_sessions
FROM all_models m
LEFT JOIN assist_sessions_agg a ON m.attribution_date = a.attribution_date AND m.channel = a.channel AND m.medium = a.medium AND m.campaign = a.campaign
ORDER BY m.attribution_date DESC, m.channel, m.medium, m.campaign, m.attribution_model
SQLEOF

cd /app/dbt_project
export DBT_PROFILES_DIR="/app/dbt_project"
dbt run --select rpt_multi_touch_attribution_fixed

echo "Solution complete!"
