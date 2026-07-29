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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
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

# Create model directories
mkdir -p "$DBT_PROJECT_DIR/models/intermediate/reviews"
mkdir -p "$DBT_PROJECT_DIR/models/marts/reviews"

cat > "$DBT_PROJECT_DIR/models/intermediate/reviews/int_reviews__enriched.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['intermediate', 'reviews', 'trust-risk']
    )
}}

with reviews as (
    select
        review_id,
        product_id,
        variant_id,
        customer_id,
        order_id,
        rating,
        review_title,
        review_text,
        pros,
        cons,
        is_verified_purchase,
        is_recommended,
        helpful_count,
        not_helpful_count,
        status,
        moderated_at,
        moderated_by,
        rejection_reason,
        review_source,
        reviewer_display_name,
        submitted_at,
        created_at,
        updated_at,
        coalesce(submitted_at, created_at) as review_ts,
        cast(coalesce(submitted_at, created_at) as date) as review_date
    from {{ ref('stg_product__product_reviews') }}
),

orders as (
    select
        order_id,
        customer_id as order_customer_id,
        channel_id,
        order_source,
        order_type,
        status as order_status,
        payment_status,
        fulfillment_status,
        {% if target.type == 'snowflake' %}
        cast(ordered_at as timestamp) as ordered_at,
        {% else %}
        ordered_at,
        {% endif %}
        shipped_at,
        delivered_at,
        cancelled_at,
        fraud_score,
        fraud_check_status
    from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select
        order_line_id,
        order_id,
        line_number,
        product_id,
        variant_id,
        quantity_ordered,
        quantity_returned,
        unit_price,
        discount_amount,
        tax_amount,
        line_total,
        status as line_status
    from {{ ref('stg_orders__order_lines') }}
),

order_lines_orders as (
    select
        ol.order_line_id,
        ol.order_id,
        ol.line_number,
        ol.product_id,
        ol.variant_id,
        ol.quantity_ordered,
        ol.quantity_returned,
        ol.unit_price,
        ol.discount_amount,
        ol.tax_amount,
        ol.line_total,
        ol.line_status,
        o.order_customer_id as customer_id,
        o.channel_id,
        o.order_source,
        o.order_type,
        o.order_status,
        o.payment_status,
        o.fulfillment_status,
        o.ordered_at,
        o.shipped_at,
        o.delivered_at,
        o.cancelled_at,
        o.fraud_score,
        o.fraud_check_status
    from order_lines ol
    left join orders o on ol.order_id = o.order_id
),

review_line_match as (
    select
        r.review_id,
        ol.order_line_id,
        ol.order_id,
        ol.customer_id as order_customer_id,
        ol.channel_id,
        ol.order_source,
        ol.order_type,
        ol.order_status,
        ol.payment_status,
        ol.fulfillment_status,
        ol.ordered_at,
        ol.shipped_at,
        ol.delivered_at,
        ol.cancelled_at,
        ol.fraud_score,
        ol.fraud_check_status,
        ol.product_id as line_product_id,
        ol.variant_id as line_variant_id,
        ol.quantity_ordered,
        ol.quantity_returned,
        ol.unit_price,
        ol.discount_amount as line_discount_amount,
        ol.tax_amount as line_tax_amount,
        ol.line_total,
        ol.line_status,
        row_number() over (
            partition by r.review_id
            order by
                case
                    when r.order_id is not null and r.order_id = ol.order_id then 0
                    else 1
                end,
                ol.ordered_at desc nulls last,
                ol.line_number
        ) as match_rank
    from reviews r
    join order_lines_orders ol
        on (
            (r.order_id is not null and r.order_id = ol.order_id and (r.product_id is null or r.product_id = ol.product_id))
            or (r.order_id is null and r.customer_id = ol.customer_id and r.product_id = ol.product_id)
        )
        and (ol.ordered_at <= r.review_ts or r.review_ts is null)
),

