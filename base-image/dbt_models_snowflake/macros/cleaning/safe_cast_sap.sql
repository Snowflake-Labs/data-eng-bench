/*
================================================================================
safe_cast_sap - Handle SAP's "Creative" Data Formats
================================================================================
SAP data is... special. This macro handles the garbage we receive.

THINGS SAP HAS SENT US:
- Dates as 'YYYYMMDD', '00000000', '99999999', '' (empty string)
- Numbers as '1.234,56' (German format), '1,234.56', '1234.56-' (trailing negative)
- Booleans as 'X', '', 'x', ' ', '1', '0', 'Y', 'N', 'J', 'JA', 'NEIN'
- NULLs as '', ' ', 'NULL', '#NULL#', '(null)', '-'
- Unicode control characters in text fields
- Leading/trailing whitespace everywhere
- Field values that are just... wrong

This macro tries to make sense of it all. Good luck.

HISTORY:
- 2022-01-01: Initial version (naive)
- 2022-03-15: Added German number format handling after invoice amounts were 100x off
- 2022-06-01: Added date edge cases after '00000000' broke reports
- 2023-01-10: Added boolean handling for German SAP instances
- 2023-04-15: Added trailing negative handling after revenue was negative
- 2023-09-01: Added unicode cleanup after control chars broke JSON exports
- 2024-02-01: Added NULL variant handling (6th type discovered)
- 2024-06-15: Performance optimization - regex was too slow

Code Review Comments:
- Jake (2022-01-01): "Why don't we just fix this at the source?"
- Everyone: *laughs*
- Jake (2022-01-02): "Oh, I see."
================================================================================
*/

