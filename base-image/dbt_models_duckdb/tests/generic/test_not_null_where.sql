{% test not_null_where(model, column_name, where) %}

SELECT {{ column_name }}
FROM {{ model }}
WHERE {{ where }}
  AND {{ column_name }} IS NULL

{% endtest %}
