{{
    config(
        materialized='view',
        tags=['staging', 'sap']
    )
}}

with source as (
    select * from {{ source('sap', 'EKPO') }}
),

deduped as (
    select *
    from source
    where po_line_id is not null
    qualify row_number() over (partition by po_line_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
