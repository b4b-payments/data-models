{{ config(
    alias='fact_card_financial',
    tags=['cards', 'mart'],
    sort=['settlement_date_sk', 'source_system']
) }}

-- Grain: one GPS presentment (FinId). This is the scheme settlement fact.
-- Visa rows that lack a Mastercard column keep that column null.
-- Visa CardOnlineFinancial is not in this build.
-- auth_sk is set only when one authorisation has that AuthId.
-- Weavr and unmatched CardID values stay on the fact with empty portal keys.

with mc as (
    select
        'gps_mc' as source_system,
        cast(id as varchar) as source_row_id,
        nullif(trim(finid), '') as source_fin_id,
        nullif(trim(authid), '') as source_auth_id,
        nullif(trim(traceid_lifecycle), '') as traceid_lifecycle,
        presentmentid as presentment_id,
        arn,
        nullif(trim(cardid), '') as processor_card_id,
        nullif(trim("card-programid"), '') as processor_program_id,
        "txnamt-value" as txn_amount_raw,
        "billamt-value" as bill_amount_raw,
        "settlementamt-value" as settlement_amount_raw,
        "txncode-direction" as txn_direction,
        "fee-value" as fee_value,
        "fee-direction" as fee_direction,
        "feeamt-value" as feeamt_value,
        "feeamt-direction" as feeamt_direction,
        "classification-mcc" as mcc_code,
        "term-country" as merchant_country_code,
        acquirercountry as acquirer_country_code,
        "txncode-type" as txn_code_type,
        "txncode-group" as txn_code_group,
        "feeclass-code" as fee_class_code,
        settlementindicator as settlement_indicator,
        networktransactionid as network_transaction_id,
        upper(trim("txnamt-currency")) as txn_currency_code,
        upper(trim("billamt-currency")) as billing_currency_code,
        upper(trim("settlementamt-currency")) as settlement_currency_code,
        cast(localdate as date) as txn_date,
        settlementdate as settlement_date,
        schemesettlementdate as scheme_settlement_date
    from {{ source('spike_stg', 'stg_gps_mc_card_financial') }}

    union all

    select
        'gps_visa' as source_system,
        cast(id as varchar) as source_row_id,
        nullif(trim(finid), '') as source_fin_id,
        nullif(trim(authid), '') as source_auth_id,
        cast(null as varchar) as traceid_lifecycle,
        presentmentid as presentment_id,
        arn,
        nullif(trim(cardid), '') as processor_card_id,
        nullif(trim("card-programid"), '') as processor_program_id,
        "txnamt-value" as txn_amount_raw,
        "billamt-value" as bill_amount_raw,
        "settlementamt-value" as settlement_amount_raw,
        "txncode-direction" as txn_direction,
        "fee-value" as fee_value,
        "fee-direction" as fee_direction,
        "feeamt-value" as feeamt_value,
        "feeamt-direction" as feeamt_direction,
        "classification-mcc" as mcc_code,
        "term-country" as merchant_country_code,
        cast(null as varchar) as acquirer_country_code,
        "txncode-type" as txn_code_type,
        "txncode-group" as txn_code_group,
        "feeclass-code" as fee_class_code,
        settlementindicator as settlement_indicator,
        cast(null as varchar) as network_transaction_id,
        upper(trim("txnamt-currency")) as txn_currency_code,
        upper(trim("billamt-currency")) as billing_currency_code,
        upper(trim("settlementamt-currency")) as settlement_currency_code,
        cast(localdate as date) as txn_date,
        settlementdate as settlement_date,
        schemesettlementdate as scheme_settlement_date
    from {{ source('spike_stg', 'stg_gps_visa_card_financial') }}
),

auth_one as (
    select source_system, source_auth_id, auth_sk
    from (
        select
            source_system,
            source_auth_id,
            auth_sk,
            count(*) over (partition by source_system, source_auth_id) as auth_count
        from {{ ref('fact_card_authorisation') }}
        where source_auth_id is not null
    ) a
    where auth_count = 1
)

select
    row_number() over (order by f.source_system, f.source_row_id) as financial_sk,
    f.source_system,
    f.source_fin_id,
    f.source_row_id,
    a.auth_sk,
    f.source_auth_id,
    f.traceid_lifecycle,
    f.presentment_id,
    f.arn,
    case when upper(f.processor_program_id) like 'WV%' then null else c.card_sk end as card_sk,
    case when upper(f.processor_program_id) like 'WV%' then null else c.cardholder_sk end as cardholder_sk,
    case when upper(f.processor_program_id) like 'WV%' then null else c.entity_sk end as entity_sk,
    case when upper(f.processor_program_id) like 'WV%' then null else c.account_sk end as account_sk,
    case when upper(f.processor_program_id) like 'WV%' then null else c.card_product_sk end as card_product_sk,
    s.card_scheme_sk,
    p.processor_sk,
    cur.id as currency_sk,
    bcur.id as billing_currency_sk,
    scur.id as settlement_currency_sk,
    d.id as date_sk,
    sd.id as settlement_date_sk,
    ssd.id as scheme_settlement_date_sk,
    f.txn_amount_raw as txn_amount,
    {{ signed_by_direction('f.bill_amount_raw', 'f.txn_direction') }} as billing_amount,
    {{ signed_by_direction('f.settlement_amount_raw', 'f.txn_direction') }} as settlement_amount,
    {{ signed_by_direction('f.fee_value', 'f.fee_direction') }} as presentment_fee_amount,
    {{ signed_by_direction('f.feeamt_value', 'f.feeamt_direction') }} as fee_amt_amount,
    f.mcc_code,
    f.merchant_country_code,
    f.acquirer_country_code,
    f.txn_code_type,
    f.txn_code_group,
    f.fee_class_code,
    f.settlement_indicator,
    f.processor_card_id,
    f.processor_program_id,
    f.network_transaction_id,
    getdate() as loaded_at
from mc f
left join auth_one a
    on a.source_system = f.source_system
   and a.source_auth_id = f.source_auth_id
left join (
    {{ unique_portal_cards() }}
) c
    on c.processor_card_id = f.processor_card_id
left join {{ ref('dim_card_scheme') }} s
    on s.scheme_code = case f.source_system
        when 'gps_mc' then 'mastercard'
        when 'gps_visa' then 'visa'
    end
left join {{ ref('dim_processor') }} p
    on p.processor_code = f.source_system
left join {{ source('spike_live', 'dim_currency') }} cur
    on cur.currency_code = f.txn_currency_code
left join {{ source('spike_live', 'dim_currency') }} bcur
    on bcur.currency_code = f.billing_currency_code
left join {{ source('spike_live', 'dim_currency') }} scur
    on scur.currency_code = f.settlement_currency_code
left join {{ source('spike_live', 'dim_date') }} d
    on d.calendar_date = f.txn_date
left join {{ source('spike_live', 'dim_date') }} sd
    on sd.calendar_date = f.settlement_date
left join {{ source('spike_live', 'dim_date') }} ssd
    on ssd.calendar_date = f.scheme_settlement_date
