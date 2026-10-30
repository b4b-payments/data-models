-- Linked outgoing portal rows take lifecycle status from payments.status.

with linked as (
    select
        'portal_b4b' as source_system,
        cast(banking_circle_transaction_notification_id as varchar) as source_payment_id,
        status,
        row_number() over (
            partition by banking_circle_transaction_notification_id
            order by id desc
        ) as rn
    from {{ source('spike_stg', 'stg_b4b_payments') }}
    where banking_circle_transaction_notification_id is not null
    union all
    select
        'portal_b4s',
        cast(banking_circle_transaction_notification_id as varchar),
        status,
        row_number() over (
            partition by banking_circle_transaction_notification_id
            order by id desc
        ) as rn
    from {{ source('spike_stg', 'stg_b4s_payments') }}
    where banking_circle_transaction_notification_id is not null
)

select f.payment_sk
from {{ ref('fact_payment') }} f
inner join linked p
    on p.source_system = f.source_system
   and p.source_payment_id = f.source_payment_id
   and p.rn = 1
inner join {{ ref('dim_payment_status') }} actual
    on actual.payment_status_sk = f.payment_status_sk
inner join {{ ref('dim_payment_status') }} expected
    on expected.status_source = 'portal_payments'
   and expected.source_status = p.status
where f.payment_direction = 'Outgoing'
  and actual.normalised_status <> expected.normalised_status
