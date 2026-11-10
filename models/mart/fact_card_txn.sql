{{ config(
    alias='fact_card_txn',
    tags=['cards', 'mart'],
    materialized='incremental',
    unique_key='card_txn_nk',
    incremental_strategy='delete+insert',
    sort=['date_sk', 'txn_outcome', 'source_system']
) }}

-- Derived card-transaction outcomes (not SoR).
-- Grain: presentment = one FinId; decline = one EHI decline with no FinId.
-- Auth is optional on presentments. Auth vs fin lookalikes stay separate columns.
-- History window via vars; incremental runs only rewrite a short trailing lookback.

{% set week_start = var('card_txn_week_start', '2025-01-01') %}
{% set week_end = var('card_txn_week_end', '2099-12-31') %}
{% set lookback_days = var('card_txn_incremental_lookback_days', 7) | int %}

with week_dates as (
    select id as date_sk, calendar_date
    from {{ source('spike_live', 'dim_date') }}
    where calendar_date between cast('{{ week_start }}' as date)
      and least(cast('{{ week_end }}' as date), current_date)
    {% if is_incremental() %}
      and calendar_date >= dateadd(day, -{{ lookback_days }}, current_date)
    {% endif %}
),

fin_stg as (
    select
        'gps_mc' as source_system,
        nullif(trim(finid), '') as source_fin_id,
        {{ gps_event_ts_utc('localdate', '"localdateutc"') }} as presentment_event_ts_utc,
        nullif(trim("paymenttoken-wallet"), '') as payment_token_wallet,
        nullif(trim("paymenttoken-type"), '') as payment_token_type,
        nullif(trim("paymenttoken-devicetype"), '') as payment_token_device_type
    from {{ source('spike_stg', 'stg_gps_mc_card_financial') }}

    union all

    select
        'gps_visa' as source_system,
        nullif(trim(finid), '') as source_fin_id,
        {{ gps_event_ts_utc('localdate', '"localdateutc"') }} as presentment_event_ts_utc,
        nullif(trim("paymenttoken-wallet"), '') as payment_token_wallet,
        nullif(trim("paymenttoken-type"), '') as payment_token_type,
        nullif(trim("paymenttoken-devicetype"), '') as payment_token_device_type
    from {{ source('spike_stg', 'stg_gps_visa_card_financial') }}
),

auth_stg as (
    select
        'gps_mc' as source_system,
        nullif(trim(authid), '') as source_auth_id,
        {{ gps_event_ts_utc('localdate', '"localdateutc"') }} as auth_event_ts_utc,
        nullif(trim("paymenttoken-wallet"), '') as payment_token_wallet
    from {{ source('spike_stg', 'stg_gps_mc_card_authorisation') }}

    union all

    select
        'gps_visa' as source_system,
        nullif(trim(authid), '') as source_auth_id,
        {{ gps_event_ts_utc('localdate', '"localdateutc"') }} as auth_event_ts_utc,
        nullif(trim("paymenttoken-wallet"), '') as payment_token_wallet
    from {{ source('spike_stg', 'stg_gps_visa_card_authorisation') }}
),

fin_stg_one as (
    select *
    from (
        select
            *,
            row_number() over (
                partition by source_system, source_fin_id
                order by presentment_event_ts_utc nulls last
            ) as rn
        from fin_stg
        where source_fin_id is not null
    ) x
    where rn = 1
),

auth_stg_one as (
    select *
    from (
        select
            *,
            row_number() over (
                partition by source_system, source_auth_id
                order by auth_event_ts_utc nulls last
            ) as rn
        from auth_stg
        where source_auth_id is not null
    ) x
    where rn = 1
),

fees as (
    select
        source_system,
        source_tx_id,
        cast(count(*) as bigint) as fee_count,
        cast(sum(fee_amount) as float) as fee_amount_sum,
        max(currency_sk) as fee_currency_sk
    from {{ ref('fact_card_fee') }}
    where source_tx_id is not null
    group by 1, 2
),

posting_stg_flags as (
    select
        'portal_b4b' as source_system,
        cast(id as varchar) as source_ledger_id,
        coalesce(atm, 0) as atm,
        coalesce(pos, 0) as pos,
        coalesce(ecommerce, 0) as ecommerce,
        nullif(trim(payment_token_wallet), '') as payment_token_wallet
    from {{ source('spike_stg', 'stg_b4b_card_transactions') }}

    union all

    select
        'portal_b4s' as source_system,
        cast(id as varchar) as source_ledger_id,
        coalesce(atm, 0) as atm,
        coalesce(pos, 0) as pos,
        coalesce(ecommerce, 0) as ecommerce,
        nullif(trim(payment_token_wallet), '') as payment_token_wallet
    from {{ source('spike_stg', 'stg_b4s_card_transactions') }}
),

