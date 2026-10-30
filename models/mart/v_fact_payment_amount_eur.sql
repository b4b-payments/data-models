{{ config(
    alias='v_fact_payment_amount_eur',
    tags=['fx', 'payments', 'mart'],
    materialized='table',
    dist='payment_sk',
    sort=['date_sk', 'source_currency']
) }}

-- Consolidated payment volume in EUR. Not stored on fact_payment (late FX).
-- Table (not a column on the payment fact): rebuilt on the FX incremental cron
-- so late Yahoo rates update EUR volume without rewriting fact_payment.
-- Yahoo pairs are USD-crossed (e.g. DKK_USD, USD_EUR), not direct DKK_EUR.
-- Convert: identity if EUR; one hop if *→EUR exists; else via USD
--   amount * asof(from→USD) * asof(USD→EUR).
-- Each hop is the latest yahoo rate on or before the booking date.

with payment as (
    select
        f.payment_sk,
        f.source_system,
        f.source_payment_id,
        f.entity_sk,
        f.account_sk,
        f.currency_sk,
        f.date_sk,
        f.amount,
        f.payment_direction,
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
eur as (
    select currency_sk as eur_sk from ccy where currency_code = 'EUR'
),
usd as (
    select currency_sk as usd_sk from ccy where currency_code = 'USD'
),
-- Direct from→EUR (covers EUR identity via separate branch; USD→EUR; any future direct pairs)
direct_fx as (
    select
        p.payment_sk,
        fx.rate,
        d_fx.calendar_date as fx_rate_date,
        fx.vendor,
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
to_usd as (
    select
        p.payment_sk,
        fx.rate as rate_to_usd,
        d_fx.calendar_date as fx_to_usd_date,
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
usd_to_eur as (
    select
        p.payment_sk,
        fx.rate as rate_usd_to_eur,
        d_fx.calendar_date as fx_usd_eur_date,
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
converted as (
    select
        p.*,
        case
            when p.source_currency = 'EUR' then cast(1 as double precision)
            when d.rate is not null then cast(d.rate as double precision)
            when tu.rate_to_usd is not null and ue.rate_usd_to_eur is not null
                then cast(tu.rate_to_usd as double precision)
                     * cast(ue.rate_usd_to_eur as double precision)
            else cast(null as double precision)
        end as fx_rate,
        case
            when p.source_currency = 'EUR' then p.booking_date
            when d.rate is not null then d.fx_rate_date
            when tu.rate_to_usd is not null and ue.rate_usd_to_eur is not null
                then least(tu.fx_to_usd_date, ue.fx_usd_eur_date)
            else cast(null as date)
        end as fx_rate_date,
        case
            when p.source_currency = 'EUR' then cast(null as varchar)
            when d.rate is not null then d.vendor
            when tu.rate_to_usd is not null and ue.rate_usd_to_eur is not null then 'yahoo'
            else cast(null as varchar)
        end as fx_vendor,
        case
            when p.source_currency = 'EUR' then 'identity'
            when d.rate is not null then 'direct'
            when tu.rate_to_usd is not null and ue.rate_usd_to_eur is not null then 'via_usd'
            else 'unmatched'
        end as fx_path
    from payment p
    left join direct_fx d
        on d.payment_sk = p.payment_sk and d.rn = 1
    left join to_usd tu
        on tu.payment_sk = p.payment_sk and tu.rn = 1
    left join usd_to_eur ue
        on ue.payment_sk = p.payment_sk and ue.rn = 1
)

select
    payment_sk,
    source_system,
    source_payment_id,
    entity_sk,
    account_sk,
    currency_sk,
    date_sk,
    amount as amount_source,
    source_currency,
    booking_date,
    payment_direction,
    'EUR' as reporting_currency,
    case
        when fx_rate is not null
            then cast(cast(amount as double precision) * fx_rate as decimal(18, 4))
        else cast(null as decimal(18, 4))
    end as amount_eur,
    fx_rate,
    fx_rate_date,
    fx_vendor,
    fx_path,
    (fx_rate is not null) as fx_matched
from converted
