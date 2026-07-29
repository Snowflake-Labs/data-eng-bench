{{
    config(
        materialized='view',
        tags=['intermediate', 'union']
    )
}}

/*
    Union model: int_subscriptions_unioned
    Combines data from 2 sources
*/

WITH 
source_1 AS (
    SELECT
        'payments' AS _source_system,
        *
    FROM {{ ref('stg_payments__subscriptions') }}
),
source_2 AS (
    SELECT
        'sfdc' AS _source_system,
        *
    FROM {{ ref('stg_sfdc__subscriptions') }}
),

combined AS (
    SELECT * FROM source_1 UNION ALL SELECT * FROM source_2
)

SELECT * FROM combined
