{% test valid_foreign_key(model, column_name, to, field) %}

SELECT {{ column_name }}
FROM {{ model }}
WHERE {{ column_name }} IS NOT NULL
  AND {{ column_name }} NOT IN (
    SELECT {{ field }} FROM {{ ref(to) }}
  )

{% endtest %}
