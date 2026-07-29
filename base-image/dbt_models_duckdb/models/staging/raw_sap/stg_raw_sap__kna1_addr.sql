with source as (
    select * from {{ source('raw_sap', 'kna1_addr') }}
),

renamed as (
    select
        address_id as address_id,
        customer_id as customer_id,
        address_type as address_type,
        address_label as address_label,
        is_default_billing as is_default_billing,
        is_default_shipping as is_default_shipping,
        recipient_name as recipient_name,
        company_name as company_name,
        address_line_1 as address_line_1,
        address_line_2 as address_line_2,
        address_line_3 as address_line_3,
        city as city,
        state_province as state_province,
        postal_code as postal_code,
        country_code as country_code,
        phone as phone,
        delivery_instructions as delivery_instructions,
        latitude as latitude,
        longitude as longitude,
        is_verified as is_verified,
        verified_at as verified_at,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
