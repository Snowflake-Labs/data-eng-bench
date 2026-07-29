{% macro qualify_latest(key_columns, order_column='updated_at') %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY {{ key_columns | join(', ') }}
        ORDER BY {{ order_column }} DESC NULLS LAST
    ) = 1
{% endmacro %}
