{{ config(tags=['fx', 'payments']) }}

-- Every payment must have exactly one reporting row (1:1 conjoin for Cube/BI).

with fact as (
    select payment_sk from {{ ref('fact_payment') }}
),
reporting as (
    select payment_sk from {{ ref('fact_payment_reporting') }}
)

select
    coalesce(f.payment_sk, r.payment_sk) as payment_sk,
    case
        when f.payment_sk is null then 'orphan_reporting'
        when r.payment_sk is null then 'missing_reporting'
    end as gap
from fact f
full outer join reporting r
    on r.payment_sk = f.payment_sk
where f.payment_sk is null
   or r.payment_sk is null
