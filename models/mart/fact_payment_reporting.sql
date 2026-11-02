{{ config(
    alias='fact_payment_reporting',
    tags=['fx', 'payments', 'mart'],
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='payment_sk',
    on_schema_change='append_new_columns',
    dist='payment_sk',
    sort=['date_sk', 'payment_sk'],
    pre_hook=["{{ carry_forward_fx_spine() }}"],
    post_hook=["{{ delete_reporting_orphans() }}"]
) }}

-- One row per payment_sk. Amounts come from spike.fx_rate_spine, equijoined
-- on (currency_sk, date_sk) once per target. The spine already holds the
-- as-of rate, so this model does not join fact_exchange_rate_daily.

with payment as (
    select
        f.payment_sk,
        f.currency_sk,
        f.date_sk,
        cast(f.amount as double precision) as amount_native,
        c.currency_code as source_currency
    from {{ ref('fact_payment') }} f
    left join {{ source('spike_live', 'dim_currency') }} c
        on c.id = f.currency_sk
    {% if is_incremental() %}
    where f.loaded_at >= '{{ var("reporting_run_started_at", "9999-12-31") }}'::timestamp
    {% endif %}
),
gbp as (
    select id as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'GBP'
),
eur as (
    select id as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'EUR'
),
usd as (
    select id as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'USD'
)

select
    p.payment_sk,
    p.date_sk,
    p.currency_sk,
    p.source_currency,
    cast(case when g.rate is not null then p.amount_native * g.rate end as decimal(18, 4)) as amount_gbp,
    cast(case when e.rate is not null then p.amount_native * e.rate end as decimal(18, 4)) as amount_eur,
    cast(case when u.rate is not null then p.amount_native * u.rate end as decimal(18, 4)) as amount_usd,
    (g.rate is not null) as fx_matched_gbp,
    (e.rate is not null) as fx_matched_eur,
    (u.rate is not null) as fx_matched_usd,
    getdate() as loaded_at,
    g.fx_path as fx_path_gbp,
    e.fx_path as fx_path_eur,
    u.fx_path as fx_path_usd,
    g.direct_rate_date as rate_date_gbp,
    e.direct_rate_date as rate_date_eur,
    u.direct_rate_date as rate_date_to_usd,
    g.usd_target_rate_date as rate_date_usd_gbp,
    e.usd_target_rate_date as rate_date_usd_eur,
    cast(null as timestamp) as restated_at
from payment p
cross join gbp gb
cross join eur er
cross join usd us
left join {{ source('spike_fx', 'fx_rate_spine') }} g
    on g.from_currency_sk = p.currency_sk
   and g.date_sk = p.date_sk
   and g.target_currency_sk = gb.currency_sk
left join {{ source('spike_fx', 'fx_rate_spine') }} e
    on e.from_currency_sk = p.currency_sk
   and e.date_sk = p.date_sk
   and e.target_currency_sk = er.currency_sk
left join {{ source('spike_fx', 'fx_rate_spine') }} u
    on u.from_currency_sk = p.currency_sk
   and u.date_sk = p.date_sk
   and u.target_currency_sk = us.currency_sk
