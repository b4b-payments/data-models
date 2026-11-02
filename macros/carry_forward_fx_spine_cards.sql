{% macro carry_forward_fx_spine_cards() %}
{# Carry forward missing booking-date spine rows for cards facts. Dedupes spine keys. #}
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
        select distinct
            coalesce(t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk) as from_currency_sk,
            tgt.id as target_currency_sk,
            t.date_sk
        from {{ ref('fact_card_txn') }} t
        cross join (
            select min(id) as id
            from {{ source('spike_live', 'dim_currency') }}
            where currency_code in ('GBP', 'EUR', 'USD')
            group by currency_code
        ) tgt
        where coalesce(t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk) is not null
          and t.date_sk is not null
        union
        select distinct
            coalesce(t.fee_currency_sk, t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk),
            tgt.id,
            t.date_sk
        from {{ ref('fact_card_txn') }} t
        cross join (
            select min(id) as id
            from {{ source('spike_live', 'dim_currency') }}
            where currency_code in ('GBP', 'EUR', 'USD')
            group by currency_code
        ) tgt
        where coalesce(t.fee_currency_sk, t.settlement_currency_sk, t.currency_sk, t.billing_currency_sk) is not null
          and t.date_sk is not null
        union
        select distinct l.currency_sk, tgt.id, l.date_sk
        from {{ ref('fact_card_load') }} l
        cross join (
            select min(id) as id
            from {{ source('spike_live', 'dim_currency') }}
            where currency_code in ('GBP', 'EUR', 'USD')
            group by currency_code
        ) tgt
        where l.currency_sk is not null and l.date_sk is not null
        union
        select distinct p.currency_sk, tgt.id, p.date_sk
        from {{ ref('fact_card_balance_posting') }} p
        cross join (
            select min(id) as id
            from {{ source('spike_live', 'dim_currency') }}
            where currency_code in ('GBP', 'EUR', 'USD')
            group by currency_code
        ) tgt
        where p.currency_sk is not null and p.date_sk is not null
    ) need
    left join (
        select distinct from_currency_sk, target_currency_sk, date_sk
        from {{ source('spike_fx', 'fx_rate_spine') }}
    ) have
      on have.from_currency_sk = need.from_currency_sk
     and have.target_currency_sk = need.target_currency_sk
     and have.date_sk = need.date_sk
    join (
        select
            from_currency_sk,
            target_currency_sk,
            date_sk,
            rate,
            fx_path,
            direct_rate_date,
            usd_leg_rate_date,
            usd_target_rate_date,
            row_number() over (
                partition by from_currency_sk, target_currency_sk, date_sk
                order by loaded_at desc nulls last
            ) as spine_rn
        from {{ source('spike_fx', 'fx_rate_spine') }}
    ) earlier
      on earlier.from_currency_sk = need.from_currency_sk
     and earlier.target_currency_sk = need.target_currency_sk
     and earlier.date_sk < need.date_sk
     and earlier.spine_rn = 1
    where have.date_sk is null
) ranked
where rn = 1
{% endmacro %}
