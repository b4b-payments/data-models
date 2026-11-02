{% macro carry_forward_fx_spine() %}
{% if var("reporting_run_started_at", "") != "" %}
insert into {{ source('spike_fx', 'fx_rate_spine') }} (
    from_currency_sk,
    target_currency_sk,
    date_sk,
    rate,
    fx_path,
    direct_rate_date,
    usd_leg_rate_date,
    usd_target_rate_date,
    loaded_at
)
select
    from_currency_sk,
    target_currency_sk,
    date_sk,
    rate,
    fx_path,
    direct_rate_date,
    usd_leg_rate_date,
    usd_target_rate_date,
    getdate()
from (
    select
        need.from_currency_sk,
        need.target_currency_sk,
        need.date_sk,
        earlier.rate,
        earlier.fx_path,
        earlier.direct_rate_date,
        earlier.usd_leg_rate_date,
        earlier.usd_target_rate_date,
        row_number() over (
            partition by need.from_currency_sk, need.target_currency_sk, need.date_sk
            order by earlier.date_sk desc
        ) as rn
    from (
        select distinct f.currency_sk as from_currency_sk, t.id as target_currency_sk, f.date_sk
        from {{ ref('fact_payment') }} f
        join {{ source('spike_live', 'dim_currency') }} t
          on t.currency_code in ('GBP', 'EUR', 'USD')
        where f.loaded_at >= '{{ var("reporting_run_started_at") }}'::timestamp
          and f.currency_sk is not null
          and f.date_sk is not null
    ) need
    left join {{ source('spike_fx', 'fx_rate_spine') }} have
      on have.from_currency_sk = need.from_currency_sk
     and have.target_currency_sk = need.target_currency_sk
     and have.date_sk = need.date_sk
    join {{ source('spike_fx', 'fx_rate_spine') }} earlier
      on earlier.from_currency_sk = need.from_currency_sk
     and earlier.target_currency_sk = need.target_currency_sk
     and earlier.date_sk < need.date_sk
    where have.date_sk is null
) ranked
where rn = 1
{% else %}
select 1
{% endif %}
{% endmacro %}
