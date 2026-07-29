{% macro get_fiscal_quarter(date_column) %}
EXTRACT(QUARTER FROM {{ date_column }})
{% endmacro %}