{{
    config(
        materialized='incremental',
        unique_key='period_start',
        incremental_strategy='append',
        tags=['time_series', 'customers', 'weekly', 'growth_metrics', 'executive_reporting'],
        meta={
            'owner': 'growth-analytics@company.com',
            'created': '2021-05-20',
            'last_modified': '2024-11-18',
            'sla': 'T+1 8am EST',
            'refresh_frequency': 'daily',
            'downstream_consumers': [
                'Executive Dashboard (Monday standup)',
                'Investor Deck (quarterly)',
                'Weekly Growth Meeting',
                'Marketing CAC Calculator',
                'Board Reporting Package'
            ],
            'stakeholders': ['Rachel Kim', 'Tom Martinez', 'Jennifer Liu (CFO)', 'David Chen (VP Growth)'],
            'freshness_tests': 'warn_after: 24 hours, error_after: 48 hours',
            'tier': 'gold',
            'pii_level': 'none'
        }
    )
}}

{#
    ================================================================================
    ts_customers__new_customers_weekly.sql
    Time Series: Weekly New Customer Acquisitions
    ================================================================================

    @author: Rachel Kim (Growth Analytics)
    @created: 2021-05-20
    @modified: 2024-11-18 by Tom Martinez
    @reviewed_by: Priya Sharma (Data Platform)

    == What This Model Does ==

    Counts unique new customers aggregated by the week of their first purchase.
    This is THE growth metric that Jennifer Liu (CFO) looks at every Monday morning
    before the standup. Don't break this one. Seriously.

    == Column Documentation Reference ==

    | Column               | Type      | Description                                    |
    |----------------------|-----------|------------------------------------------------|
    | period_start         | DATE      | Monday of the week (ISO standard, fight me)    |
    | period_end           | DATE      | Sunday ending the week                         |
    | new_customers        | INTEGER   | Count of first-time purchasers this week       |
    | cumulative_customers | INTEGER   | Running total of all customers ever            |
    | wow_change           | INTEGER   | Week-over-week absolute change                 |
    | wow_change_pct       | DECIMAL   | Week-over-week percent change                  |
    | is_partial_week      | BOOLEAN   | True if week has < 7 days of data              |
    | dbt_updated_at       | TIMESTAMP | When this row was last refreshed               |

    == Business Rules ==

    DEFINITION OF "NEW CUSTOMER":
    A customer_id appearing in fct_sales for the FIRST time with a non-cancelled order.
    We use first ORDER date, not account creation date because:
    1. Account creation is unreliable (ghost accounts everywhere)
    2. Finance only counts actual purchasers for revenue recognition
    3. This matches Marketing's CAC calculation (finally got alignment in Q3 2023!)

    THRESHOLDS (configurable via vars):
    - min_customers_per_week: 5 (anything less triggers data quality alert)
    - max_wow_change_pct: 200 (flags anomalies for review)
    - historical_lookback_years: 5 (don't go further back, data is garbage)

    == Date Range ==

    This model covers 2019-01-01 through present day.
    Pre-2019 data exists but has migration gaps from the Oracle->Snowflake->DuckDB saga.
    If you need 2017-2018, talk to Alex Chen. He has "special" queries. I don't ask questions.

    == Known Issues & Gotchas ==

    1. CANCELLED ORDERS: Excluded from first-purchase calculation. If a customer's
       only order was cancelled, they don't count until a real order. ~2% impact.
       Business approved this logic. (DATA-567, signed off by Jennifer Liu)

    2. WEEK START DRAMA: date_trunc('week') uses Monday (ISO 8601). Marketing wanted
       Sunday. We debated this for 3 WEEKS in 2022. ISO won. Created a _SUNDAY variant
       that nobody uses. Whatever. (DATA-789)

    3. WEEK 1 WEIRDNESS: First week of each year shows weird numbers because partial
       week + NYE hangovers + people returning holiday gifts? I honestly don't know.
       XXX: why does this work? We tried fixing it and made it worse. Left it alone.

    4. TEST CUSTOMERS: We filter out TEST% and INTERNAL% customer_ids but honestly
       this should be handled in staging. Added a ticket 18 months ago. Still open.
       TODO 2024-06-15: Remind Tom about DATA-2341 for upstream test customer filter

    == Performance Notes ==

    - Depends on int_customer__first_orders (~800K rows)
    - Changed to incremental in Nov 2024 because Finance wanted 10 years of history
    - Append strategy: we only add new weeks, never update historical
    - Row limit in dev: Use limit 1000 in target.name == 'dev' for faster iteration
    - Production runtime: ~4 seconds on medium warehouse

    TODO 2024-12-01: Tom wants to add a YoY comparison column. David Chen keeps asking.
    TODO 2025-01-15: Marketing attribution breakdown once they finalize their logic
                     (they've been "finalizing" it since 2022, so don't hold your breath)
    FIXME: Week 53 edge case still breaks some years. I give up.

    == Freshness Tests ==

    Configured in schema.yml:
    - warn_after: {count: 24, period: hour}
    - error_after: {count: 48, period: hour}

    If this goes stale, page the on-call. Jennifer WILL notice.

    == Code Review History ==
    ---------------------------------------------------------------------------
    2021-05-20 @rachel.kim: Initial model. Wrote this at 2am before board meeting.
    2021-08-10 @rachel.kim: Added is_cancelled filter. Finance was not happy.
    2022-01-15 @alex.chen: Sunday weeks PR rejected. Sorry Marketing.
    2023-03-20 @tom.martinez: Converted to view. "It's fast enough" - famous last words
    2023-11-08 @priya.sharma: Added dbt_updated_at. Basic hygiene.
    2024-07-15 @tom.martinez: Fixed typo in comment. Took 3 years to notice lol
    2024-11-18 @tom.martinez: Converted back to incremental. Finance wants ALL history.
                              I wrote this in 20 minutes and it somehow works. Don't touch it.
    ---------------------------------------------------------------------------
#}

-- ============================================================================
-- CTEs
-- ============================================================================

{% if is_incremental() %}
-- Early filtering pattern: only process weeks after our last run
-- This is why incremental models exist. Thank you dbt gods.
{% set max_period_query %}
    SELECT MAX(period_start) FROM {{ this }}
{% endset %}
{% endif %}

WITH all_days AS (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="CAST('2019-01-01' AS DATE)",
        end_date="CAST(CURRENT_DATE + INTERVAL '1 day' AS DATE)"
    ) }}
),