posting_one as (
    select *
    from (
        select
            p.*,
            sf.ecommerce,
            sf.payment_token_wallet as posting_wallet,
            row_number() over (
                partition by p.processor_transaction_id
                order by p.event_ts nulls last, p.posting_sk
            ) as rn
        from {{ ref('fact_card_balance_posting') }} p
        left join posting_stg_flags sf
            on sf.source_system = p.source_system
           and sf.source_ledger_id = p.source_ledger_id
        where p.processor_transaction_id is not null
    ) x
    where rn = 1
),

presentments as (
    select
        'presentment|' || f.source_system || '|' || f.source_fin_id as card_txn_nk,
        'presentment' as txn_outcome,
        f.financial_sk,
        f.source_system,
        f.source_fin_id,
        cast(null as varchar) as source_ledger_id,
        f.auth_sk,
        f.source_auth_id,
        f.traceid_lifecycle,
        cast(f.presentment_id as varchar) as presentment_id,
        cast(f.arn as varchar) as arn,
        cast(f.network_transaction_id as varchar) as network_transaction_id,
        f.card_sk,
        f.cardholder_sk,
        f.account_sk,
        f.entity_sk,
        f.card_product_sk,
        f.card_scheme_sk,
        f.processor_sk,
        f.currency_sk,
        f.billing_currency_sk,
        f.settlement_currency_sk,
        f.date_sk,
        f.settlement_date_sk,
        f.scheme_settlement_date_sk,
        f.txn_amount,
        f.billing_amount,
        f.settlement_amount,
        f.presentment_fee_amount,
        f.fee_amt_amount,
        nullif(trim(cast(f.mcc_code as varchar)), '') as mcc_code,
        f.merchant_country_code,
        f.acquirer_country_code,
        f.txn_code_type,
        f.txn_code_group,
        f.fee_class_code,
        f.settlement_indicator,
        f.processor_card_id,
        f.processor_program_id,
        fs.presentment_event_ts_utc,
        case
            when fs.payment_token_wallet is not null then {{ normalize_wallet('fs.payment_token_wallet') }}
            when po.posting_wallet is not null then {{ normalize_wallet('po.posting_wallet') }}
            else 'none'
        end as wallet,
        fs.payment_token_type,
        fs.payment_token_device_type,
        {{ presentment_channel_from_flags(
            'f.source_system',
            'coalesce(po.atm, 0)',
            'coalesce(po.pos, 0)',
            'f.mcc_code'
        ) }} as presentment_channel,
        {{ card_initiation('coalesce(po.ecommerce, 0)') }} as initiation,
        a.date_sk as auth_date_sk,
        a.settlement_date_sk as auth_settlement_date_sk,
        a.txn_amount as auth_txn_amount,
        a.billing_amount as auth_billing_amount,
        a.commission_amount as auth_commission_amount,
        a.fixed_fee_amount as auth_fixed_fee_amount,
        a.rate_fee_amount as auth_rate_fee_amount,
        a.approved as auth_approved,
        a.response_code as auth_response_code,
        a.auth_code as auth_code,
        a.mcc_code as auth_mcc_code,
        a.merchant_country_code as auth_merchant_country_code,
        a.acquirer_country_code as auth_acquirer_country_code,
        a.txn_code_type as auth_txn_code_type,
        a.txn_code_group as auth_txn_code_group,
        a.currency_sk as auth_currency_sk,
        a.billing_currency_sk as auth_billing_currency_sk,
        aus.auth_event_ts_utc,
        {{ normalize_wallet('aus.payment_token_wallet') }} as auth_wallet,
        {{ presentment_channel_from_flags('cast(null as varchar)', '0', '0', 'a.mcc_code') }} as auth_presentment_channel,
        po.posting_sk,
        po.source_system as posting_source_system,
        po.source_ledger_id as posting_source_ledger_id,
        po.date_sk as posting_date_sk,
        po.event_ts as posting_event_ts_utc,
        po.txn_amount as ledger_txn_amount,
        po.billing_amount as ledger_billing_amount,
        po.settlement_amount as ledger_settlement_amount,
        po.currency_sk as ledger_currency_sk,
        po.billing_currency_sk as ledger_billing_currency_sk,
        po.settlement_currency_sk as ledger_settlement_currency_sk,
        po.transaction_link as posting_transaction_link,
        po.atm as ledger_atm,
        po.pos as ledger_pos,
        po.fees_fixed_amount as ledger_fees_fixed_amount,
        po.fees_rate_amount as ledger_fees_rate_amount,
        po.fx_padding_amount as ledger_fx_padding_amount,
        fee.fee_count,
        fee.fee_amount_sum,
        fee.fee_currency_sk,
        cast(null as bigint) as ehi_observation_count,
        cast(null as timestamp) as ehi_first_event_ts_utc,
        cast(null as timestamp) as ehi_last_event_ts_utc,
        cast(null as float) as observed_txn_amount,
        cast(null as float) as observed_billing_amount,
        cast(null as float) as observed_settlement_amount,
        cast(null as bigint) as observed_currency_sk,
        cast(null as bigint) as observed_billing_currency_sk,
        cast(null as bigint) as observed_settlement_currency_sk
    from {{ ref('fact_card_financial') }} f
    inner join week_dates w
        on w.date_sk = f.date_sk
    left join fin_stg_one fs
        on fs.source_system = f.source_system
       and fs.source_fin_id = f.source_fin_id
    left join {{ ref('fact_card_authorisation') }} a
        on a.auth_sk = f.auth_sk
    left join auth_stg_one aus
        on aus.source_system = f.source_system
       and aus.source_auth_id = f.source_auth_id
    left join posting_one po
        on po.processor_transaction_id = f.source_fin_id
       and (
            (f.source_system in ('gps_mc', 'gps_visa') and po.source_system in ('portal_b4b', 'portal_b4s'))
       )
    left join fees fee
        on fee.source_system = f.source_system
       and fee.source_tx_id = f.source_fin_id
),

