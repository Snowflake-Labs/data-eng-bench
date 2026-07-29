{% macro get_fiscal_year(date_column) %}
EXTRACT(YEAR FROM {{ date_column }})
{% endmacro %}