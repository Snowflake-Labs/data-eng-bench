{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'VBAP') }}
),

deduped as (
    select *
    from source
    where order_line_id is not null
    qualify row_number() over (partition by order_line_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
