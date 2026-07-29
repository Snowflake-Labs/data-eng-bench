-- Product Attribute Summary
-- Summarizes product attributes

with product_attributes as (
    select * from {{ ref('stg_product__product_attributes') }}
),

product_attribute_options as (
    select * from {{ ref('stg_product__product_attribute_options') }}
)

select
    pa.attribute_id,
    pa.attribute_code,
    pa.attribute_name,
    pa.attribute_type,
    pa.data_type,
    pa.is_variant_attribute,
    pa.is_filterable,
    count(distinct pao.option_id) as option_count
from product_attributes pa
left join product_attribute_options pao on pa.attribute_id = pao.attribute_id
group by 1, 2, 3, 4, 5, 6, 7
