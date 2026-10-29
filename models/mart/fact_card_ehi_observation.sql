{{ config(
    alias='fact_card_ehi_observation',
    tags=['cards', 'mart'],
    sort=['date_sk', 'source_system']
) }}

-- Grain: one portal card_transactions row that is not a balance posting.
-- Includes every authorisation, and financial rows that do not post.
-- Amounts use the observed_ prefix and are not Cube measures.
-- Holds (authorisation with impacts_balance = 1) stay here. They are not settled spend.

with txns as (
    select 'portal_b4b' as source_system, t.*
    from {{ source('spike_stg', 'stg_b4b_card_transactions') }} t
    where not ({{ posting_predicate('t') }})

    union all

    select 'portal_b4s' as source_system, t.*
    from {{ source('spike_stg', 'stg_b4s_card_transactions') }} t
    where not ({{ posting_predicate('t') }})
)

select
    row_number() over (order by t.source_system, t.id) as observation_sk,
    t.source_system,
    cast(t.id as varchar) as source_ledger_id,
    c.card_sk,
    c.cardholder_sk,
    a.entity_sk,
    a.account_sk,
    pr.processor_sk,
    cur.id as currency_sk,
    bcur.id as billing_currency_sk,
    scur.id as settlement_currency_sk,
    d.id as date_sk,
    t.transaction_timestamp as event_ts,
    t.amount as observed_txn_amount,
    t.billing_amount as observed_billing_amount,
    t.settlement_amount as observed_settlement_amount,
    t.declined,
    t.ledger_transaction,
    t.impacts_balance,
    t.transaction_type,
    t.transaction_class,
    t.processor_transaction_type,
    nullif(trim(t.processor_transaction_id), '') as processor_transaction_id,
    nullif(trim(t.processor_traceid), '') as processor_traceid,
    nullif(trim(t.transaction_link), '') as transaction_link,
    nullif(trim(t.token), '') as card_token,
    t.transaction_authorisation_code as auth_code,
    t.mcc_code,
    t.merchant_country as merchant_country_code,
    t.resp_code_de39 as response_code,
    t.processor as processor_code_raw,
    getdate() as loaded_at
from txns t
left join (
    {{ unique_portal_cards() }}
) c
    on c.processor_card_id = nullif(trim(t.token), '')
left join {{ ref('dim_account') }} a
    on a.source_system = t.source_system
   and a.source_pk = cast(t.company_id as varchar)
left join {{ ref('dim_processor') }} pr
    on pr.processor_code = lower(trim(t.processor))
left join {{ source('spike_live', 'dim_currency') }} cur
    on cur.currency_code = upper(trim(t.currency))
left join {{ source('spike_live', 'dim_currency') }} bcur
    on bcur.currency_code = upper(trim(t.billing_currency))
left join {{ source('spike_live', 'dim_currency') }} scur
    on scur.currency_code = upper(trim(t.settlement_currency))
left join {{ source('spike_live', 'dim_date') }} d
    on d.calendar_date = cast(t.transaction_date as date)
