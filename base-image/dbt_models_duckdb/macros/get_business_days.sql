{% macro get_business_days(start_date, end_date) %}
DATEDIFF(DAY, {{ start_date }}, {{ end_date }}) * 5/7
{% endmacro %}