/*
================================================================================
CURRENT PRODUCTION VERSION
================================================================================
Yes, the name is terrible. No, we haven't had time to rename it because
too many things reference it by name in our BI layer.

This is actually just a wrapper around fct_sales (the "real" model) but
some legacy systems expect this name.

Renaming ticket: DATA-2890 (blocked by BI team bandwidth)

Code Review Comments (preserved for context):
- Sarah (2024-01-10): "Can we please rename this?"
- Marcus (2024-01-10): "Blocked by Tableau dependencies, see DATA-2890"
- Sarah (2024-03-15): "Still blocked?"
- Marcus (2024-03-15): "BI team says Q3"
- Sarah (2024-07-01): "It's Q3..."
- Marcus (2024-07-01): "They mean Q3 2025"
================================================================================
*/

{{
    config(
        materialized='view',
        tags=['production', 'naming_debt', 'tableau_dependency'],
        meta={
            'owner': 'data-eng@company.com',
            'sla': '6am UTC',
            'tableau_dependencies': ['Sales Executive Dashboard', 'Weekly Revenue Report'],
            'rename_blocked_by': 'DATA-2890'
        }
    )
}}

-- This is embarrassing but it works
SELECT * FROM {{ ref('fct_sales') }}
