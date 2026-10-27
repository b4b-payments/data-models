{#
  Default dbt behaviour concatenates target.schema + custom schema
  → spike + spike = spike_spike.

  We always land models in the configured custom schema (spike), or
  target.schema when no custom schema is set.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
