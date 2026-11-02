{{ config(
    alias='fact_payment_reporting',
    tags=['fx', 'payments', 'mart'],
    materialized='table',
    dist='payment_sk',
    sort=['date_sk', 'payment_sk']
) }}

-- Slim reporting fact: one row per payment_sk with GBP/EUR/USD amounts.
-- Not on fact_payment (late FX). Rebuild on FX cron; conjoin 1:1 for Cube/BI.
-- Yahoo is USD-crossed: identity / direct from→target / else from→USD * USD→target.
-- Each hop is as-of (latest rate on or before booking date).

with payment as (
    select
        f.payment_sk,
        f.currency_sk,
        f.date_sk,
        f.amount,
        c.currency_code as source_currency,
        d.calendar_date as booking_date
    from {{ ref('fact_payment') }} f
    left join {{ source('spike_live', 'dim_currency') }} c
        on c.id = f.currency_sk
    left join {{ source('spike_live', 'dim_date') }} d
        on d.id = f.date_sk
),
ccy as (
    select currency_code, id as currency_sk
    from {{ source('spike_live', 'dim_currency') }}
),
usd as (
    select currency_sk as usd_sk from ccy where currency_code = 'USD'
),
gbp as (
    select currency_sk as gbp_sk from ccy where currency_code = 'GBP'
),
eur as (
    select currency_sk as eur_sk from ccy where currency_code = 'EUR'
),
to_usd as (
    select
        p.payment_sk,
        cast(fx.rate as double precision) as rate_to_usd,
        row_number() over (
            partition by p.payment_sk
            order by d_fx.calendar_date desc nulls last
        ) as rn
    from payment p
    cross join usd u
    inner join {{ ref('fact_exchange_rate_daily') }} fx
        on fx.from_currency_sk = p.currency_sk
       and fx.to_currency_sk = u.usd_sk
       and fx.vendor = 'yahoo'
    inner join {{ source('spike_live', 'dim_date') }} d_fx
        on d_fx.id = fx.date_sk
       and d_fx.calendar_date <= p.booking_date
),
usd_to_gbp as (
    select
        p.payment_sk,
        cast(fx.rate as double precision) as rate_usd_to_gbp,
        row_number() over (
            partition by p.payment_sk
            order by d_fx.calendar_date desc nulls last
        ) as rn
    from payment p
    cross join usd u
    cross join gbp g
    inner join {{ ref('fact_exchange_rate_daily') }} fx
        on fx.from_currency_sk = u.usd_sk
       and fx.to_currency_sk = g.gbp_sk
       and fx.vendor = 'yahoo'
    inner join {{ source('spike_live', 'dim_date') }} d_fx
        on d_fx.id = fx.date_sk
       and d_fx.calendar_date <= p.booking_date
),
usd_to_eur as (
    select
        p.payment_sk,
        cast(fx.rate as double precision) as rate_usd_to_eur,
        row_number() over (
            partition by p.payment_sk
            order by d_fx.calendar_date desc nulls last
        ) as rn
    from payment p
    cross join usd u
    cross join eur e
    inner join {{ ref('fact_exchange_rate_daily') }} fx
        on fx.from_currency_sk = u.usd_sk
       and fx.to_currency_sk = e.eur_sk
       and fx.vendor = 'yahoo'
    inner join {{ source('spike_live', 'dim_date') }} d_fx
        on d_fx.id = fx.date_sk
       and d_fx.calendar_date <= p.booking_date
),
direct_gbp as (
    select
        p.payment_sk,
        cast(fx.rate as double precision) as rate,
        row_number() over (
            partition by p.payment_sk
            order by d_fx.calendar_date desc nulls last
        ) as rn
    from payment p
    cross join gbp g
    inner join {{ ref('fact_exchange_rate_daily') }} fx
        on fx.from_currency_sk = p.currency_sk
       and fx.to_currency_sk = g.gbp_sk
       and fx.vendor = 'yahoo'
    inner join {{ source('spike_live', 'dim_date') }} d_fx
        on d_fx.id = fx.date_sk
       and d_fx.calendar_date <= p.booking_date
),
direct_eur as (
    select
        p.payment_sk,
        cast(fx.rate as double precision) as rate,
        row_number() over (
            partition by p.payment_sk
            order by d_fx.calendar_date desc nulls last
        ) as rn
    from payment p
    cross join eur e
    inner join {{ ref('fact_exchange_rate_daily') }} fx
        on fx.from_currency_sk = p.currency_sk
       and fx.to_currency_sk = e.eur_sk
       and fx.vendor = 'yahoo'
    inner join {{ source('spike_live', 'dim_date') }} d_fx
        on d_fx.id = fx.date_sk
       and d_fx.calendar_date <= p.booking_date
),
rates as (
    select
        p.payment_sk,
        p.currency_sk,
        p.date_sk,
        cast(p.amount as double precision) as amount_native,
        p.source_currency,
        case
            when p.source_currency = 'GBP' then 1.0
            when dg.rate is not null then dg.rate
            when tu.rate_to_usd is not null and ug.rate_usd_to_gbp is not null
                then tu.rate_to_usd * ug.rate_usd_to_gbp
            else null
        end as rate_gbp,
        case
            when p.source_currency = 'EUR' then 1.0
            when de.rate is not null then de.rate
            when tu.rate_to_usd is not null and ue.rate_usd_to_eur is not null
                then tu.rate_to_usd * ue.rate_usd_to_eur
            else null
        end as rate_eur,
        case
            when p.source_currency = 'USD' then 1.0
            when tu.rate_to_usd is not null then tu.rate_to_usd
            else null
        end as rate_usd
    from payment p
    left join to_usd tu
        on tu.payment_sk = p.payment_sk and tu.rn = 1
    left join usd_to_gbp ug
        on ug.payment_sk = p.payment_sk and ug.rn = 1
    left join usd_to_eur ue
        on ue.payment_sk = p.payment_sk and ue.rn = 1
    left join direct_gbp dg
        on dg.payment_sk = p.payment_sk and dg.rn = 1
    left join direct_eur de
        on de.payment_sk = p.payment_sk and de.rn = 1
)

select
    payment_sk,
    date_sk,
    currency_sk,
    source_currency,
    cast(case when rate_gbp is not null then amount_native * rate_gbp end as decimal(18, 4)) as amount_gbp,
    cast(case when rate_eur is not null then amount_native * rate_eur end as decimal(18, 4)) as amount_eur,
    cast(case when rate_usd is not null then amount_native * rate_usd end as decimal(18, 4)) as amount_usd,
    (rate_gbp is not null) as fx_matched_gbp,
    (rate_eur is not null) as fx_matched_eur,
    (rate_usd is not null) as fx_matched_usd,
    getdate() as loaded_at
from rates
