{% macro calculate_age(start_date, end_date) %}
DATEDIFF(DAY, {{ start_date }}, {{ end_date }})
{% endmacro %}