date_spine AS (
    SELECT DATE_TRUNC('week', date_day) AS week_start
    FROM all_days
    GROUP BY DATE_TRUNC('week', date_day)
),

first_orders AS (
    -- Refs intermediate model per marts pattern (not staging directly)
    -- See int_customers__lifetime_metrics for the actual first-order logic
    SELECT
        customer_id,
        first_order_date
    FROM {{ ref('int_customers__lifetime_metrics') }}
    WHERE first_order_date IS NOT NULL
        -- HACK: Filter test customers here because staging doesn't do it consistently
        -- I've complained about this in like 5 different tickets
        AND customer_id NOT LIKE 'TEST%'
        AND customer_id NOT LIKE 'INTERNAL%'
        -- Early filtering: only look at recent data in dev
        {% if target.name == 'dev' %}
        AND first_order_date >= CURRENT_DATE - INTERVAL '90 days'
        -- Row limit for dev mentioned: see limit clause below too
        {% endif %}
    {% if is_incremental() %}
        -- Append strategy: only process new weeks
        AND first_order_date > (SELECT MAX(period_start) FROM {{ this }})
    {% endif %}
),

weekly_new_customers AS (
    -- Aggregate new customers by week
    -- Using Monday week start because ISO 8601 and also because I'm tired of arguing
    SELECT
        DATE_TRUNC('week', first_order_date) AS period_start,
        COUNT(DISTINCT customer_id) AS new_customers
    FROM first_orders
    GROUP BY DATE_TRUNC('week', first_order_date)
),

-- Self-deprecating humor: I wrote this join at 11pm and it works.
-- I don't know why we need the date spine since we already have dates from first_orders.
-- But removing it broke something once so here it stays. Classic.
weekly_with_zeros AS (
    -- Join with date spine to fill in weeks with zero new customers
    -- (This has never happened in production but "just in case" - Rachel 2021)
    SELECT
        ds.week_start AS period_start,
        COALESCE(wnc.new_customers, 0) AS new_customers
    FROM date_spine ds
    LEFT JOIN weekly_new_customers wnc
        ON ds.week_start = wnc.period_start
    WHERE ds.week_start <= CURRENT_DATE
)

-- ============================================================================
-- Final SELECT
-- ============================================================================

SELECT
    period_start,

    -- Period end is always 6 days after start (Sunday)
    -- Someone asked for this in a dashboard once. Stakeholder: David Chen (VP Growth)
    period_start + INTERVAL '6 days' AS period_end,

    new_customers,

    -- Cumulative total for growth charts
    -- Jennifer Liu specifically requested this for the investor deck
    SUM(new_customers) OVER (
        ORDER BY period_start
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_customers,

    -- Week-over-week change metrics
    -- XXX: why does this work with incremental? Shouldn't the window function break?
    -- Tested it, seems fine. Moving on.
    new_customers - LAG(new_customers, 1) OVER (ORDER BY period_start) AS wow_change,

    ROUND(
        100.0 * (new_customers - LAG(new_customers, 1) OVER (ORDER BY period_start))
        / NULLIF(LAG(new_customers, 1) OVER (ORDER BY period_start), 0),
        1
    ) AS wow_change_pct,

    -- Partial week flag for week 1 and current week
    -- Thresholds configurable: if we have less than 7 days of data, flag it
    CASE
        WHEN period_start + INTERVAL '6 days' > CURRENT_DATE THEN TRUE
        WHEN EXTRACT(WEEK FROM period_start) = 1
             AND EXTRACT(DAY FROM period_start) > 1 THEN TRUE
        ELSE FALSE
    END AS is_partial_week,

    -- Audit column for freshness monitoring
    CURRENT_TIMESTAMP AS dbt_updated_at

FROM weekly_with_zeros
WHERE period_start >= '2019-01-01'  -- Historical cutoff, see Known Issues
ORDER BY period_start

{% if target.name == 'dev' %}
-- Row limit for dev: don't need full history when iterating
LIMIT 1000
{% endif %}

-- ============================================================================
-- Debug Queries (uncomment as needed)
-- ============================================================================
-- SELECT * FROM weekly_with_zeros WHERE new_customers = 0
-- ^ Should be empty. If not, we have data gaps.

-- SELECT period_start, new_customers FROM weekly_with_zeros
-- WHERE new_customers < {{ var('min_customers_per_week', 5) }}
-- ^ If any week has fewer than threshold, investigate
