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

cd "$DBT_PROJECT_DIR"

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

# Install dependencies first
dbt deps

# Create directories for models
mkdir -p models/intermediate/digital
mkdir -p models/marts/digital

# ============ INTERMEDIATE MODELS ============

# int_session_engagement
cat > models/intermediate/digital/int_session_engagement.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with page_views as (
    select
        session_id,
        count(*) as total_pageviews,
        count(distinct page_url) as unique_pages_viewed,
        coalesce(sum(time_on_page_seconds), 0) as total_time_on_pages_seconds,
        coalesce(avg(case when scroll_depth_percent is not null then scroll_depth_percent end), 0) as avg_scroll_depth_percent,
        count(case when page_type = 'PRODUCT' then 1 end) as product_page_views,
        count(case when page_type = 'CATEGORY' then 1 end) as category_page_views,
        count(case when page_type = 'CART' then 1 end) as cart_page_views,
        count(case when page_type = 'CHECKOUT' then 1 end) as checkout_page_views
    from {{ ref('stg_digital__web_page_views') }}
    group by session_id
),

events as (
    select
        session_id,
        count(case when event_type = 'ADD_TO_CART' then 1 end) as add_to_cart_events,
        count(case when event_type = 'VIDEO_PLAY' then 1 end) as video_play_events,
        count(case when event_type = 'SEARCH' then 1 end) as search_events
    from {{ ref('stg_digital__web_events') }}
    group by session_id
)

select
    coalesce(pv.session_id, e.session_id) as session_id,
    coalesce(pv.total_pageviews, 0) as total_pageviews,
    coalesce(pv.unique_pages_viewed, 0) as unique_pages_viewed,
    coalesce(pv.total_time_on_pages_seconds, 0) as total_time_on_pages_seconds,
    coalesce(pv.avg_scroll_depth_percent, 0) as avg_scroll_depth_percent,
    coalesce(pv.product_page_views, 0) as product_page_views,
    coalesce(pv.category_page_views, 0) as category_page_views,
    coalesce(pv.cart_page_views, 0) as cart_page_views,
    coalesce(pv.checkout_page_views, 0) as checkout_page_views,
    coalesce(e.add_to_cart_events, 0) as add_to_cart_events,
    coalesce(e.video_play_events, 0) as video_play_events,
    coalesce(e.search_events, 0) as search_events
from page_views pv
full outer join events e on pv.session_id = e.session_id
EOF

# int_session_cart_activity
cat > models/intermediate/digital/int_session_cart_activity.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

select
    session_id,
    true as cart_created,
    coalesce(max(item_count), 0) as cart_item_count,
    coalesce(max(subtotal), 0) as cart_subtotal,
    max(converted_at) is not null as cart_converted
from {{ ref('stg_digital__shopping_carts') }}
group by session_id
EOF

# int_session_product_interest
cat > models/intermediate/digital/int_session_product_interest.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with product_views as (
    select
        session_id,
        product_id
    from {{ ref('stg_digital__web_page_views') }}
    where page_type = 'PRODUCT'
        and product_id is not null
),

cart_items as (
    select
        sc.session_id,
        sci.variant_id,
        sci.quantity,
        sci.unit_price
    from {{ ref('stg_digital__shopping_carts') }} sc
    inner join {{ ref('stg_digital__shopping_cart_items') }} sci
        on sc.cart_id = sci.cart_id
),

wishlist_items as (
    select
        ws.session_id,
        wi.variant_id
    from {{ ref('stg_digital__web_sessions') }} ws
    inner join {{ ref('stg_digital__wishlist_items') }} wi
        on ws.visitor_id = wi.wishlist_id
),

product_views_agg as (
    select
        session_id,
        count(distinct product_id) as unique_products_viewed
    from product_views
    group by session_id
),

cart_items_agg as (
    select
        session_id,
        count(distinct variant_id) as products_added_to_cart,
        coalesce(sum(quantity), 0) as cart_item_quantity,
        coalesce(avg(unit_price), 0) as avg_product_price,
        max(case when unit_price > 100 then true else false end) as has_high_value_item
    from cart_items
    group by session_id
),

wishlist_items_agg as (
    select
        session_id,
        count(distinct variant_id) as products_wishlisted
    from wishlist_items
    group by session_id
),

all_sessions as (
    select distinct session_id
    from {{ ref('stg_digital__web_sessions') }}
)

