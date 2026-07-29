/*
================================================================================
DRAFT: Revenue Recognition Model
================================================================================
Status: Never completed, never used, never deleted

Started by: Finance requested this in Q1 2024
Progress: ~30% complete
Blocked by: Unclear ASC 606 requirements from accounting

This is a classic "we'll finish it later" model that became permanent.
================================================================================
*/

{{
    config(
        materialized='view',
        enabled=false,
        tags=['draft', 'incomplete', 'finance'],
        meta={
            'owner': 'finance-analytics@company.com',
            'status': 'DRAFT - 30% complete',
            'blocked_by': 'ASC 606 requirements unclear',
            'requested_by': 'CFO (Q1 2024)',
            'last_touched': '2024-02-15'
        }
    )
}}

-- TODO: Complete this when accounting provides ASC 606 requirements
-- TODO: Add subscription revenue logic
-- TODO: Handle multi-element arrangements
-- TODO: Deferred revenue calculation

SELECT
    order_id,
    order_date,
    line_total AS gross_revenue,

    -- Placeholder revenue recognition logic
    -- This is definitely wrong, placeholder only
    CASE
        WHEN order_status = 'DELIVERED' THEN line_total
        WHEN order_status = 'SHIPPED' THEN line_total * 0.5  -- ???
        ELSE 0
    END AS recognized_revenue,

    line_total - recognized_revenue AS deferred_revenue,

    'DRAFT_LOGIC' AS _warning

FROM {{ ref('fct_sales') }}
LIMIT 1000  -- limited to prevent full scan on draft model
