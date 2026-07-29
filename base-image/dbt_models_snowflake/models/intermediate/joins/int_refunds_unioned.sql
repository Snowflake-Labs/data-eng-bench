{{
    config(
        materialized='view',
        tags=['intermediate', 'union']
    )
}}

/*
    Union model: int_refunds_unioned
    Combines data from 2 sources
*/

WITH
source_1 AS (
    SELECT
        'payments' AS source_origin,
        *
    FROM {{ ref('stg_payments__refunds') }}
),
source_2 AS (
    SELECT
        'pos' AS source_origin,
        *
    FROM {{ ref('stg_pos__refunds') }}
),

combined AS (
    SELECT * FROM source_1 UNION ALL SELECT * FROM source_2
)

SELECT * FROM combined