select
    s.session_id,
    coalesce(pv.unique_products_viewed, 0) as unique_products_viewed,
    coalesce(ca.products_added_to_cart, 0) as products_added_to_cart,
    coalesce(wi.products_wishlisted, 0) as products_wishlisted,
    coalesce(ca.cart_item_quantity, 0) as cart_item_quantity,
    coalesce(ca.avg_product_price, 0) as avg_product_price,
    coalesce(ca.has_high_value_item, false) as has_high_value_item,
    case
        when coalesce(ca.products_added_to_cart, 0) = 0 then 0
        else round(CAST(coalesce(wi.products_wishlisted, 0) AS DECIMAL(18,4)) / CAST(ca.products_added_to_cart AS DECIMAL(18,4)), 2)
    end as wishlist_to_cart_ratio,
    least(100, round(
        (coalesce(pv.unique_products_viewed, 0) * 2) +
        (coalesce(ca.products_added_to_cart, 0) * 5) +
        (coalesce(wi.products_wishlisted, 0) * 3),
    2)) as product_interest_score
from all_sessions s
left join product_views_agg pv on s.session_id = pv.session_id
left join cart_items_agg ca on s.session_id = ca.session_id
left join wishlist_items_agg wi on s.session_id = wi.session_id
EOF

# ============ MARTS MODELS ============

# session_quality_scores
cat > models/marts/digital/session_quality_scores.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with sessions as (
    select *
    from {{ ref('stg_digital__web_sessions') }}
    where session_start >= (select max(session_start) from {{ ref('stg_digital__web_sessions') }}) - interval '90 days'
),

engagement as (
    select * from {{ ref('int_session_engagement') }}
),

cart_activity as (
    select * from {{ ref('int_session_cart_activity') }}
),

with_engagement_score as (
    select
        s.session_id,
        s.visitor_id,
        s.customer_id,
        s.session_start,
        cast(s.session_start as date) as session_date,
        s.duration_seconds as session_duration_seconds,
        round(s.duration_seconds / 60.0, 2) as session_duration_minutes,
        s.page_views,
        coalesce(e.unique_pages_viewed, 0) as unique_pages_viewed,
        s.landing_page,
        s.device_type,
        s.utm_source,
        s.utm_medium,
        s.utm_campaign,
        coalesce(s.utm_source, 'direct') as traffic_source,
        coalesce(e.product_page_views, 0) as product_views_count,
        coalesce(ca.cart_created, false) as added_to_cart,
        coalesce(ca.cart_subtotal, 0) as cart_value,
        s.is_converted or coalesce(ca.cart_converted, false) as did_convert,

        -- Engagement score calculation
        least(100, round(
            (least(coalesce(s.page_views, 0), 5) * 5) +
            (least(round(s.duration_seconds / 60.0, 2), 10) * 1.5) +
            (case when coalesce(e.product_page_views, 0) > 0 then 10 else 0 end) +
            (case when coalesce(ca.cart_created, false) then 15 else 0 end) +
            (case when coalesce(e.checkout_page_views, 0) > 0 then 5 else 0 end) +
            (case when coalesce(e.avg_scroll_depth_percent, 0) >= 75 then 10 else coalesce(e.avg_scroll_depth_percent, 0) / 10.0 end) +
            (case when coalesce(e.search_events, 0) > 0 then 5 else 0 end) +
            (case when coalesce(e.video_play_events, 0) > 0 then 5 else 0 end) +
            (case when coalesce(e.unique_pages_viewed, 0) >= 3 then 10 else coalesce(e.unique_pages_viewed, 0) * 3.0 end),
        2)) as engagement_score,

        s.page_views = 1 and s.duration_seconds < 10 as is_bounce,

        -- Bounce type
        case
            when s.page_views = 1 and s.duration_seconds < 10 then
                case
                    when s.duration_seconds < 3 then 'IMMEDIATE'
                    else 'SHORT_VISIT'
                end
        end as bounce_type,

        -- Store these for conversion probability calculation
        coalesce(e.checkout_page_views, 0) as checkout_page_views,
        coalesce(e.product_page_views, 0) as product_page_views_for_prob

    from sessions s
    left join engagement e on s.session_id = e.session_id
    left join cart_activity ca on s.session_id = ca.session_id
),

with_conversion_probability as (
    select
        *,
        -- Conversion probability calculation
        round(case
            when did_convert = true then 1.0
            when checkout_page_views > 0 then 0.85
            when engagement_score >= 80 and added_to_cart then 0.75
            when engagement_score >= 70 then 0.65
            when engagement_score >= 60 and product_page_views_for_prob >= 3 then 0.55
            when engagement_score >= 50 then 0.45
            when engagement_score >= 40 then 0.30
            when engagement_score >= 30 and product_page_views_for_prob > 0 then 0.25
            when engagement_score >= 20 then 0.15
            when is_bounce = false then 0.10
            else 0.05
        end, 2) as conversion_probability
    from with_engagement_score
)

