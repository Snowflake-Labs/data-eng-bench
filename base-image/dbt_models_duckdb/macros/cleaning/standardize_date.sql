{% macro standardize_date(column, formats=['%Y-%m-%d', '%m/%d/%Y', '%d-%b-%Y']) %}
    COALESCE(
        TRY_CAST({{ column }} AS DATE),
        {% for fmt in formats %}
        TRY_STRPTIME({{ column }}, '{{ fmt }}'){% if not loop.last %},{% endif %}
        {% endfor %}
    )
{% endmacro %}
