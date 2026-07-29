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
    select * exclude (_rn)
    from (
        select *,
            row_number() over (partition by order_line_id order by _loaded_at desc) as _rn
        from source
        where order_line_id is not null
    )
    where _rn = 1
)

select * from deduped
