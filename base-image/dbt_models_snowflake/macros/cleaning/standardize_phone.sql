{% macro standardize_phone(column) %}
    CASE
        WHEN {{ column }} IS NULL THEN NULL
        WHEN LENGTH(REGEXP_REPLACE({{ column }}, '[^0-9]', '')) = 10 THEN
            '+1' || REGEXP_REPLACE({{ column }}, '[^0-9]', '')
        WHEN LENGTH(REGEXP_REPLACE({{ column }}, '[^0-9]', '')) = 11
             AND REGEXP_REPLACE({{ column }}, '[^0-9]', '') LIKE '1%' THEN
            '+' || REGEXP_REPLACE({{ column }}, '[^0-9]', '')
        ELSE REGEXP_REPLACE({{ column }}, '[^0-9+]', '')
    END
{% endmacro %}
