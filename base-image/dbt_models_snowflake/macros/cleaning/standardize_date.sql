{% macro standardize_date(column, formats=['YYYY-MM-DD', 'MM/DD/YYYY', 'DD-MON-YYYY']) %}
    COALESCE(
        {% for fmt in formats %}
        TRY_TO_TIMESTAMP({{ column }}, '{{ fmt }}'){% if not loop.last %},{% endif %}
        {% endfor %}
    )
{% endmacro %}