fin_ids as (
    select distinct source_system, source_fin_id
    from {{ ref('fact_card_financial') }}
    where source_fin_id is not null
),

auth_ids as (
    select distinct source_system, source_auth_id
    from {{ ref('fact_card_authorisation') }}
    where source_auth_id is not null
),

declines as (
    select
        'decline|' || e.source_system || '|' || e.source_ledger_id as card_txn_nk,
        'decline' as txn_outcome,
        cast(null as bigint) as financial_sk,
        e.source_system,
        cast(null as varchar) as source_fin_id,
        e.source_ledger_id,
        a.auth_sk,
        e.processor_transaction_id as source_auth_id,
        e.processor_traceid as traceid_lifecycle,
        cast(null as varchar) as presentment_id,
        cast(null as varchar) as arn,
        cast(null as varchar) as network_transaction_id,
        e.card_sk,
        e.cardholder_sk,
        e.account_sk,
        e.entity_sk,
        cast(null as bigint) as card_product_sk,
        cast(null as bigint) as card_scheme_sk,
        e.processor_sk,
        e.currency_sk,
        e.billing_currency_sk,
        e.settlement_currency_sk,
        e.date_sk,
        cast(null as bigint) as settlement_date_sk,
        cast(null as bigint) as scheme_settlement_date_sk,
        cast(null as float) as txn_amount,
        cast(null as float) as billing_amount,
        cast(null as float) as settlement_amount,
        cast(null as float) as presentment_fee_amount,
        cast(null as float) as fee_amt_amount,
        nullif(trim(cast(e.mcc_code as varchar)), '') as mcc_code,
        e.merchant_country_code,
        cast(null as varchar) as acquirer_country_code,
        cast(null as varchar) as txn_code_type,
        cast(null as varchar) as txn_code_group,
        cast(null as varchar) as fee_class_code,
        cast(null as varchar) as settlement_indicator,
        e.card_token as processor_card_id,
        cast(null as varchar) as processor_program_id,
        cast(null as timestamp) as presentment_event_ts_utc,
        'none' as wallet,
        cast(null as varchar) as payment_token_type,
        cast(null as varchar) as payment_token_device_type,
        'unknown' as presentment_channel,
        'non_remote' as initiation,
        a.date_sk as auth_date_sk,
        a.settlement_date_sk as auth_settlement_date_sk,
        a.txn_amount as auth_txn_amount,
        a.billing_amount as auth_billing_amount,
        a.commission_amount as auth_commission_amount,
        a.fixed_fee_amount as auth_fixed_fee_amount,
        a.rate_fee_amount as auth_rate_fee_amount,
        coalesce(a.approved, 'no') as auth_approved,
        coalesce(a.response_code, e.response_code) as auth_response_code,
        coalesce(a.auth_code, e.auth_code) as auth_code,
        coalesce(
            nullif(trim(cast(a.mcc_code as varchar)), ''),
            nullif(trim(cast(e.mcc_code as varchar)), '')
        ) as auth_mcc_code,
        coalesce(a.merchant_country_code, e.merchant_country_code) as auth_merchant_country_code,
        a.acquirer_country_code as auth_acquirer_country_code,
        a.txn_code_type as auth_txn_code_type,
        a.txn_code_group as auth_txn_code_group,
        a.currency_sk as auth_currency_sk,
        a.billing_currency_sk as auth_billing_currency_sk,
        aus.auth_event_ts_utc,
        {{ normalize_wallet('aus.payment_token_wallet') }} as auth_wallet,
        {{ presentment_channel_from_flags(
            'cast(null as varchar)', '0', '0',
            "coalesce(nullif(trim(cast(a.mcc_code as varchar)), ''), nullif(trim(cast(e.mcc_code as varchar)), ''))"
        ) }} as auth_presentment_channel,
        cast(null as bigint) as posting_sk,
        cast(null as varchar) as posting_source_system,
        cast(null as varchar) as posting_source_ledger_id,
        cast(null as bigint) as posting_date_sk,
        cast(null as timestamp) as posting_event_ts_utc,
        cast(null as float) as ledger_txn_amount,
        cast(null as float) as ledger_billing_amount,
        cast(null as float) as ledger_settlement_amount,
        cast(null as bigint) as ledger_currency_sk,
        cast(null as bigint) as ledger_billing_currency_sk,
        cast(null as bigint) as ledger_settlement_currency_sk,
        e.transaction_link as posting_transaction_link,
        cast(null as integer) as ledger_atm,
        cast(null as integer) as ledger_pos,
        cast(null as float) as ledger_fees_fixed_amount,
        cast(null as float) as ledger_fees_rate_amount,
        cast(null as float) as ledger_fx_padding_amount,
        cast(null as bigint) as fee_count,
        cast(null as float) as fee_amount_sum,
        cast(null as bigint) as fee_currency_sk,
        1::bigint as ehi_observation_count,
        e.event_ts as ehi_first_event_ts_utc,
        e.event_ts as ehi_last_event_ts_utc,
        e.observed_txn_amount,
        e.observed_billing_amount,
        e.observed_settlement_amount,
        e.currency_sk as observed_currency_sk,
        e.billing_currency_sk as observed_billing_currency_sk,
        e.settlement_currency_sk as observed_settlement_currency_sk
    from {{ ref('fact_card_ehi_observation') }} e
    inner join week_dates w
        on w.date_sk = e.date_sk
    left join fin_ids fi
        on fi.source_fin_id = e.processor_transaction_id
    left join auth_ids ai
        on ai.source_auth_id = e.processor_transaction_id
    left join {{ ref('fact_card_authorisation') }} a
        on a.source_system = case
            when lower(coalesce(e.processor_code_raw, '')) like '%visa%' then 'gps_visa'
            else 'gps_mc'
        end
       and a.source_auth_id = e.processor_transaction_id
    left join auth_stg_one aus
        on aus.source_auth_id = e.processor_transaction_id
    where coalesce(e.declined, 0) = 1
      and fi.source_fin_id is null
),

