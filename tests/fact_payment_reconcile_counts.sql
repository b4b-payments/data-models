{{ config(tags=['weekly_reconcile']) }}

-- Fact grain is one notification or one Oversight payment.

with fact as (
    select source_system, count(*) as n
    from {{ ref('fact_payment') }}
    group by 1
),
src as (
    select
        'portal_b4b' as source_system,
        count(*) as n
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    union all
    select
        'portal_b4s',
        count(*)
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
    union all
    select
        'oversight',
        count(*)
    from {{ source('spike_stg', 'stg_oversight_payments') }}
)

select
    coalesce(f.source_system, s.source_system) as source_system,
    f.n as fact_n,
    s.n as source_n
from fact f
full outer join src s
    on s.source_system = f.source_system
where coalesce(f.n, 0) <> coalesce(s.n, 0)
