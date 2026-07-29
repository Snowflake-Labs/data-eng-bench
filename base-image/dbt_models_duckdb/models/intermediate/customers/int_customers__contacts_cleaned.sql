{{
    config(
        materialized='view',
        tags=['intermediate', 'customers', 'sfdc', 'pii'],
        meta={
            'owner': 'customer-data@company.com',
            'sla': '5:00am UTC',
            'estimated_runtime_minutes': 2,
            'snowflake_warehouse': 'TRANSFORM_S',
            'contains_pii': true,
            'gdpr_relevant': true,
            'data_classification': 'confidential',
            'retention_days': 2555,
            'masking_policy': 'pii_email_mask'
        }
    )
}}

/*
================================================================================
Intermediate model: int_customers__contacts_cleaned
Domain: customers
Source: Salesforce Contacts
================================================================================

Cleaned contact information (email, phone, etc.) for customer dimension.

IMPORTANT: This model contains PII!
- contact_value may contain email addresses, phone numbers
- Apply appropriate masking in downstream BI tools
- Subject to GDPR data retention requirements

Code Review Comments (preserved for context):
- Legal (2023-09-01): "Need data retention policy applied"
- Sarah (2023-09-01): "Added retention_days=2555 (7 years per finance policy)"
- Marcus (2024-02-15): "is_verified logic seems wrong for phone numbers"
- Sarah (2024-02-15): "SFDC sends verified_at=NULL for phones, that's expected"
================================================================================
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sfdc__contacts') }}

),

cleaned AS (

    SELECT
        contact_id,
        customer_id,
        contact_type,
        contact_subtype,
        contact_value,
        is_primary,
        is_verified,
        verified_at,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
