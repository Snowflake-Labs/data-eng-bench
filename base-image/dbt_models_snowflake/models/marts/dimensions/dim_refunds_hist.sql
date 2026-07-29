{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_refunds_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['_id']) }} AS hist_key,
        _id AS hist_id,

        -- Attributes
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash,
        _archived_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE _id IS NOT NULL
)

SELECT * FROM final