select
    session_id,
    visitor_id,
    customer_id,
    session_start,
    session_date,
    session_duration_seconds,
    session_duration_minutes,
    page_views,
    unique_pages_viewed,
    landing_page,
    device_type,
    utm_source,
    utm_medium,
    utm_campaign,
    traffic_source,
    product_views_count,
    added_to_cart,
    cart_value,
    did_convert,
    engagement_score,
    is_bounce,
    bounce_type,
    conversion_probability,
    case
        when engagement_score >= 70 then 'HIGH'
        when engagement_score >= 40 then 'MEDIUM'
        else 'LOW'
    end as session_quality_tier,
    round(conversion_probability * 150.0, 2) as expected_value
from with_conversion_probability
order by session_start desc
EOF

# visitor_product_affinity
cat > models/marts/digital/visitor_product_affinity.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with sessions as (
    select
        visitor_id,
        session_id,
        session_start,
        is_converted
    from {{ ref('stg_digital__web_sessions') }}
    where session_start >= (select max(session_start) from {{ ref('stg_digital__web_sessions') }}) - interval '90 days'
),

product_interest as (
    select * from {{ ref('int_session_product_interest') }}
),

cart_activity as (
    select * from {{ ref('int_session_cart_activity') }}
),

visitor_sessions as (
    select
        s.visitor_id,
        s.session_id,
        cast(s.session_start as date) as session_date,
        coalesce(pi.unique_products_viewed, 0) as unique_products_viewed,
        coalesce(pi.products_added_to_cart, 0) as products_added_to_cart,
        coalesce(pi.products_wishlisted, 0) as products_wishlisted,
        coalesce(ca.cart_created, false) as has_cart,
        coalesce(pi.has_high_value_item, false) as has_high_value_item
    from sessions s
    left join product_interest pi on s.session_id = pi.session_id
    left join cart_activity ca on s.session_id = ca.session_id
)

select
    visitor_id,
    count(*) as total_sessions,
    count(case when unique_products_viewed > 0 then 1 end) as sessions_with_product_views,
    sum(unique_products_viewed) as total_products_viewed,
    round(CAST(sum(unique_products_viewed) AS DECIMAL(18,4)) / CAST(count(*) AS DECIMAL(18,4)), 2) as avg_products_per_session,
    sum(products_added_to_cart) as total_products_carted,
    sum(products_wishlisted) as total_products_wishlisted,
    round(CAST(count(case when has_cart then 1 end) AS DECIMAL(18,4)) / CAST(count(*) AS DECIMAL(18,4)), 2) as cart_conversion_rate,
    case
        when (sum(products_added_to_cart) + sum(products_wishlisted)) = 0 then 0
        else round(CAST(sum(products_wishlisted) AS DECIMAL(18,4)) / CAST((sum(products_added_to_cart) + sum(products_wishlisted)) AS DECIMAL(18,4)), 2)
    end as wishlist_preference_score,
    case
        when (sum(products_added_to_cart) + sum(products_wishlisted)) = 0 then 0
        else round(CAST(sum(unique_products_viewed) AS DECIMAL(18,4)) / CAST((sum(products_added_to_cart) + sum(products_wishlisted)) AS DECIMAL(18,4)), 2)
    end as browse_to_action_ratio,
    max(has_high_value_item) as high_value_shopper,
    case
        when round(CAST(count(case when has_cart then 1 end) AS DECIMAL(18,4)) / CAST(count(*) AS DECIMAL(18,4)), 2) >= 0.5 then 'CONVERTER'
        when (sum(products_added_to_cart) + sum(products_wishlisted)) > 0
             and round(CAST(sum(unique_products_viewed) AS DECIMAL(18,4)) / NULLIF(CAST((sum(products_added_to_cart) + sum(products_wishlisted)) AS DECIMAL(18,4)), 0), 2) >= 5.0
             and round(CAST(count(case when has_cart then 1 end) AS DECIMAL(18,4)) / CAST(count(*) AS DECIMAL(18,4)), 2) < 0.5 then 'BROWSER'
        when case
                when (sum(products_added_to_cart) + sum(products_wishlisted)) = 0 then 0
                else round(CAST(sum(products_wishlisted) AS DECIMAL(18,4)) / CAST((sum(products_added_to_cart) + sum(products_wishlisted)) AS DECIMAL(18,4)), 2)
             end >= 0.6 then 'RESEARCHER'
        else 'CASUAL'
    end as visitor_segment,
    min(session_date) as first_session_date,
    max(session_date) as last_session_date,
    case
        when count(*) = 1 then 0
        else max(session_date) - min(session_date)
    end as days_active
from visitor_sessions
group by visitor_id
order by total_sessions desc, visitor_id
EOF

# Run dbt
dbt run --select models/intermediate/digital models/marts/digital
