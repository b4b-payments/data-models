{% macro delete_reporting_orphans() %}
{% if is_incremental() and var("reporting_run_started_at", "") != "" %}
delete from {{ this }}
where not exists (
    select 1
    from {{ ref('fact_payment') }} f
    where f.payment_sk = {{ this }}.payment_sk
)
{% else %}
select 1
{% endif %}
{% endmacro %}
