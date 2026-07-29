{% test accepted_range(model, column_name, min_value=none, max_value=none) %}

SELECT {{ column_name }}
FROM {{ model }}
WHERE {{ column_name }} IS NOT NULL
  {% if min_value is not none %}AND {{ column_name }} < {{ min_value }}{% endif %}
  {% if max_value is not none %}OR {{ column_name }} > {{ max_value }}{% endif %}

{% endtest %}
