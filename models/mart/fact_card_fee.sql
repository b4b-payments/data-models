{{ config(
    alias='fact_card_fee',
    tags=['cards', 'mart'],
    sort=['date_sk', 'source_system']
) }}

-- Grain: one GPS CardFee line. This is the scheme-fee fact.
-- Presentment fee columns and portal fee fields are not added here.

with gps as (
    select 'gps_mc' as source_system, f.*
    from {{ source('spike_stg', 'stg_gps_mc_card_fee') }} f

    union all

    select 'gps_visa' as source_system, f.*
    from {{ source('spike_stg', 'stg_gps_visa_card_fee') }} f
)

select
    row_number() over (order by g.source_system, g.id) as fee_sk,
    g.source_system,
    nullif(trim(g.cardfeeid), '') as source_fee_id,
    cast(g.id as varchar) as source_row_id,
    case when upper(trim(g."card-programid")) like 'WV%' then null else c.card_sk end as card_sk,
    case when upper(trim(g."card-programid")) like 'WV%' then null else c.cardholder_sk end as cardholder_sk,
    case when upper(trim(g."card-programid")) like 'WV%' then null else c.entity_sk end as entity_sk,
    case when upper(trim(g."card-programid")) like 'WV%' then null else c.account_sk end as account_sk,
    p.processor_sk,
    case when upper(trim(g."card-programid")) like 'WV%' then null else c.card_product_sk end as card_product_sk,
    cur.id as currency_sk,
    d.id as date_sk,
    sd.id as settlement_date_sk,
    {{ signed_by_direction('g."feeamt-value"', 'g."feeamt-direction"') }} as fee_amount,
    g."amt-value" as basis_amount,
    g."feeclass-code" as fee_class_code,
    g."feeclass-type" as fee_class_type,
    g."feeclass-interchangetransaction" as fee_class_interchange,
    g."txncode-type" as txn_code_type,
    g."txncode-group" as txn_code_group,
    nullif(trim(g.txid), '') as source_tx_id,
    nullif(trim(g.loadunloadid), '') as source_load_unload_id,
    nullif(trim(g.cardid), '') as processor_card_id,
    g."desc" as description,
    getdate() as loaded_at
from gps g
left join (
    {{ unique_portal_cards() }}
) c
    on c.processor_card_id = nullif(trim(g.cardid), '')
left join {{ ref('dim_processor') }} p
    on p.processor_code = g.source_system
left join {{ source('spike_live', 'dim_currency') }} cur
    on cur.currency_code = upper(trim(g."feeamt-currency"))
left join {{ source('spike_live', 'dim_date') }} d
    on d.calendar_date = cast(g.localdate as date)
left join {{ source('spike_live', 'dim_date') }} sd
    on sd.calendar_date = g.settlementdate
