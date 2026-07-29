{% macro safe_cast(column, to_type, default=none) %}
    COALESCE(
        TRY_CAST({{ column }} AS {{ to_type }}),
        {% if default is not none %}{{ default }}{% else %}NULL{% endif %}
    )
{% endmacro %}
