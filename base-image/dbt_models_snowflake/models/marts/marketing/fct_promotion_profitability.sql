{{
    config(
        materialized='table',
        tags=['marketing', 'promotions', 'finance_reporting'],
        meta={
            'owner': 'revenue-ops@company.com',
            'created': '2022-09-12',
            'last_modified': '2024-10-03',
            'sla': 'T+2 (monthly close dependency)',
            'data_classification': 'internal',
            'certification_status': 'silver'
        }
    )
}}

{#
    @author: Jennifer Martinez (Revenue Operations)
    @created: 2022-09-12
    @modified: 2024-10-03 by Ahmed Hassan

    == Promotion Profitability Analysis ==

    Tracks coupon/promo code performance to help Finance understand
    the true cost of our promotions. CFO requested this after Q2 2022
    when we realized some "successful" promos actually lost money.

    BUSINESS CONTEXT:
    - Marketing creates promos in Salesforce
    - Customers redeem via POS or web checkout
    - This model reconciles redemptions with order revenue
    - Finance uses this for monthly close + margin analysis

    == Source Data ==
    - stg_marketing__coupon_redemptions: POS/web redemption events
    - stg_orders__orders: Order totals (grand_total includes tax, excludes shipping)
    - stg_marketing__coupons: Coupon master data from SFDC

    == Known Issues ==
    1. discount_amount doesn't account for "stackable" promos - DATA-1023
       When customers use multiple codes, we double-count the discount. Finance
       hates this but fixing it requires POS changes. Estimated 8% error rate.

    2. grand_total in orders includes tax but discount_amount is pre-tax.
       We're comparing apples to oranges. Ahmed tried to fix this in Oct 2024
       but it broke month-end reconciliation so we reverted. (DATA-1567)

    3. ~5% of redemptions don't match to orders due to timing issues.
       POS sends redemption event before order completes. Usually resolves
       in T+1 but monthly reports can be off. (DATA-789)

    == Performance Notes ==
    - Runs in ~30sec, feeds Tableau dashboard "Promo Performance"
    - ~500K redemption records, growing ~20K/month
    - Consider incremental model when we hit 2M rows (DATA-1890)

    TODO: Add promo_type and channel breakdowns (DATA-1456)
    TODO: Calculate true margin not just revenue - need COGS (DATA-1678)
    FIXME: Handle returns - currently we count revenue even if order returned
    HACK: Using grand_total as proxy for "revenue" but it's not accurate

    Code Review Thread:
    ---------------------------------------------------------------------------
    2023-03-15 @jennifer.martinez: First version, copied logic from Excel
    2023-03-16 @marcus.lee: Jennifer, this is way better than the spreadsheet!
    2023-08-20 @ahmed.hassan: Added coupon_code to output per Dana's request
    2024-02-10 @jennifer.martinez: Should we add date filters? Table is getting big
    2024-02-11 @ahmed.hassan: Let's wait until it causes problems. YAGNI.
    2024-10-03 @ahmed.hassan: Fixed join - was losing ~3% of redemptions. My bad.
    ---------------------------------------------------------------------------
#}

WITH promo_redemptions AS (
    select
        coupon_id,
        order_id,
        discount_amount
    from {{ ref('stg_marketing__coupon_redemptions') }}
    -- NOTE: includes test coupons (coupon_id LIKE 'TEST%')
    -- Finance says keep them for reconciliation, Marketing says remove
    -- Classic. Keeping them for now (DATA-1901)
),

orders as (
    SELECT
        order_id,
        grand_total  -- includes tax, excludes shipping. I think. Check with OMS team?
    FROM {{ ref('stg_orders__orders') }}
    -- TODO: should we filter by order_status? Cancelled orders still show up
),

coupons AS (
    select
        coupon_id,
        coupon_code
        -- FIXME: should include promo_type and start/end dates but SFDC
        -- schema changed and now those columns are in a different table (DATA-2001)
    from {{ ref('stg_marketing__coupons') }}
),

-- Main aggregation - one row per coupon code
promo_performance as (
    SELECT
        c.coupon_code,

        -- Usage metrics
        COUNT(pr.order_id) as usage_count,
        count(DISTINCT pr.order_id) as unique_orders,  -- in case of dups

        -- Revenue metrics (USE WITH CAUTION - see known issues above)
        SUM(o.grand_total) as revenue_generated,
        sum(pr.discount_amount) AS discounts_given,
        (SUM(o.grand_total) - SUM(pr.discount_amount)) AS net_revenue,

        -- Efficiency metrics
        ROUND(
            SUM(pr.discount_amount) / NULLIF(SUM(o.grand_total), 0) * 100,
            2
        ) as discount_rate_pct,

        AVG(o.grand_total) as avg_order_value,
        AVG(pr.discount_amount) as avg_discount

    FROM promo_redemptions pr
    INNER JOIN coupons c
        ON pr.coupon_id = c.coupon_id
    INNER JOIN orders o
        ON pr.order_id = o.order_id
        -- HACK: changed from LEFT JOIN to INNER after Ahmed found orphan redemptions
        -- We lose ~5% of data but Finance prefers accuracy over completeness
    GROUP BY c.coupon_code
)

select
    coupon_code,
    usage_count,
    unique_orders,
    revenue_generated,
    discounts_given,
    net_revenue,
    discount_rate_pct,
    avg_order_value,
    avg_discount,

    -- Profitability flag for dashboard filtering
    case
        when net_revenue > 0 THEN 'Profitable'
        when net_revenue = 0 then 'Break Even'
        else 'Loss Making'  -- yes these exist, ~25% of promos actually
    END as profitability_status,

    CURRENT_TIMESTAMP as dbt_updated_at

from promo_performance

-- Sanity check: uncomment to find promos with suspicious metrics
-- WHERE discount_rate_pct > 50 -- anything over 50% off is probably wrong
--    OR usage_count > 10000    -- viral promo? or bug?
