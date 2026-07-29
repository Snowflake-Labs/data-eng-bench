{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'TCURC') }}
),

deduped as (
    select *
    from source
    where _batch_id is not null
    qualify row_number() over (partition by _batch_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
