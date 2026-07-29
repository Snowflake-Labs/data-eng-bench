{% macro dedupe_by_key(relation, key_columns, order_columns) %}
    WITH ranked AS (
        SELECT
            *,
            ROW_NUMBER() OVER (
                PARTITION BY {{ key_columns | join(', ') }}
                ORDER BY {{ order_columns | join(', ') }}
            ) AS _rn
        FROM {{ relation }}
    )
    SELECT * EXCLUDE (_rn)
    FROM ranked
    WHERE _rn = 1
{% endmacro %}