best_line as (
    select *
    from review_line_match
    where match_rank = 1
),

reviews_with_orders as (
    select
        r.*,
        coalesce(r.order_id, bl.order_id) as matched_order_id,
        bl.order_line_id,
        coalesce(bl.order_customer_id, r.customer_id) as matched_customer_id,
        coalesce(bl.channel_id, o.channel_id) as channel_id,
        coalesce(bl.order_source, o.order_source) as order_source,
        coalesce(bl.order_type, o.order_type) as order_type,
        coalesce(bl.order_status, o.order_status) as order_status,
        coalesce(bl.payment_status, o.payment_status) as payment_status,
        coalesce(bl.fulfillment_status, o.fulfillment_status) as fulfillment_status,
        coalesce(bl.ordered_at, o.ordered_at) as ordered_at,
        coalesce(bl.shipped_at, o.shipped_at) as shipped_at,
        coalesce(bl.delivered_at, o.delivered_at) as delivered_at,
        coalesce(bl.cancelled_at, o.cancelled_at) as cancelled_at,
        coalesce(bl.fraud_score, o.fraud_score) as fraud_score,
        coalesce(bl.fraud_check_status, o.fraud_check_status) as fraud_check_status,
        bl.quantity_ordered,
        bl.quantity_returned as line_quantity_returned,
        bl.unit_price as line_unit_price,
        bl.line_discount_amount,
        bl.line_tax_amount,
        bl.line_total,
        bl.line_status
    from reviews r
    left join best_line bl on r.review_id = bl.review_id
    left join orders o on o.order_id = r.order_id
),

fraud_scores as (
    select
        order_id,
        score as fraud_score_value,
        risk_level,
        provider,
        reviewed_by as fraud_reviewed_by,
        reviewed_at as fraud_reviewed_at
    from {{ ref('stg_orders__order_fraud_scores') }}
),

returns as (
    select
        return_id,
        order_id,
        status as return_status,
        return_type,
        refund_method,
        refund_amount,
        requested_at,
        received_at,
        processed_at
    from {{ ref('stg_orders__returns') }}
),

return_lines as (
    select
        return_line_id,
        return_id,
        order_line_id,
        quantity_returned,
        reason_id,
        condition,
        refund_amount as return_line_refund
    from {{ ref('stg_orders__return_lines') }}
),

return_lines_enriched as (
    select
        rl.return_line_id,
        rl.return_id,
        rl.order_line_id,
        rl.quantity_returned,
        rl.reason_id,
        rl.condition,
        rl.return_line_refund,
        ol.order_id,
        ol.product_id
    from return_lines rl
    left join order_lines ol on rl.order_line_id = ol.order_line_id
),

returns_by_order as (
    select
        order_id,
        count(distinct return_id) as return_count,
        sum(refund_amount) as total_refund_amount,
        max(return_status) as latest_return_status
    from returns
    group by order_id
),

returns_by_order_product as (
    select
        order_id,
        product_id,
        sum(quantity_returned) as product_return_qty,
        count(distinct return_line_id) as product_return_line_count,
        sum(return_line_refund) as product_return_refund
    from return_lines_enriched
    group by order_id, product_id
),

coupons as (
    select
        order_id,
        count(distinct redemption_id) as coupon_redemption_count,
        {% if target.type == 'snowflake' %}
        sum(TRY_TO_DOUBLE(discount_amount)) as coupon_discount_total
        {% else %}
        sum(try_cast(discount_amount as double)) as coupon_discount_total
        {% endif %}
    from {{ ref('stg_coupon_usage') }}
    group by order_id
),

customers as (
    select
        customer_id,
        email_verified,
        phone_verified,
        status as customer_status,
        churn_risk_tier,
        segment_ml,
        first_order_date,
        last_order_date,
        total_orders,
        total_lifetime_value,
        current_tier_id
    from {{ ref('stg_customer__customers') }}
),

