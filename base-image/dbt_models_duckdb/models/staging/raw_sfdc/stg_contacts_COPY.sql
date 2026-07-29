-- COPY of stg_contacts.sql made before refactor
-- Created: 2024-09-20
-- Remove after PR #5821 is merged

{{ config(enabled=false) }}

-- Original logic preserved here for reference
select * from {{ ref('stg_contacts') }}
