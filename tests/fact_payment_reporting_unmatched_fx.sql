{{ config(tags=['fx', 'payments']) }}

-- Fail when a reporting row could not convert to GBP, EUR, or USD
-- (missing as-of FX path for the payment's source currency).

select
    payment_sk,
    source_currency,
    date_sk,
    fx_matched_gbp,
    fx_matched_eur,
    fx_matched_usd,
    amount_gbp,
    amount_eur,
    amount_usd
from {{ ref('fact_payment_reporting') }}
where not fx_matched_gbp
   or not fx_matched_eur
   or not fx_matched_usd
   or amount_gbp is null
   or amount_eur is null
   or amount_usd is null
