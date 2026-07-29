{% snapshot customer_snapshot %}

{{
    config(
      target_schema='snapshots',
      unique_key='customer_id',
      strategy='timestamp',
      updated_at='updated_at',
      invalidate_hard_deletes=True
    )
}}

select
    customer_id,
    customer_number,
    customer_type,
    email,
    email_verified,
    phone_primary,
    phone_verified,
    first_name,
    last_name,
    company_name,
    acquisition_source,
    acquisition_campaign,
    current_timestamp as updated_at
from {{ ref('stg_customers') }}
where acquisition_source is not null

{% endsnapshot %}
