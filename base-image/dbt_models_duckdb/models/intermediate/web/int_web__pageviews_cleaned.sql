{{
    config(
        materialized='view',
        tags=['intermediate', 'web', 'ga4', 'high_volume'],
        meta={
            'owner': 'digital-analytics@company.com',
            'sla': '7:00am UTC',
            'estimated_runtime_minutes': 4,
            'snowflake_warehouse': 'TRANSFORM_M',
            'data_source': 'Google Analytics 4',
            'volume': 'high (~50M rows/day)',
            'ga4_migration_date': '2024-03-01',
            'bot_filtering': 'applied in staging'
        }
    )
}}

/*
================================================================================
Intermediate model: int_web__pageviews_cleaned
Domain: web
Source: Google Analytics 4 (via BigQuery export)
================================================================================

Cleaned pageview data from GA4. This model was migrated from GA3/UA
in March 2024. The schema changed significantly.

MIGRATION NOTES (GA3 -> GA4):
- Event-based model vs session-based
- Different field names and structures
- Some historical data gaps during migration window

Code Review Comments (preserved for context):
- Sarah (2024-03-01): "GA4 migration complete. Watch for data gaps."
- Marcus (2024-03-05): "Seeing ~15% fewer pageviews than GA3"
- Digital Team (2024-03-05): "Expected. GA4 counts differently."
- Jake (2024-06-15): "Can we add scroll depth?"
- Sarah (2024-06-15): "Need GA4 enhanced measurement enabled first"
================================================================================
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_ga__pageviews') }}

),

cleaned AS (

    SELECT
        _id,
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
