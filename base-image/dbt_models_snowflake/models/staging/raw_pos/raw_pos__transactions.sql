{{
    config(
        materialized='view',
        tags=['staging', 'pos']
    )
}}

with source as (
    select * from {{ source('pos', 'TRANSACTIONS') }}
),

deduped as (
    select
        order_id,
        _loaded_at
        -- Note: Additional columns should be explicitly listed here
        -- DuckDB EXCLUDE syntax converted to explicit column selection
    from (
        select *,
            row_number() over (partition by order_id order by _loaded_at desc NULLS LAST) as _rn
        from source
        where order_id is not null
    )
    qualify row_number() over (partition by order_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