product_ratings as (
    select
        product_id,
        total_reviews,
        average_rating,
        rating_1_count,
        rating_2_count,
        rating_3_count,
        rating_4_count,
        rating_5_count,
        recommend_percentage,
        last_review_date
    from {{ ref('stg_product_ratings_summary') }}
),

events as (
    select
        product_id,
        {% if target.type == 'snowflake' %}
        coalesce(TRY_TO_TIMESTAMP(event_timestamp), cast(created_at as timestamp)) as event_ts
        {% else %}
        coalesce(try_cast(event_timestamp as timestamp), cast(created_at as timestamp)) as event_ts
        {% endif %}
    from {{ ref('stg_events') }}
    where product_id is not null
),

events_daily as (
    select
        product_id,
        cast(event_ts as date) as event_date,
        count(*) as product_event_count
    from events
    where event_ts is not null
    group by product_id, cast(event_ts as date)
),

review_velocity_product as (
    select
        product_id,
        review_date,
        count(*) as product_review_count
    from reviews
    group by product_id, review_date
),

review_velocity_customer as (
    select
        customer_id,
        review_date,
        count(*) as customer_review_count
    from reviews
    group by customer_id, review_date
),

events_7d as (
    select
        r.review_id,
        sum(ed.product_event_count) as product_event_7d_count
    from reviews r
    left join events_daily ed
        on r.product_id = ed.product_id
        {% if target.type == 'snowflake' %}
        and ed.event_date between DATEADD('day', -7, r.review_date) and r.review_date
        {% else %}
        and ed.event_date between r.review_date - interval '7 days' and r.review_date
        {% endif %}
    group by r.review_id
)

select
    rwo.review_id,
    rwo.product_id,
    rwo.variant_id,
    rwo.customer_id,
    rwo.matched_customer_id,
    rwo.matched_order_id as order_id,
    rwo.order_line_id,
    rwo.rating,
    rwo.review_title,
    rwo.review_text,
    rwo.pros,
    rwo.cons,
    rwo.is_verified_purchase,
    rwo.is_recommended,
    rwo.helpful_count,
    rwo.not_helpful_count,
    rwo.status as review_status,
    rwo.moderated_at,
    rwo.moderated_by,
    rwo.rejection_reason,
    rwo.review_source,
    rwo.reviewer_display_name,
    rwo.submitted_at,
    rwo.created_at,
    rwo.updated_at,
    rwo.review_ts,
    rwo.review_date,
    rwo.channel_id,
    rwo.order_source,
    rwo.order_type,
    rwo.order_status,
    rwo.payment_status,
    rwo.fulfillment_status,
    rwo.ordered_at,
    rwo.shipped_at,
    rwo.delivered_at,
    rwo.cancelled_at,
    rwo.fraud_score,
    rwo.fraud_check_status,
    rwo.quantity_ordered,
    rwo.line_quantity_returned,
    rwo.line_unit_price,
    rwo.line_discount_amount,
    rwo.line_tax_amount,
    rwo.line_total,
    rwo.line_status,
    fs.fraud_score_value,
    fs.risk_level as fraud_risk_level,
    fs.provider as fraud_provider,
    fs.fraud_reviewed_by,
    fs.fraud_reviewed_at,
    rbo.return_count,
    rbo.total_refund_amount,
    rbo.latest_return_status,
    rbop.product_return_qty,
    rbop.product_return_line_count,
    rbop.product_return_refund,
    c.coupon_redemption_count,
    c.coupon_discount_total,
    cust.email_verified,
    cust.phone_verified,
    cust.customer_status,
    cust.churn_risk_tier,
    cust.segment_ml,
    cust.first_order_date,
    cust.last_order_date,
    cust.total_orders,
    cust.total_lifetime_value,
    cust.current_tier_id,
    pr.total_reviews as product_total_reviews,
    pr.average_rating as product_average_rating,
    pr.rating_1_count,
    pr.rating_2_count,
    pr.rating_3_count,
    pr.rating_4_count,
    pr.rating_5_count,
    pr.recommend_percentage,
    pr.last_review_date as product_last_review_date,
    e7d.product_event_7d_count,
    vp.product_review_count as product_review_count_day,
    vc.customer_review_count as customer_review_count_day
