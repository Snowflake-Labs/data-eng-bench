
{% macro surrogate_key(field_list) %}
    {{ dbt_utils.surrogate_key(field_list) }}
{% endmacro %}
