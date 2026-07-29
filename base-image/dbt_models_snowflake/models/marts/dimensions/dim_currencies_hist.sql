{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_currencies_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['_batch_id']) }} AS hist_key,
        _batch_id AS hist_id,

        -- Attributes
        currency_name,
        currency_symbol,
        decimal_places,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE _batch_id IS NOT NULL
)

SELECT * FROM final