from reviews_with_orders rwo
left join fraud_scores fs on rwo.matched_order_id = fs.order_id
left join returns_by_order rbo on rwo.matched_order_id = rbo.order_id
left join returns_by_order_product rbop
    on rwo.matched_order_id = rbop.order_id
    and rwo.product_id = rbop.product_id
left join coupons c on rwo.matched_order_id = c.order_id
left join customers cust on rwo.customer_id = cust.customer_id
left join product_ratings pr on rwo.product_id = pr.product_id
left join events_7d e7d on rwo.review_id = e7d.review_id
left join review_velocity_product vp
    on rwo.product_id = vp.product_id
    and rwo.review_date = vp.review_date
left join review_velocity_customer vc
    on rwo.customer_id = vc.customer_id
    and rwo.review_date = vc.review_date
_EOF_

cat > "$DBT_PROJECT_DIR/models/intermediate/reviews/schema.yml" << '_EOF_'
version: 2

models:
  - name: int_reviews__enriched
    description: |
      Review-level enrichment for moderation and trust risk analytics.
      Combines reviews with orders, order lines, fraud scores, returns, coupons,
      customer verification, product rating baselines, and event velocity signals.
    columns:
      - name: review_id
        description: Review identifier
        tests:
          - not_null
      - name: order_id
        description: Matched order identifier for the review
      - name: order_line_id
        description: Matched order line identifier for the review
      - name: product_id
        description: Reviewed product identifier
      - name: customer_id
        description: Reviewer customer identifier
      - name: review_date
        description: Date of review submission
_EOF_

cat > "$DBT_PROJECT_DIR/models/marts/reviews/fct_review_moderation_risk.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['marts', 'reviews', 'trust-risk']
    )
}}

with base as (
    select * from {{ ref('int_reviews__enriched') }}
),