{# Main safe_cast_sap macro with type-specific handling #}
{% macro safe_cast_sap(column, to_type, default=none, sap_source=none) %}

{% set type_lower = to_type | lower %}

{% if type_lower in ['date', 'timestamp'] %}
    {{ safe_cast_sap_date(column, to_type, default) }}

{% elif type_lower in ['number', 'numeric', 'decimal', 'float', 'integer', 'int'] %}
    {{ safe_cast_sap_number(column, to_type, default) }}

{% elif type_lower in ['boolean', 'bool'] %}
    {{ safe_cast_sap_boolean(column, default) }}

{% elif type_lower in ['string', 'varchar', 'text'] %}
    {{ safe_cast_sap_string(column) }}

{% else %}
    {# Fallback to standard safe_cast #}
    COALESCE(TRY_CAST({{ column }} AS {{ to_type }}), {{ default if default is not none else 'NULL' }})
{% endif %}

{% endmacro %}


{#
================================================================================
DATE HANDLING
SAP sends: YYYYMMDD, 00000000, 99999999, empty string
================================================================================
#}
{% macro safe_cast_sap_date(column, to_type='DATE', default=none) %}
CASE
    -- Empty or whitespace
    WHEN TRIM(COALESCE({{ column }}::VARCHAR, '')) = '' THEN {{ default if default is not none else 'NULL' }}

    -- SAP's "null date" values
    WHEN {{ column }}::VARCHAR IN ('00000000', '99999999', '00010101', '99991231') THEN {{ default if default is not none else 'NULL' }}

    -- Standard YYYYMMDD format (most common from SAP)
    WHEN REGEXP_LIKE({{ column }}::VARCHAR, '^[0-9]{8}$') THEN
        TRY_TO_DATE({{ column }}::VARCHAR, 'YYYYMMDD')

    -- ISO format YYYY-MM-DD (sometimes SAP cooperates)
    WHEN REGEXP_LIKE({{ column }}::VARCHAR, '^[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN
        TRY_TO_DATE(SUBSTRING({{ column }}::VARCHAR, 1, 10), 'YYYY-MM-DD')

    -- German format DD.MM.YYYY
    WHEN REGEXP_LIKE({{ column }}::VARCHAR, '^[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}$') THEN
        TRY_TO_DATE({{ column }}::VARCHAR, 'DD.MM.YYYY')

    -- US format MM/DD/YYYY
    WHEN REGEXP_LIKE({{ column }}::VARCHAR, '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') THEN
        TRY_TO_DATE({{ column }}::VARCHAR, 'MM/DD/YYYY')

    -- Fallback: try automatic parsing
    ELSE TRY_TO_DATE({{ column }}::VARCHAR)
END
{% endmacro %}


{#
================================================================================
NUMBER HANDLING
SAP sends: German format (1.234,56), trailing negative (1234.56-), mixed
================================================================================
#}
{% macro safe_cast_sap_number(column, to_type='DECIMAL(18,2)', default=none) %}
CASE
    -- Empty or whitespace
    WHEN TRIM(COALESCE({{ column }}::VARCHAR, '')) = '' THEN {{ default if default is not none else 'NULL' }}

    -- SAP null representations
    WHEN {{ column }}::VARCHAR IN ('-', '*', '#', 'NULL', '#NULL#', '(null)') THEN {{ default if default is not none else 'NULL' }}

    -- German format: 1.234,56 -> 1234.56
    -- Detect by: has comma AND no decimal point after comma
    WHEN {{ column }}::VARCHAR LIKE '%,%'
         AND NOT {{ column }}::VARCHAR LIKE '%,%.'
         AND POSITION(',' IN {{ column }}::VARCHAR) > POSITION('.' IN {{ column }}::VARCHAR) THEN
        TRY_CAST(
            REPLACE(REPLACE({{ column }}::VARCHAR, '.', ''), ',', '.')
            AS {{ to_type }}
        )

    -- Trailing negative: 1234.56- -> -1234.56
    WHEN {{ column }}::VARCHAR LIKE '%-' AND NOT {{ column }}::VARCHAR LIKE '-%' THEN
        TRY_CAST(
            '-' || REPLACE({{ column }}::VARCHAR, '-', '')
            AS {{ to_type }}
        )

    -- Leading negative with spaces: - 1234.56 -> -1234.56
    WHEN {{ column }}::VARCHAR LIKE '- %' THEN
        TRY_CAST(
            REPLACE({{ column }}::VARCHAR, '- ', '-')
            AS {{ to_type }}
        )

    -- Standard format (hopefully)
    ELSE TRY_CAST({{ column }} AS {{ to_type }})
END
{% endmacro %}


{#
================================================================================
BOOLEAN HANDLING
SAP sends: X, '', x, 1, 0, Y, N, J, JA, NEIN, and probably more
================================================================================
#}
{% macro safe_cast_sap_boolean(column, default=false) %}
CASE
    -- Truthy values (SAP edition)
    WHEN UPPER(TRIM(COALESCE({{ column }}::VARCHAR, ''))) IN (
        'X', '1', 'Y', 'YES', 'TRUE', 'T',
        'J', 'JA',           -- German
        'S', 'SI',           -- Spanish/Italian
        'O', 'OUI'           -- French
    ) THEN TRUE

    -- Falsey values (SAP edition)
    WHEN UPPER(TRIM(COALESCE({{ column }}::VARCHAR, ''))) IN (
        '', ' ', '0', 'N', 'NO', 'FALSE', 'F',
        'NEIN',              -- German
        'NON'                -- French
    ) THEN FALSE

    -- NULL
    WHEN {{ column }} IS NULL THEN {{ default }}

    -- Unknown value - default to false but log warning
    -- (In practice, this should trigger a data quality flag)
    ELSE {{ default }}
END
{% endmacro %}


{#
================================================================================
STRING HANDLING
Clean up SAP's text fields: trim, remove control chars, handle nulls
================================================================================
#}
{% macro safe_cast_sap_string(column) %}
CASE
    -- Actual NULL
    WHEN {{ column }} IS NULL THEN NULL

    -- SAP null representations
    WHEN TRIM({{ column }}::VARCHAR) IN ('', '-', '*', '#', 'NULL', '#NULL#', '(null)', '#') THEN NULL

    -- Clean the string: trim and remove control characters
    ELSE
        TRIM(
            REGEXP_REPLACE(
                {{ column }}::VARCHAR,
                '[\\x00-\\x1F\\x7F]',  -- Remove control characters
                ''
            )
        )
END
{% endmacro %}


{#
================================================================================
CONVENIENCE MACROS FOR COMMON SAP TABLES
================================================================================
#}

{# SAP Material (MARA) fields #}
{% macro safe_cast_mara_field(column, field_name) %}
{% if field_name in ['ERSDA', 'LAEDA'] %}
    {{ safe_cast_sap_date(column) }}
{% elif field_name in ['BRGEW', 'NTGEW', 'VOLUM'] %}
    {{ safe_cast_sap_number(column, 'DECIMAL(15,3)') }}
{% elif field_name in ['LVORM', 'MTPOS_MARA'] %}
    {{ safe_cast_sap_boolean(column) }}
{% else %}
    {{ safe_cast_sap_string(column) }}
{% endif %}
{% endmacro %}

{# SAP Order (VBAK) fields #}
{% macro safe_cast_vbak_field(column, field_name) %}
{% if field_name in ['ERDAT', 'AEDAT', 'VDATU', 'BSTDK'] %}
    {{ safe_cast_sap_date(column) }}
{% elif field_name in ['NETWR', 'WAERK', 'KNUMV'] %}
    {{ safe_cast_sap_number(column, 'DECIMAL(18,2)') }}
{% else %}
    {{ safe_cast_sap_string(column) }}
{% endif %}
{% endmacro %}
