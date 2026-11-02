{{ config(
    alias='fact_card_txn_reporting',
    tags=['fx', 'cards', 'mart'],
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='card_txn_sk',
    on_schema_change='append_new_columns',
    dist='card_txn_sk',
    sort=['date_sk', 'card_txn_sk'],
    pre_hook=["{{ carry_forward_fx_spine_cards() }}"],
) }}

-- Slim FX companion for fact_card_txn (not SoR). One row per card_txn_sk.
-- Settlement and fee amounts → GBP/EUR/USD via spike.fx_rate_spine (as-of date_sk).
-- Cards BI must use these consolidated measures — never sum mixed native currencies.

with txn as (
    select
        t.card_txn_sk,
        t.card_txn_nk,
        t.date_sk,
        t.txn_outcome,
        coalesce(t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk) as settlement_from_currency_sk,
        coalesce(t.fee_currency_sk, t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk) as fee_from_currency_sk,
        cast(t.settlement_amount as double precision) as settlement_native,
        cast(t.fee_amount_sum as double precision) as fee_native,
        sc.currency_code as settlement_source_currency,
        fc.currency_code as fee_source_currency
    from {{ ref('fact_card_txn') }} t
    left join {{ source('spike_live', 'dim_currency') }} sc
        on sc.id = coalesce(t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk)
    left join {{ source('spike_live', 'dim_currency') }} fc
        on fc.id = coalesce(t.fee_currency_sk, t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk)
    {% if is_incremental() %}
    where t.loaded_at >= '{{ var("reporting_run_started_at", "9999-12-31") }}'::timestamp
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
        from_currency_sk,
        target_currency_sk,
        date_sk,
        rate,
        row_number() over (
            partition by from_currency_sk, target_currency_sk, date_sk
            order by loaded_at desc nulls last
        ) as rn
    from {{ source('spike_fx', 'fx_rate_spine') }}
)

select
    t.card_txn_sk,
    t.card_txn_nk,
    t.date_sk,
    t.txn_outcome,
    t.settlement_from_currency_sk,
    t.fee_from_currency_sk,
    t.settlement_source_currency,
    t.fee_source_currency,
    cast(case
        when t.settlement_native is null then null
        when sg.rate is not null then t.settlement_native * sg.rate
    end as decimal(18, 4)) as settlement_amount_gbp,
    cast(case
        when t.settlement_native is null then null
        when se.rate is not null then t.settlement_native * se.rate
    end as decimal(18, 4)) as settlement_amount_eur,
    cast(case
        when t.settlement_native is null then null
        when su.rate is not null then t.settlement_native * su.rate
    end as decimal(18, 4)) as settlement_amount_usd,
    cast(case
        when t.fee_native is null then null
        when fg.rate is not null then t.fee_native * fg.rate
    end as decimal(18, 4)) as fee_amount_gbp,
    cast(case
        when t.fee_native is null then null
        when fe.rate is not null then t.fee_native * fe.rate
    end as decimal(18, 4)) as fee_amount_eur,
    cast(case
        when t.fee_native is null then null
        when fu.rate is not null then t.fee_native * fu.rate
    end as decimal(18, 4)) as fee_amount_usd,
    (t.settlement_native is null or sg.rate is not null) as fx_matched_settlement_gbp,
    (t.settlement_native is null or se.rate is not null) as fx_matched_settlement_eur,
    (t.settlement_native is null or su.rate is not null) as fx_matched_settlement_usd,
    (t.fee_native is null or fg.rate is not null) as fx_matched_fee_gbp,
    (t.fee_native is null or fe.rate is not null) as fx_matched_fee_eur,
    (t.fee_native is null or fu.rate is not null) as fx_matched_fee_usd,
    getdate() as loaded_at
from txn t
cross join gbp gb
cross join eur er
cross join usd us
left join spine sg
    on sg.from_currency_sk = t.settlement_from_currency_sk
   and sg.date_sk = t.date_sk
   and sg.target_currency_sk = gb.currency_sk
   and sg.rn = 1
left join spine se
    on se.from_currency_sk = t.settlement_from_currency_sk
   and se.date_sk = t.date_sk
   and se.target_currency_sk = er.currency_sk
   and se.rn = 1
left join spine su
    on su.from_currency_sk = t.settlement_from_currency_sk
   and su.date_sk = t.date_sk
   and su.target_currency_sk = us.currency_sk
   and su.rn = 1
left join spine fg
    on fg.from_currency_sk = t.fee_from_currency_sk
   and fg.date_sk = t.date_sk
   and fg.target_currency_sk = gb.currency_sk
   and fg.rn = 1
left join spine fe
    on fe.from_currency_sk = t.fee_from_currency_sk
   and fe.date_sk = t.date_sk
   and fe.target_currency_sk = er.currency_sk
   and fe.rn = 1
left join spine fu
    on fu.from_currency_sk = t.fee_from_currency_sk
   and fu.date_sk = t.date_sk
   and fu.target_currency_sk = us.currency_sk
   and fu.rn = 1
