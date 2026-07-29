{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'TRANS_LINES') }}
),

deduped as (
    select *
    from source
    where order_line_id is not null
    qualify row_number() over (partition by order_line_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
