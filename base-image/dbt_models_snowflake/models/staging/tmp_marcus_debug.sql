/*
================================================================================
TEMPORARY DEBUG MODEL - MARCUS
================================================================================
Created: 2024-09-15 during P1 investigation of missing orders
Purpose: Debug why HomeStyle orders weren't showing up

SHOULD HAVE BEEN DELETED but somehow made it into main branch.
Now it runs every night and nobody noticed for 3 months.

Ticket: DATA-3012 - Remove debug models from production
================================================================================
*/

{# DISABLED 2025-01-12: Finally disabled after 4 months in production. DATA-3012. #}
{{
    config(
        materialized='table',
        enabled=false,
        tags=['debug', 'temporary', 'delete_me'],
        meta={
            'owner': 'marcus.chen@company.com',
            'purpose': 'P1 debugging - INC-2024-0915',
            'should_be_deleted': true,
            'disabled_date': '2025-01-12',
            'disabled_reason': 'Cleanup - model was running unnecessarily for 4 months'
        }
    )
}}

-- Marcus: I'm leaving this here temporarily to debug the HomeStyle issue
-- Marcus (3 months later): Oh no, this is still here

SELECT
    'DEBUG_MARKER' AS debug_flag,
    o.*,

    -- Debug columns added during investigation
    LENGTH(order_number) AS order_number_length,
    -- Snowflake conversion: regexp_matches -> REGEXP_LIKE (returns BOOLEAN)
    REGEXP_LIKE(order_number, '^HS-[0-9]{8}$') AS matches_homestyle_pattern,
    CASE
        WHEN order_number LIKE 'HS-%' THEN 'HomeStyle'
        WHEN order_number LIKE 'POS-%' THEN 'POS'
        WHEN order_number LIKE 'SAP-%' THEN 'SAP'
        ELSE 'UNKNOWN'
    END AS detected_source,

    -- These were useful during the incident
    HASH(order_id || customer_id) AS debug_hash,
    CURRENT_TIMESTAMP AS _debug_generated_at

FROM {{ ref('stg_sap__vbak') }} o
WHERE ordered_at >= '2024-09-01'  -- was relevant during incident

-- Leaving the below commented out in case we need it again
-- AND order_number NOT LIKE 'TEST%'
-- AND customer_id IS NOT NULL