scored as (
    select
        base.*,
        length(base.review_text) as review_text_length,
        DATEDIFF('day', base.ordered_at, base.review_ts) as time_to_review_days,
        DATEDIFF('hour', base.review_ts, base.moderated_at) as moderation_latency_hours,
        base.rating - base.product_average_rating as rating_delta,
        case
            when base.product_average_rating is null then false
            when abs(base.rating - base.product_average_rating) >= 2 then true
            else false
        end as rating_outlier_flag,
        case
            when coalesce(base.coupon_redemption_count, 0) > 0 then true
            else false
        end as coupon_used_flag,
        case
            when coalesce(base.product_return_qty, 0) > 0 or coalesce(base.return_count, 0) > 0 then true
            else false
        end as return_flag,
        case
            when base.fraud_risk_level in ('HIGH', 'CRITICAL') then true
            when base.fraud_check_status = 'FAIL' then true
            else false
        end as fraud_high_flag,
        case
            {% if target.type == 'snowflake' %}
            when UPPER(CAST(base.is_verified_purchase AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then false
            {% else %}
            when base.is_verified_purchase = true then false
            {% endif %}
            else true
        end as unverified_purchase_flag,
        case
            when coalesce(base.customer_review_count_day, 0) >= 3 then true
            else false
        end as customer_velocity_flag,
        case
            when coalesce(base.product_review_count_day, 0) >= 20 then true
            else false
        end as product_velocity_flag,
        case
            when base.review_text is null or length(base.review_text) < 20 then true
            else false
        end as low_content_flag
    from base
),

scored_with_score as (
    select
        scored.*,
        (
            {% if target.type == 'snowflake' %}
            case when unverified_purchase_flag = true then 30 else 0 end
            + case when fraud_high_flag = true then 20 else 0 end
            + case when coupon_used_flag = true then 10 else 0 end
            + case when return_flag = true then 10 else 0 end
            + case when UPPER(CAST(email_verified AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES') AND email_verified IS NOT NULL then 5 else 0 end
            + case when UPPER(CAST(phone_verified AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES') AND phone_verified IS NOT NULL then 5 else 0 end
            + case when low_content_flag = true then 5 else 0 end
            + case when rating_outlier_flag = true then 5 else 0 end
            + case when customer_velocity_flag = true then 5 else 0 end
            + case when product_velocity_flag = true then 5 else 0 end
            {% else %}
            case when unverified_purchase_flag then 30 else 0 end
            + case when fraud_high_flag then 20 else 0 end
            + case when coupon_used_flag then 10 else 0 end
            + case when return_flag then 10 else 0 end
            + case when email_verified = false then 5 else 0 end
            + case when phone_verified = false then 5 else 0 end
            + case when low_content_flag then 5 else 0 end
            + case when rating_outlier_flag then 5 else 0 end
            + case when customer_velocity_flag then 5 else 0 end
            + case when product_velocity_flag then 5 else 0 end
            {% endif %}
            + case when time_to_review_days is not null and time_to_review_days < 1 then 5 else 0 end
            + case when time_to_review_days is not null and time_to_review_days > 365 then 5 else 0 end
        ) as score_deductions,
        greatest(
            0,
            100 - (
                {% if target.type == 'snowflake' %}
                case when unverified_purchase_flag = true then 30 else 0 end
                + case when fraud_high_flag = true then 20 else 0 end
                + case when coupon_used_flag = true then 10 else 0 end
                + case when return_flag = true then 10 else 0 end
                + case when UPPER(CAST(email_verified AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES') AND email_verified IS NOT NULL then 5 else 0 end
                + case when UPPER(CAST(phone_verified AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES') AND phone_verified IS NOT NULL then 5 else 0 end
                + case when low_content_flag = true then 5 else 0 end
                + case when rating_outlier_flag = true then 5 else 0 end
                + case when customer_velocity_flag = true then 5 else 0 end
                + case when product_velocity_flag = true then 5 else 0 end
                {% else %}
                case when unverified_purchase_flag then 30 else 0 end
                + case when fraud_high_flag then 20 else 0 end
                + case when coupon_used_flag then 10 else 0 end
                + case when return_flag then 10 else 0 end
                + case when email_verified = false then 5 else 0 end
                + case when phone_verified = false then 5 else 0 end
                + case when low_content_flag then 5 else 0 end
                + case when rating_outlier_flag then 5 else 0 end
                + case when customer_velocity_flag then 5 else 0 end
                + case when product_velocity_flag then 5 else 0 end
                {% endif %}
                + case when time_to_review_days is not null and time_to_review_days < 1 then 5 else 0 end
                + case when time_to_review_days is not null and time_to_review_days > 365 then 5 else 0 end
            )
        ) as trust_score
    from scored
),

final as (
    select
        scored_with_score.*,
        case
            when trust_score < 50 then 'HIGH'
            when trust_score < 80 then 'MEDIUM'
            else 'LOW'
        end as risk_bucket,
        case
            {% if target.type == 'snowflake' %}
            when fraud_high_flag = true or unverified_purchase_flag = true or coupon_used_flag = true then 'P1'
            when rating_outlier_flag = true or customer_velocity_flag = true or product_velocity_flag = true then 'P2'
            {% else %}
            when fraud_high_flag or unverified_purchase_flag or coupon_used_flag then 'P1'
            when rating_outlier_flag or customer_velocity_flag or product_velocity_flag then 'P2'
            {% endif %}
            else 'P3'
        end as queue_priority
    from scored_with_score
)

select * from final
_EOF_

cat > "$DBT_PROJECT_DIR/models/marts/reviews/rpt_review_moderation_kpis.sql" << '_EOF_'
{{
    config(
        materialized='view',
        tags=['marts', 'reviews', 'trust-risk']
    )
}}

with reviews as (
    select * from {{ ref('fct_review_moderation_risk') }}
)

select
    date_trunc('month', review_date) as review_month,
    channel_id,
    review_source,
    fraud_risk_level,
    risk_bucket,
    coalesce(rejection_reason, 'NONE') as rejection_reason,
    count(*) as review_count,
    {% if target.type == 'snowflake' %}
    sum(case when UPPER(CAST(is_verified_purchase AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then 1 else 0 end) as verified_review_count,
    round(100.0 * sum(case when UPPER(CAST(is_verified_purchase AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES') then 1 else 0 end) / nullif(count(*), 0), 2) as verified_purchase_share,
    {% else %}
    sum(case when is_verified_purchase then 1 else 0 end) as verified_review_count,
    round(100.0 * sum(case when is_verified_purchase then 1 else 0 end) / nullif(count(*), 0), 2) as verified_purchase_share,
    {% endif %}
    avg(time_to_review_days) as avg_time_to_review_days,
    avg(moderation_latency_hours) as avg_moderation_latency_hours,
    {% if target.type == 'snowflake' %}
    sum(case when rating_outlier_flag = true then 1 else 0 end) as rating_outlier_count,
    {% else %}
    sum(case when rating_outlier_flag then 1 else 0 end) as rating_outlier_count,
    {% endif %}
    avg(abs(rating_delta)) as avg_rating_delta,
    {% if target.type == 'snowflake' %}
    sum(case when product_velocity_flag = true then 1 else 0 end) as product_velocity_flag_count,
    sum(case when customer_velocity_flag = true then 1 else 0 end) as customer_velocity_flag_count,
    sum(case when return_flag = true then 1 else 0 end) as reviews_with_returns,
    sum(case when coupon_used_flag = true then 1 else 0 end) as reviews_with_coupons,
    {% else %}
    sum(case when product_velocity_flag then 1 else 0 end) as product_velocity_flag_count,
    sum(case when customer_velocity_flag then 1 else 0 end) as customer_velocity_flag_count,
    sum(case when return_flag then 1 else 0 end) as reviews_with_returns,
    sum(case when coupon_used_flag then 1 else 0 end) as reviews_with_coupons,
    {% endif %}
    avg(trust_score) as avg_trust_score
from reviews
group by
    date_trunc('month', review_date),
    channel_id,
    review_source,
    fraud_risk_level,
    risk_bucket,
    coalesce(rejection_reason, 'NONE')
_EOF_

cat > "$DBT_PROJECT_DIR/models/marts/reviews/schema.yml" << '_EOF_'
version: 2

models:
  - name: fct_review_moderation_risk
    description: |
      Review-level fact table with trust score and risk bucket for moderation.
      Provides time-to-review, moderation latency, and fraud/return/coupon flags.
    columns:
      - name: review_id
        description: Review identifier
        tests:
          - not_null
          - unique
      - name: trust_score
        description: Heuristic trust score (0-100)
      - name: risk_bucket
        description: Risk classification bucket
      - name: queue_priority
        description: Moderation queue priority

  - name: rpt_review_moderation_kpis
    description: |
      Monthly KPI rollup for review moderation and trust risk.
      Includes verified purchase share, time-to-review, rating volatility,
      and rejection reason trends.
    columns:
      - name: review_month
        description: Month of review activity
      - name: verified_purchase_share
        description: Percentage of reviews that are verified purchases
      - name: avg_trust_score
        description: Average trust score for the bucket
_EOF_

cd "$DBT_PROJECT_DIR"

dbt deps

dbt run --select int_reviews__enriched \
    fct_review_moderation_risk \
    rpt_review_moderation_kpis \
    --profiles-dir ./

dbt test --select int_reviews__enriched \
    fct_review_moderation_risk \
    rpt_review_moderation_kpis \
	--profiles-dir ./

echo "Solution complete!"
