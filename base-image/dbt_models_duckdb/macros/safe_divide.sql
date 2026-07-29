
{% macro safe_divide(numerator, denominator) %}
    case
        when {{ denominator }} = 0 then null
        else ({{ numerator }}::decimal / {{ denominator }}::decimal)
    end
{% endmacro %}
