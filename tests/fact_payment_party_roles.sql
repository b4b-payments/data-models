-- A present account or beneficiary uses exactly one unknown role key.
-- A blank account uses unknown for both. Neither role key is the client account.

with portal as (
    select
        'portal_b4b' as source_system,
        cast(id as varchar) as source_payment_id,
        nullif(trim(counterparty_account), '') is not null as has_party
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    union all
    select
        'portal_b4s',
        cast(id as varchar),
        nullif(trim(counterparty_account), '') is not null
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
),
oversight as (
    select
        'oversight' as source_system,
        cast(id as varchar) as source_payment_id,
        nullif(trim(cast(beneficiary_id as varchar)), '') is not null as has_party
    from {{ source('spike_stg', 'stg_oversight_payments') }}
),
keys as (
    select * from portal
    union all
    select * from oversight
),
unknown_sk as (
    select {{ sk_unknown() }} as party_sk
)

select f.payment_sk
from {{ ref('fact_payment') }} f
inner join keys k
    on k.source_system = f.source_system
   and k.source_payment_id = f.source_payment_id
cross join unknown_sk u
where (
        k.has_party
        and (
            (f.debtor_party_sk = u.party_sk) = (f.creditor_party_sk = u.party_sk)
        )
    )
    or (
        not k.has_party
        and (f.debtor_party_sk <> u.party_sk or f.creditor_party_sk <> u.party_sk)
    )
    or f.debtor_party_sk = f.account_sk
    or f.creditor_party_sk = f.account_sk
