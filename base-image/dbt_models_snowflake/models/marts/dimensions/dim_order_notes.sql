{{
    config(
        materialized='table',
        tags=['dimension', 'notes', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_notes') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['note_id']) }} AS notes_key,
        note_id AS notes_id,

        -- Attributes
        order_id,
        note_type,
        note_text,
        is_internal,
        created_by,
        created_at,
        _loaded_at,
        _source_system,
        _batch_id,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE note_id IS NOT NULL
)

SELECT * FROM final
