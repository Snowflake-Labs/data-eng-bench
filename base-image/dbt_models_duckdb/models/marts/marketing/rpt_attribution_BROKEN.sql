/*
================================================================================
BROKEN: Marketing Attribution Report
================================================================================
Status: Broken since GA4 migration (2024-03-01)

The UTM parsing logic broke when we switched from UA to GA4.
Marketing team has been using a manual spreadsheet since then.

Fixing this is blocked by:
1. Nobody understands the original logic
2. The original author (Jake) left
3. Marketing adapted to the spreadsheet workflow
4. "If it ain't broke... well, it IS broke, but they adapted"

Ticket: DATA-2234 (assigned, unassigned, reassigned 4 times)
================================================================================
*/

-- Disabled: Known broken model, kept for historical reference
{{
    config(
        enabled=false,
        materialized='table',
        tags=['broken', 'marketing', 'ga4_migration'],
        meta={
            'owner': 'unassigned',
            'status': 'BROKEN',
            'broken_since': '2024-03-01',
            'workaround': 'Marketing uses manual spreadsheet',
            'original_author': 'jake.morrison@company.com (departed)'
        }
    )
}}

-- WARNING: This model produces incorrect results since GA4 migration
-- Marketing knows this and uses a spreadsheet instead
-- We run it anyway because disabling models is scary

SELECT
    DATE_TRUNC('day', event_date) AS attribution_date,

    -- UTM parsing that doesn't work with GA4 format
    SPLIT_PART(utm_source, '_', 1) AS channel,  -- BROKEN: GA4 format is different
    SPLIT_PART(utm_medium, '-', 1) AS medium,   -- BROKEN: returns garbage
    utm_campaign AS campaign,

    COUNT(*) AS sessions,
    SUM(CASE WHEN conversion_flag = 1 THEN 1 ELSE 0 END) AS conversions,
    SUM(conversion_value) AS attributed_revenue,

    -- These calculations are based on broken inputs
    SUM(CASE WHEN conversion_flag = 1 THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS conversion_rate

FROM {{ ref('int_sessions_events_joined') }}
WHERE event_date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY 1, 2, 3, 4
