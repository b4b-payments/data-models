{{ config(
    alias='fact_exchange_rate_daily',
    tags=['fx', 'mart'],
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['from_currency_sk', 'to_currency_sk', 'date_sk', 'vendor'],
    on_schema_change='append_new_columns',
    dist='date_sk',
    sort=['date_sk', 'from_currency_sk', 'to_currency_sk', 'vendor']
) }}

-- Grain: one Yahoo mid rate per (date, from, to, vendor).
-- SoT: PassFort fx_daily_rates via spike.stg_passfort_fx_daily_rates.
-- Do not use for customer deal rates. Reporting conversion only.
-- Incremental: staging rows with updated_at past the watermark, plus a
-- 3-day rate_date lookback so carry corrections re-apply.

with
staging as (
    select
        upper(trim(r.base_code)) as from_code,
        upper(trim(r.quote_code)) as to_code,
        r.rate_date,
        cast(r.rate as decimal(24, 12)) as rate,
        r.pair,
        r.origin,
        r.asset_class,
        r.yahoo_symbol,
        r.source,
        r.extracted_at,
        r.updated_at as source_updated_at,
        'passfort' as source_system,
        'yahoo' as vendor
    from {{ source('spike_stg', 'stg_passfort_fx_daily_rates') }} r
    where r.rate is not null
      and nullif(trim(r.base_code), '') is not null
      and nullif(trim(r.quote_code), '') is not null
      and r.rate_date is not null
    {% if is_incremental() %}
      and (
          r.updated_at > (
              select coalesce(max(source_updated_at), cast('1900-01-01' as timestamp))
              from {{ this }}
          )
          or r.rate_date >= dateadd(day, -3, current_date)
      )
    {% endif %}
),
mapped as (
    select
        fnv_hash(
            cast(c_from.id as varchar)
            || '|' || cast(c_to.id as varchar)
            || '|' || cast(d.id as varchar)
            || '|' || s.vendor
        ) as fx_rate_daily_sk,
        s.source_system,
        s.pair as source_pk,
        d.id as date_sk,
        c_from.id as from_currency_sk,
        c_to.id as to_currency_sk,
        s.vendor,
        s.rate,
        s.pair,
        s.origin,
        s.asset_class,
        s.yahoo_symbol,
        s.source,
        s.extracted_at,
        s.source_updated_at,
        getdate() as loaded_at
    from staging s
    inner join {{ source('spike_live', 'dim_currency') }} c_from
        on c_from.currency_code = s.from_code
    inner join {{ source('spike_live', 'dim_currency') }} c_to
        on c_to.currency_code = s.to_code
    inner join {{ source('spike_live', 'dim_date') }} d
        on d.calendar_date = s.rate_date
)

select * from mapped