combined as (
    select * from presentments
    union all
    select * from declines
)

select
    {{ sk_hash_ready("'card_txn'", 'card_txn_nk') }} as card_txn_sk,
    c.card_txn_nk,
    c.txn_outcome,
    case
        when c.posting_source_system = 'portal_b4b' then 'B4B'
        when c.posting_source_system = 'portal_b4s' then 'B4S'
        when c.source_system = 'portal_b4b' then 'B4B'
        when c.source_system = 'portal_b4s' then 'B4S'
        when nullif(trim(ent.product), '') is not null then ent.product
        when acc.source_system = 'portal_b4b' then 'B4B'
        when acc.source_system = 'portal_b4s' then 'B4S'
        when acc.source_system = 'oversight' then 'OVERSIGHT'
        else cast(null as varchar)
    end as product,
    -- Denormalised for Cards BI so Cube SQL need not join accounts/entities on every tile.
    acc.b4b_legal_entity,
    acc.account_name as company_name,
    ent.entity_name,
    c.financial_sk,
    c.source_system,
    c.source_fin_id,
    c.source_ledger_id,
    c.auth_sk,
    c.source_auth_id,
    c.traceid_lifecycle,
    c.presentment_id,
    c.arn,
    c.network_transaction_id,
    c.card_sk,
    c.cardholder_sk,
    c.account_sk,
    c.entity_sk,
    c.card_product_sk,
    c.card_scheme_sk,
    c.processor_sk,
    pm.mcc_sk,
    am.mcc_sk as auth_mcc_sk,
    c.currency_sk,
    c.billing_currency_sk,
    c.settlement_currency_sk,
    c.date_sk,
    c.settlement_date_sk,
    c.scheme_settlement_date_sk,
    coalesce(
        c.presentment_event_ts_utc,
        c.ehi_first_event_ts_utc,
        c.posting_event_ts_utc,
        c.auth_event_ts_utc
    ) as event_ts,
    c.txn_amount,
    c.billing_amount,
    c.settlement_amount,
    c.presentment_fee_amount,
    c.fee_amt_amount,
    c.mcc_code,
    pm.mcc_group,
    c.merchant_country_code,
    c.acquirer_country_code,
    c.txn_code_type,
    c.txn_code_group,
    c.fee_class_code,
    c.settlement_indicator,
    c.processor_card_id,
    c.processor_program_id,
    c.presentment_event_ts_utc,
    c.presentment_channel,
    c.initiation,
    c.wallet,
    c.payment_token_type,
    c.payment_token_device_type,
    case when c.presentment_channel = 'atm' then 1 else 0 end as is_atm,
    case when c.presentment_channel = 'pos' then 1 else 0 end as is_pos,
    case when c.presentment_channel = 'online' then 1 else 0 end as is_online,
    case
        when c.txn_outcome = 'presentment' and c.auth_sk is null then 1
        else 0
    end as missing_auth,
    case
        when c.txn_outcome = 'presentment' and c.posting_sk is null then 1
        else 0
    end as missing_posting,
    case
        when c.txn_outcome = 'decline' and c.auth_sk is null then 1
        else 0
    end as decline_missing_auth,
    c.auth_date_sk,
    c.auth_settlement_date_sk,
    c.auth_event_ts_utc,
    c.auth_txn_amount,
    c.auth_billing_amount,
    c.auth_commission_amount,
    c.auth_fixed_fee_amount,
    c.auth_rate_fee_amount,
    c.auth_approved,
    c.auth_response_code,
    c.auth_code,
    c.auth_mcc_code,
    c.auth_merchant_country_code,
    c.auth_acquirer_country_code,
    c.auth_txn_code_type,
    c.auth_txn_code_group,
    c.auth_currency_sk,
    c.auth_billing_currency_sk,
    c.auth_presentment_channel,
    c.auth_wallet,
    c.posting_sk,
    c.posting_source_system,
    c.posting_source_ledger_id,
    c.posting_date_sk,
    c.posting_event_ts_utc,
    c.ledger_txn_amount,
    c.ledger_billing_amount,
    c.ledger_settlement_amount,
    c.ledger_currency_sk,
    c.ledger_billing_currency_sk,
    c.ledger_settlement_currency_sk,
    c.posting_transaction_link,
    c.ledger_atm,
    c.ledger_pos,
    c.ledger_fees_fixed_amount,
    c.ledger_fees_rate_amount,
    c.ledger_fx_padding_amount,
    c.fee_count,
    c.fee_amount_sum,
    c.fee_currency_sk,
    c.ehi_observation_count,
    c.ehi_first_event_ts_utc,
    c.ehi_last_event_ts_utc,
    c.observed_txn_amount,
    c.observed_billing_amount,
    c.observed_settlement_amount,
    c.observed_currency_sk,
    c.observed_billing_currency_sk,
    c.observed_settlement_currency_sk,
    getdate() as loaded_at
from combined c
left join {{ ref('dim_mcc') }} pm
    on pm.mcc_code = lpad(trim(cast(c.mcc_code as varchar)), 4, '0')
left join {{ ref('dim_mcc') }} am
    on am.mcc_code = lpad(trim(cast(c.auth_mcc_code as varchar)), 4, '0')
left join {{ ref('dim_entity') }} ent
    on ent.entity_sk = c.entity_sk
left join {{ ref('dim_account') }} acc
    on acc.account_sk = c.account_sk
