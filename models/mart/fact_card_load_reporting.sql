{{ config(
    alias='fact_card_load_reporting',
    tags=['fx', 'cards', 'mart'],
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='load_sk',
    on_schema_change='append_new_columns',
    dist='load_sk',
    sort=['date_sk', 'load_sk'],
    pre_hook=["{{ carry_forward_fx_spine_cards() }}"],
) }}

-- Slim as-of FX companion for fact_card_load. One row per load_sk.
-- Cards BI uses amount_eur for portal loads — never sum mixed natives.

with load_rows as (
    select
        l.load_sk,
        l.date_sk,
        l.source_system,
        l.direction,
        l.successful,
        l.currency_sk,
        cast(l.amount as double precision) as amount_native,
        c.currency_code as source_currency
    from {{ ref('fact_card_load') }} l
    left join {{ source('spike_live', 'dim_currency') }} c
        on c.id = l.currency_sk
    {% if is_incremental() %}
    where l.loaded_at >= '{{ var("reporting_run_started_at", "9999-12-31") }}'::timestamp
    {% endif %}
),
gbp as (
    select min(id) as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'GBP'
),
eur as (
    select min(id) as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'EUR'
),
usd as (
    select min(id) as currency_sk from {{ source('spike_live', 'dim_currency') }} where currency_code = 'USD'
),
spine as (
    select
        from_currency_sk, target_currency_sk, date_sk, rate,
        row_number() over (
            partition by from_currency_sk, target_currency_sk, date_sk
            order by loaded_at desc nulls last
        ) as rn
    from {{ source('spike_fx', 'fx_rate_spine') }}
)

select
    l.load_sk,
    l.date_sk,
    l.source_system,
    l.direction,
    l.successful,
    l.currency_sk,
    l.source_currency,
    cast(case when g.rate is not null then l.amount_native * g.rate end as decimal(18, 4)) as amount_gbp,
    cast(case when e.rate is not null then l.amount_native * e.rate end as decimal(18, 4)) as amount_eur,
    cast(case when u.rate is not null then l.amount_native * u.rate end as decimal(18, 4)) as amount_usd,
    (g.rate is not null) as fx_matched_gbp,
    (e.rate is not null) as fx_matched_eur,
    (u.rate is not null) as fx_matched_usd,
    getdate() as loaded_at
from load_rows l
cross join gbp gb
cross join eur er
cross join usd us
left join spine g
    on g.from_currency_sk = l.currency_sk
   and g.date_sk = l.date_sk
   and g.target_currency_sk = gb.currency_sk
   and g.rn = 1
left join spine e
    on e.from_currency_sk = l.currency_sk
   and e.date_sk = l.date_sk
   and e.target_currency_sk = er.currency_sk
   and e.rn = 1
left join spine u
    on u.from_currency_sk = l.currency_sk
   and u.date_sk = l.date_sk
   and u.target_currency_sk = us.currency_sk
   and u.rn = 1
