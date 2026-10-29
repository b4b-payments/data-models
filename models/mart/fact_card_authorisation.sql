{{ config(
    alias='fact_card_authorisation',
    tags=['cards', 'mart'],
    sort=['date_sk', 'source_system']
) }}

-- Grain: one GPS authorisation decision, including declines.
-- TxnAmt-value already shares the portal sign. BillAmt-value is stored
-- positive; a debit is made negative from TxnCode-direction.
-- Weavr (programme WV%) keeps the row and leaves portal keys empty.
-- A CardID that matches more than one portal card also leaves those keys empty.

with gps as (
    select 'gps_mc' as source_system, a.*
    from {{ source('spike_stg', 'stg_gps_mc_card_authorisation') }} a

    union all

    select 'gps_visa' as source_system, a.*
    from {{ source('spike_stg', 'stg_gps_visa_card_authorisation') }} a
),

keyed as (
    select
        g.source_system,
        cast(g.id as varchar) as source_row_id,
        nullif(trim(g.authid), '') as source_auth_id,
        nullif(trim(g.traceid_lifecycle), '') as traceid_lifecycle,
        nullif(trim(g.cardid), '') as processor_card_id,
        nullif(trim(g."card-programid"), '') as processor_program_id,
        case
            when upper(trim(g."card-programid")) like 'WV%' then 1
            else 0
        end as is_weavr,
        g."txnamt-value" as txn_amount,
        {{ signed_by_direction('g."billamt-value"', 'g."txncode-direction"') }} as billing_amount,
        g."commissionamt-value" as commission_amount,
        g.fixed_fee as fixed_fee_amount,
        g.rate_fee as rate_fee_amount,
        cast(g."response-approved" as varchar) as approved,
        g."response-responsecode" as response_code,
        g.apprcode as auth_code,
        g."classification-mcc" as mcc_code,
        g."term-country" as merchant_country_code,
        g.acquirercountry as acquirer_country_code,
        g."txncode-type" as txn_code_type,
        g."txncode-group" as txn_code_group,
        g.networktransactionid as network_transaction_id,
        upper(trim(g."txnamt-currency")) as txn_currency_code,
        upper(trim(g."billamt-currency")) as billing_currency_code,
        cast(g.localdate as date) as txn_date,
        g.settlementdate as settlement_date
    from gps g
)

select
    row_number() over (order by k.source_system, k.source_row_id) as auth_sk,
    k.source_system,
    k.source_auth_id,
    k.source_row_id,
    k.traceid_lifecycle,
    case when k.is_weavr = 1 then null else c.card_sk end as card_sk,
    case when k.is_weavr = 1 then null else c.cardholder_sk end as cardholder_sk,
    case when k.is_weavr = 1 then null else c.entity_sk end as entity_sk,
    case when k.is_weavr = 1 then null else c.account_sk end as account_sk,
    case when k.is_weavr = 1 then null else c.card_product_sk end as card_product_sk,
    s.card_scheme_sk,
    p.processor_sk,
    cur.id as currency_sk,
    bcur.id as billing_currency_sk,
    d.id as date_sk,
    sd.id as settlement_date_sk,
    k.txn_amount,
    k.billing_amount,
    k.commission_amount,
    k.fixed_fee_amount,
    k.rate_fee_amount,
    k.approved,
    k.response_code,
    k.auth_code,
    k.mcc_code,
    k.merchant_country_code,
    k.acquirer_country_code,
    k.txn_code_type,
    k.txn_code_group,
    k.processor_card_id,
    k.processor_program_id,
    k.network_transaction_id,
    getdate() as loaded_at
from keyed k
left join (
    {{ unique_portal_cards() }}
) c
    on c.processor_card_id = k.processor_card_id
left join {{ ref('dim_card_scheme') }} s
    on s.scheme_code = case k.source_system
        when 'gps_mc' then 'mastercard'
        when 'gps_visa' then 'visa'
    end
left join {{ ref('dim_processor') }} p
    on p.processor_code = k.source_system
left join {{ source('spike_live', 'dim_currency') }} cur
    on cur.currency_code = k.txn_currency_code
left join {{ source('spike_live', 'dim_currency') }} bcur
    on bcur.currency_code = k.billing_currency_code
left join {{ source('spike_live', 'dim_date') }} d
    on d.calendar_date = k.txn_date
left join {{ source('spike_live', 'dim_date') }} sd
    on sd.calendar_date = k.settlement_date
