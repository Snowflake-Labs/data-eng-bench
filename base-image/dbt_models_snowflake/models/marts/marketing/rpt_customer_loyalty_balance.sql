{{
    config(
        materialized='table',
        tags=['marketing', 'loyalty', 'customer_facing'],
        meta={
            'owner': 'loyalty-team@company.com',
            'created': '2022-11-08',
            'last_modified': '2024-08-28',
            'sla': 'T+1 7am (feeds member portal)',
            'data_classification': 'internal',
            'downstream_consumers': ['Member Portal', 'Customer Service Dashboard', 'Email Marketing (points expiry)']
        }
    )
}}

{#
    @author: Lisa Wong (Loyalty & Rewards Team)
    @created: 2022-11-08
    @modified: 2024-08-28 by Kevin O'Brien

    == Model Description ==
    Customer Loyalty Points Balance Report - provides current loyalty points
    balance for each customer-program combination. This model description should
    be kept in sync with the schema.yml entry (see missing schema entries below).

    == Business Context ==
    We operate 3 loyalty programs with different point values:
      - Rewards+ (main program): 0.01 USD per point (100 pts = $1)
      - Employee Perks: 0.015 USD per point (100 pts = $1.50)
      - Partner Program: 0.008 USD per point (100 pts = $0.80)

    Points are earned on purchases and can be redeemed for discounts.
    Expiration is handled by a separate process (12-month rolling window).
    Customer Service relies heavily on this for member inquiries.

    == Source Relations ==
    - stg_marketing__loyalty_points_transactions: ~800K transactions, source of
      truth for balance_after (populated by OMS on each transaction)
    - stg_marketing__loyalty_programs: Master list with program metadata and
      points_value conversion rates

    == Business Rules ==
    1. Balance is determined by the balance_after column from the most recent
       transaction per customer-program combination (uses ROW_NUMBER window function)
    2. Negative balances ARE valid - caused by manual CS adjustments (~50 customers)
       Portal clamps display to 0 but we store actual value (DATA-1234)
    3. Customers may have balances in multiple programs (intentional for employees)
    4. Value tier is a simplified classification until proper tier logic ships

    == Environment-Specific Logic ==
    - Production: Full dataset, ~800K source transactions
    - Dev/staging: May use filtered dataset via dbt_project.yml vars
    - points_value rates are stored in source, not hardcoded here

    == Known Data Quality Issues ==
    - ~500 customer_ids don't match dim_customer (migration orphans, DATA-890)
    - balance_after can be negative due to manual adjustments (DATA-1234)
    - Voided transactions still included (balance_after already adjusted)

    == Schema Entries ==
    NOTE: Missing schema entries for this model - needs schema.yml update for:
    - Column descriptions (current_balance, balance_value, value_tier)
    - data_tests for balance_value >= 0 assertion would fail due to negative balances

    == Type Adapters ==
    - balance_value calculated as INTEGER * DECIMAL, returns DECIMAL
    - current_timestamp returns TIMESTAMP for dbt_updated_at

    == Related Models ==
    - rpt_loyalty_program_summary: Aggregated program-level stats
    - rpt_loyalty_points_trend: Time series of point accumulation

    == Performance ==
    - Runtime: ~20 seconds (ROW_NUMBER over 800K rows is bottleneck)
    - Materialized as table for portal API performance (view was too slow)

    TODO: Add points expiring in next 30/60/90 days for email triggers (DATA-1678)
    FIXME: Handle edge case where customer has transactions but no program match
#}

-- =============================================================================
-- CTE SECTION: Related logic grouped by purpose
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Source CTEs: Pull from staging models (single responsibility - data sourcing)
-- -----------------------------------------------------------------------------
WITH loyalty_points_transactions AS (
    -- Source relation: stg_marketing__loyalty_points_transactions
    -- Contains all point earn/redeem/adjust transactions with running balance
    SELECT *
    FROM {{ ref('stg_marketing__loyalty_points_transactions') }}
    -- ~800K rows currently, growing ~15K/month
),

loyalty_programs AS (
    -- Source relation: stg_marketing__loyalty_programs
    -- Master reference for program names and points_value conversion
    SELECT *
    FROM {{ ref('stg_marketing__loyalty_programs') }}
    -- 3 active programs as of 2024
),

-- -----------------------------------------------------------------------------
-- Transformation CTE: Get latest balance using window function
-- Single responsibility: Identify most recent transaction per customer-program
-- -----------------------------------------------------------------------------
latest_balance AS (
    -- ROW_NUMBER for getting latest balance - partitioned by customer-program
    -- Uses correlated window function to rank transactions by recency
    SELECT
        customer_id,
        program_id,
        balance_after,
        created_at AS last_transaction_date,
        -- Window function: ROW_NUMBER to identify latest record
        ROW_NUMBER() OVER (
            PARTITION BY customer_id, program_id
            ORDER BY created_at DESC  -- Most recent transaction first
        ) AS rn
    FROM loyalty_points_transactions
    -- Note: voided transactions included - balance_after already reflects voids

    -- Debug queries (commented out):
    -- SELECT customer_id, COUNT(*) FROM loyalty_points_transactions GROUP BY 1 HAVING COUNT(*) > 100;
    -- SELECT * FROM loyalty_points_transactions WHERE balance_after < 0;
)

-- =============================================================================
-- FINAL SELECT: Assemble output with business logic
-- =============================================================================
SELECT
    -- Key columns
    lb.customer_id,
    lb.program_id,
    lp.program_name,

    -- Points balance (business rule: can be negative per DATA-1234)
    lb.balance_after as current_balance,

    -- Monetary value calculation
    -- Business rule: points_value varies by program (see header docs)
    COALESCE(lb.balance_after * lp.points_value, 0) as balance_value,

    -- Metadata
    lb.last_transaction_date,

    -- Simplified tier (temporary until proper tier logic - DATA-1789)
    -- Business rule: classification based on point thresholds
    CASE
        WHEN lb.balance_after >= 10000 THEN 'High Value'
        WHEN lb.balance_after >= 1000 THEN 'Medium Value'
        WHEN lb.balance_after > 0 THEN 'Low Value'
        ELSE 'Zero/Negative'
    END AS value_tier,

    CURRENT_TIMESTAMP AS dbt_updated_at

FROM latest_balance lb
-- Join conditions formatted for readability
LEFT JOIN loyalty_programs lp
    ON lb.program_id = lp.program_id

-- Filter to latest record only (rn = 1 from window function)
WHERE lb.rn = 1
