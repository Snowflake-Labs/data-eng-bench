{% macro add_dq_flags(required_columns=[]) %}
    -- Data Quality Flags
    CASE
        WHEN {% for col in required_columns %}{{ col }} IS NULL{% if not loop.last %} OR {% endif %}{% endfor %}
        THEN FALSE
        ELSE TRUE
    END AS dq_is_valid,

    CASE
        WHEN {% for col in required_columns %}{{ col }} IS NULL{% if not loop.last %} OR {% endif %}{% endfor %}
        THEN TRUE
        ELSE FALSE
    END AS dq_missing_required,

    FALSE AS dq_format_corrected,
    FALSE AS dq_duplicate_suspected,
    FALSE AS dq_late_arriving
{% endmacro %}
