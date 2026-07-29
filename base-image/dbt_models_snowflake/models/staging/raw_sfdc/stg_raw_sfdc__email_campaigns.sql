-- stg_raw_sfdc__email_campaigns
-- Email campaign metadata from Salesforce Marketing Cloud
--
-- WARNING: This model looks empty because it's a placeholder!
-- The actual fields were never mapped when SFDC was integrated.
-- Nobody uses this model but we're afraid to delete it.
-- TODO: Actually implement this or remove it. It's been like this since 2023.

with source as (
    select * from {{ source('raw_sfdc', 'email_campaigns') }}
    -- FIXME: Only has metadata columns, no actual campaign data
),

renamed as (
    select
        _id as _id,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _source_table as _source_table,
        _row_hash as _row_hash
    from source
)

select * from renamed
