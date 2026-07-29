/*
================================================================================
HOTFIX: Manual Adjustments for JIRA-2345
================================================================================
Created: 2024-07-15
Purpose: Apply manual corrections for data quality issue JIRA-2345

Issue: SAP sent us 3 months of invoices with wrong currency codes.
Solution: This model applies manual corrections from a spreadsheet.

The spreadsheet was uploaded to a seed file.
The seed file is still here.
The issue was fixed at source 4 months ago.
This model still runs.
================================================================================
*/

{{
    config(
        materialized='view',
        tags=['hotfix', 'manual_correction', 'jira_2345'],
        meta={
            'owner': 'data-eng@company.com',
            'jira_ticket': 'JIRA-2345',
            'issue': 'Wrong currency codes from SAP',
            'correction_source': 'seed_manual_currency_corrections',
            'issue_fixed_at_source': '2024-08-15',
            'can_be_deleted': true
        }
    )
}}

-- This hotfix is no longer needed
-- JIRA-2345 was resolved at source on 2024-08-15
-- Keeping "just in case we need to reference the correction logic"

SELECT
    o.order_id,
    o.order_number,
    o.customer_id,
    o.grand_total,

    -- Original (potentially wrong) currency
    o.currency_code AS original_currency_code,

    -- Corrected currency from manual spreadsheet
    COALESCE(c.corrected_currency_code, o.currency_code) AS currency_code,

    -- Flag if this was manually corrected
    CASE WHEN c.corrected_currency_code IS NOT NULL THEN TRUE ELSE FALSE END AS was_manually_corrected,

    o.ordered_at,
    o._loaded_at

FROM {{ ref('stg_sap__vbak') }} o
LEFT JOIN {{ ref('seed_manual_currency_corrections') }} c
    ON o.order_number = c.order_number
WHERE o.ordered_at BETWEEN '2024-04-01' AND '2024-06-30'  -- affected period
