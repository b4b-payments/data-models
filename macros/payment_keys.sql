-- Shared surrogate keys for the thin payment fact.
-- A blank natural key is fnv_hash('~unknown'), one row, not hashed per product.
-- The fact and the dimensions call these macros so the hash cannot drift.

{% macro sk_unknown() -%}
fnv_hash('~unknown')
{%- endmacro %}

{% macro sk_hash_ready(source_sql, value_sql) -%}
case
    when ({{ value_sql }}) is null then {{ sk_unknown() }}
    else fnv_hash(({{ source_sql }}) || '|' || ({{ value_sql }}))
end
{%- endmacro %}

{% macro country_sk(code_sql) -%}
case
    when nullif(upper(trim(cast({{ code_sql }} as varchar))), '') is null then {{ sk_unknown() }}
    else fnv_hash(upper(trim(cast({{ code_sql }} as varchar))))
end
{%- endmacro %}

{% macro profile_sk(direction, sca, is_returned, is_reversed, account_resolved, rail_resolved) -%}
fnv_hash(
    coalesce({{ direction }}, '') || '|' ||
    case when {{ sca }} is true then '1' when {{ sca }} is false then '0' else '' end || '|' ||
    case when {{ is_returned }} then '1' else '0' end || '|' ||
    case when {{ is_reversed }} then '1' else '0' end || '|' ||
    case when {{ account_resolved }} then '1' else '0' end || '|' ||
    case when {{ rail_resolved }} then '1' else '0' end
)
{%- endmacro %}

{% macro json_array_text(json_sql, path_sql, field_sql) -%}
case
    when is_valid_json(json_extract_path_text({{ json_sql }}, {{ path_sql }}))
     and left(json_extract_path_text({{ json_sql }}, {{ path_sql }}), 1) = '['
    then nullif(trim(json_extract_path_text(
        json_extract_array_element_text(json_extract_path_text({{ json_sql }}, {{ path_sql }}), 0),
        {{ field_sql }}
    )), '')
end
{%- endmacro %}

{% macro oversight_error_code(json_sql) -%}
coalesce(
    {{ json_array_text(json_sql, "'payment', 'errors'", "'errorCode'") }},
    {{ json_array_text(json_sql, "'errors'", "'errorCode'") }}
)
{%- endmacro %}

{% macro oversight_error_text(json_sql) -%}
coalesce(
    {{ json_array_text(json_sql, "'payment', 'errors'", "'errorDescription'") }},
    {{ json_array_text(json_sql, "'errors'", "'errorDescription'") }}
)
{%- endmacro %}
