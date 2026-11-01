{{ config(tags=['fx', 'payments']) }}

-- Identity currencies must equal native amount (4dp) when the source is GBP/EUR/USD.

with joined as (
    select
        r.payment_sk,
        r.source_currency,
        cast(f.amount as decimal(18, 4)) as amount_native,
        r.amount_gbp,
        r.amount_eur,
        r.amount_usd
    from {{ ref('fact_payment_reporting') }} r
    inner join {{ ref('fact_payment') }} f
        on f.payment_sk = r.payment_sk
)

select
    payment_sk,
    source_currency,
    amount_native,
    amount_gbp,
    amount_eur,
    amount_usd
from joined
where (source_currency = 'GBP' and amount_gbp <> amount_native)
   or (source_currency = 'EUR' and amount_eur <> amount_native)
   or (source_currency = 'USD' and amount_usd <> amount_native)
