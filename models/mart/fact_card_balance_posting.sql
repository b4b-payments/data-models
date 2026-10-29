{{ config(
    alias='fact_card_balance_posting',
    tags=['cards', 'mart'],
    sort=['date_sk', 'source_system']
) }}

-- Grain: one portal card_transactions row that posts to the customer balance.
-- A row qualifies only when transaction_class is financial, ledger_transaction
-- is 1, impacts_balance is 1, and declined is 0.
-- load_unload rows stay off this fact. Their total is fact_card_load.
-- account_sk is the transaction company. It is empty when that company has
-- no legal entity, because dim_account still requires one. The spend row stays.

with txns as (
    select 'portal_b4b' as source_system, t.*
    from {{ source('spike_stg', 'stg_b4b_card_transactions') }} t
    where {{ posting_predicate('t') }}

    union all

    select 'portal_b4s' as source_system, t.*
    from {{ source('spike_stg', 'stg_b4s_card_transactions') }} t
    where {{ posting_predicate('t') }}
)

select
    row_number() over (order by t.source_system, t.id) as posting_sk,
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
    t.amount as txn_amount,
    t.billing_amount,
    t.settlement_amount,
    t.blocked_amount,
    t.fees_fixed_amount,
    t.fees_rate_amount,
    t.fx_padding as fx_padding_amount,
    t.declined,
    t.ledger_transaction,
    t.impacts_balance,
    t.atm,
    t.pos,
    t.transaction_type,
    t.transaction_class,
    t.processor_transaction_type,
    nullif(trim(t.processor_transaction_id), '') as processor_transaction_id,
    nullif(trim(t.processor_traceid), '') as processor_traceid,
    nullif(trim(t.transaction_link), '') as transaction_link,
    nullif(trim(t.token), '') as card_token,
    t.transaction_authorisation_code as auth_code,
    t.acquirer_reference_data as arn,
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
