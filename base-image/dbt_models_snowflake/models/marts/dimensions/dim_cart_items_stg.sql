{{
    config(
        materialized='table',
        tags=['dimension', 'stg', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_cart_items_stg') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['_id']) }} AS stg_key,
        _id AS stg_id,

        -- Attributes
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash,
        _status,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE _id IS NOT NULL
)

SELECT * FROM final
