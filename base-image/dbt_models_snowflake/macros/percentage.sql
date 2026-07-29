
{% macro percentage(part, whole) %}
    case
        when {{ whole }} = 0 then 0
        else (({{ part }}::decimal / {{ whole }}::decimal) * 100)::decimal(10,2)
    end
{% endmacro %}
