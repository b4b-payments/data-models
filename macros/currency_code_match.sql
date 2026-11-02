{# GPS often ships ISO numeric (826); portal sources ship ISO alpha (GBP). #}
{% macro currency_code_match(dim_alias, code_sql) -%}
(
    {{ dim_alias }}.iso_currency_code = {{ code_sql }}
    or {{ dim_alias }}.currency_code = {{ code_sql }}
    or {{ dim_alias }}.numeric_code = {{ code_sql }}
)
{%- endmacro %}
