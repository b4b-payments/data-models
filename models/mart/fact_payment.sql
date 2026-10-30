{{ config(
    alias='fact_payment',
    tags=['payments', 'mart'],
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['source_system', 'source_payment_id'],
    on_schema_change='append_new_columns',
    dist='entity_sk',
    sort=['date_sk', 'source_system'],
    pre_hook=["{{ delete_missing_fact_payments() }}"]
) }}

-- Grain: one portal payment notification (B4B or B4S), or one Oversight payment.
-- Incoming and outgoing. Deposit is only the incoming leg.
-- Portal account: COALESCE(payments.company_id, deposits.company_id, viban→company_id)
-- on the same portal, then dim_account / entity_sk via that company.
-- An incremental run first deletes a changed key that is no longer in staging.

with
{% if is_incremental() %}
changed_bctn as (
    select source_system, business_key
    from {{ source('spike_ops', 'pipeline_changed_key') }}
    where run_id = '{{ var("pipeline_run_id", "") }}'
      and key_role = 'bctn_id'
),
changed_oversight as (
    select business_key
    from {{ source('spike_ops', 'pipeline_changed_key') }}
    where run_id = '{{ var("pipeline_run_id", "") }}'
      and key_role = 'oversight_payment_id'
),
{% endif %}
oversight as (
    select
        'oversight' as source_system,
        cast(p.id as varchar) as source_payment_id,
        a.account_sk,
        a.entity_sk,
        rc.id as rail_sk,
        cur.id as currency_sk,
        d.id as date_sk,
        p.created_at as event_ts,
        p.amount,
        p.status as payment_status,
        -- Oversight is outbound initiation. Successful rows have payment.classification;
        -- failed BC error JSON has none — default those to Outgoing (not unknown).
        coalesce(
            nullif(
                json_extract_path_text(p.banking_circle_api_response, 'payment', 'classification'),
                ''
            ),
            'Outgoing'
        ) as payment_direction,
        case
            when p.sca_applied then true
            when p.sca_applied is false then false
            else null
        end as sca_applied,
        {{ sk_hash_ready("'oversight'", "nullif(trim(p.status), '')") }} as payment_status_sk,
        {{ sk_hash_ready("'oversight'", "nullif(trim(p.status), '')") }} as source_status_sk,
        {{ profile_sk(
            "coalesce(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'classification'), ''), 'Outgoing')",
            "case when p.sca_applied then true when p.sca_applied is false then false else null end",
            "p.status = 'Returned'",
            "p.status = 'Reversed'",
            "a.account_sk is not null",
            "rc.id is not null"
        ) }} as payment_profile_sk,
        {{ sk_hash_ready("'oversight_error'", oversight_error_code('p.banking_circle_api_response')) }} as failure_reason_sk,
        {{ sk_hash_ready(
            "'oversight'",
            "case when nullif(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'paymentRail')), '') is null and nullif(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'subClassification')), '') is null then null else coalesce(nullif(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'paymentRail')), ''), '') || '|' || coalesce(nullif(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'subClassification')), ''), '') end"
        ) }} as payment_type_sk,
        d.id as transaction_date_sk,
        vd.id as value_date_sk,
        sd.id as status_updated_date_sk,
        case
            when coalesce(
                nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'processedTimestamp'), ''),
                nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'latestStatusChangedTimestamp'), '')
            ) is null then cast(null as timestamp)
            else cast(replace(split_part(coalesce(
                nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'processedTimestamp'), ''),
                nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'latestStatusChangedTimestamp'), '')
            ), '+', 1), 'T', ' ') as timestamp)
        end as status_updated_at,
        case
            when coalesce(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'classification'), ''), 'Outgoing') = 'Incoming'
                then {{ sk_hash_ready("'OVERSIGHT'", "nullif(trim(cast(p.beneficiary_id as varchar)), '')") }}
            else {{ sk_unknown() }}
        end as debtor_party_sk,
        case
            when coalesce(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'classification'), ''), 'Outgoing') = 'Incoming'
                then {{ sk_unknown() }}
            else {{ sk_hash_ready("'OVERSIGHT'", "nullif(trim(cast(p.beneficiary_id as varchar)), '')") }}
        end as creditor_party_sk,
        {{ country_sk("json_extract_path_text(p.banking_circle_api_response, 'payment', 'transfer', 'debtorAccount', 'country')") }} as debtor_country_sk,
        {{ country_sk("json_extract_path_text(p.banking_circle_api_response, 'payment', 'transfer', 'creditorAccount', 'country')") }} as creditor_country_sk,
        cast(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'debtorInformation', 'debitAmount', 'amount'), '') as decimal(18, 4)) as instructed_amount,
        icur.id as instructed_currency_sk,
        cast(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'transfer', 'amount', 'amount'), '') as decimal(18, 4)) as settled_amount,
        scur.id as settled_currency_sk
    from {{ source('spike_stg', 'stg_oversight_payments') }} p
    left join {{ ref('dim_account') }} a
        on a.source_system = 'oversight'
       and a.source_pk = cast(p.company_id as varchar)
    left join {{ source('spike_live', 'dim_payment_rail') }} rc
        on rc.rail_code = regexp_substr(
            json_extract_path_text(p.banking_circle_api_response, 'payment', 'transactionReference'),
            'F[0-9]{3}'
        )
       and nullif(rc.rail_code, '') is not null
    left join {{ source('spike_live', 'dim_currency') }} cur
        on cur.currency_code = upper(trim(p.currency))
    left join {{ source('spike_live', 'dim_date') }} d
        on d.calendar_date = cast(p.created_at as date)
    left join {{ source('spike_live', 'dim_date') }} vd
        on vd.calendar_date = cast(replace(split_part(nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'transfer', 'valueDate'), ''), '+', 1), 'T', ' ') as date)
    left join {{ source('spike_live', 'dim_date') }} sd
        on sd.calendar_date = cast(
            case
                when coalesce(
                    nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'processedTimestamp'), ''),
                    nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'latestStatusChangedTimestamp'), '')
                ) is null then cast(null as timestamp)
                else cast(replace(split_part(coalesce(
                    nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'processedTimestamp'), ''),
                    nullif(json_extract_path_text(p.banking_circle_api_response, 'payment', 'latestStatusChangedTimestamp'), '')
                ), '+', 1), 'T', ' ') as timestamp)
            end as date
        )
    left join {{ source('spike_live', 'dim_currency') }} icur
        on icur.currency_code = upper(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'debtorInformation', 'debitAmount', 'currency')))
    left join {{ source('spike_live', 'dim_currency') }} scur
        on scur.currency_code = upper(trim(json_extract_path_text(p.banking_circle_api_response, 'payment', 'transfer', 'amount', 'currency')))
    {% if is_incremental() %}
    where cast(p.id as varchar) in (select business_key from changed_oversight)
    {% endif %}
),

-- Latest portal payment row per BCTN (enrich company_id), per portal
pay_src as (
    select
        'portal_b4b' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id,
        status,
        updated_at,
        payment_amount,
        payment_currency
    from {{ source('spike_stg', 'stg_b4b_payments') }}
    where banking_circle_transaction_notification_id is not null
    {% if is_incremental() %}
      and cast(banking_circle_transaction_notification_id as varchar) in (
          select business_key from changed_bctn where source_system = 'portal_b4b'
      )
    {% endif %}
    union all
    select
        'portal_b4s' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id,
        status,
        updated_at,
        payment_amount,
        payment_currency
    from {{ source('spike_stg', 'stg_b4s_payments') }}
    where banking_circle_transaction_notification_id is not null
    {% if is_incremental() %}
      and cast(banking_circle_transaction_notification_id as varchar) in (
          select business_key from changed_bctn where source_system = 'portal_b4s'
      )
    {% endif %}
),

pay as (
    select
        source_system,
        banking_circle_transaction_notification_id,
        company_id,
        status,
        updated_at,
        payment_amount,
        payment_currency,
        row_number() over (
            partition by source_system, banking_circle_transaction_notification_id
            order by id desc
        ) as rn
    from pay_src
),

-- Latest deposit row per BCTN, per portal
dep_src as (
    select
        'portal_b4b' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id
    from {{ source('spike_stg', 'stg_b4b_company_deposits') }}
    where banking_circle_transaction_notification_id is not null
    {% if is_incremental() %}
      and cast(banking_circle_transaction_notification_id as varchar) in (
          select business_key from changed_bctn where source_system = 'portal_b4b'
      )
    {% endif %}
    union all
    select
        'portal_b4s' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id
    from {{ source('spike_stg', 'stg_b4s_company_deposits') }}
    where banking_circle_transaction_notification_id is not null
    {% if is_incremental() %}
      and cast(banking_circle_transaction_notification_id as varchar) in (
          select business_key from changed_bctn where source_system = 'portal_b4s'
      )
    {% endif %}
),

dep as (
    select
        source_system,
        banking_circle_transaction_notification_id,
        company_id,
        row_number() over (
            partition by source_system, banking_circle_transaction_notification_id
            order by id desc
        ) as rn
    from dep_src
),

-- VIBAN number → company, one company per viban on that portal
vb_src as (
    select
        'portal_b4b' as source_system,
        v.viban_number,
        cv.company_id
    from {{ source('spike_stg', 'stg_b4b_vibans') }} v
    inner join {{ source('spike_stg', 'stg_b4b_companies_vibans') }} cv
        on cv.viban_id = v.id
    where v.banking_circle_client_number is not null
      and nullif(trim(v.viban_number), '') is not null
    {% if is_incremental() %}
      and v.viban_number in (
          select b.viban_number
          from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }} b
          where cast(b.id as varchar) in (
              select business_key from changed_bctn where source_system = 'portal_b4b'
          )
      )
    {% endif %}
    union all
    select
        'portal_b4s' as source_system,
        v.viban_number,
        cv.company_id
    from {{ source('spike_stg', 'stg_b4s_vibans') }} v
    inner join {{ source('spike_stg', 'stg_b4s_companies_vibans') }} cv
        on cv.viban_id = v.id
    where v.banking_circle_client_number is not null
      and nullif(trim(v.viban_number), '') is not null
    {% if is_incremental() %}
      and v.viban_number in (
          select b.viban_number
          from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }} b
          where cast(b.id as varchar) in (
              select business_key from changed_bctn where source_system = 'portal_b4s'
          )
      )
    {% endif %}
),

vb as (
    select
        source_system,
        viban_number,
        company_id,
        row_number() over (
            partition by source_system, viban_number
            order by company_id
        ) as rn
    from vb_src
),

bctn as (
    select
        'portal_b4b' as source_system,
        id,
        transaction_date,
        value_date,
        created_at,
        transfer_amount,
        transaction_amount,
        status,
        credit_debit_indicator,
        viban_number,
        booking_reference,
        transfer_amount_currency,
        transaction_amount_currency,
        processed,
        returned,
        return_code,
        message,
        transaction_type,
        counterparty,
        counterparty_account,
        counterparty_country,
        counterparty_financial_institution
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    {% if is_incremental() %}
    where cast(id as varchar) in (
        select business_key from changed_bctn where source_system = 'portal_b4b'
    )
    {% endif %}
    union all
    select
        'portal_b4s' as source_system,
        id,
        transaction_date,
        value_date,
        created_at,
        transfer_amount,
        transaction_amount,
        status,
        credit_debit_indicator,
        viban_number,
        booking_reference,
        transfer_amount_currency,
        transaction_amount_currency,
        case
            when processed = 1 then true
            when processed = 0 then false
            else cast(null as boolean)
        end as processed,
        case
            when returned = 1 then true
            when returned = 0 then false
            else cast(null as boolean)
        end as returned,
        return_code,
        message,
        transaction_type,
        counterparty,
        counterparty_account,
        counterparty_country,
        counterparty_financial_institution
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
    {% if is_incremental() %}
    where cast(id as varchar) in (
        select business_key from changed_bctn where source_system = 'portal_b4s'
    )
    {% endif %}
),

portal as (
    select
        bctn.source_system,
        cast(bctn.id as varchar) as source_payment_id,
        a.account_sk,
        a.entity_sk,
        rc.id as rail_sk,
        cur.id as currency_sk,
        d.id as date_sk,
        coalesce(bctn.transaction_date, bctn.value_date, bctn.created_at) as event_ts,
        coalesce(bctn.transfer_amount, bctn.transaction_amount) as amount,
        bctn.status as payment_status,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'DEBIT' then 'Outgoing'
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT' then 'Incoming'
            else bctn.credit_debit_indicator
        end as payment_direction,
        cast(null as boolean) as sca_applied,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'DEBIT'
             and nullif(trim(pay.status), '') is not null
                then {{ sk_hash_ready("'portal_payments'", "nullif(trim(pay.status), '')") }}
            else {{ sk_hash_ready(
                "'bctn_flags'",
                "case when bctn.returned is true then 'returned' when bctn.status = 'failed' then 'failed' when bctn.processed is true then 'processed' else 'pending' end"
            ) }}
        end as payment_status_sk,
        {{ sk_hash_ready("'bctn'", "nullif(trim(bctn.status), '')") }} as source_status_sk,
        {{ profile_sk(
            "case when upper(coalesce(bctn.credit_debit_indicator, '')) = 'DEBIT' then 'Outgoing' when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT' then 'Incoming' else bctn.credit_debit_indicator end",
            "cast(null as boolean)",
            "coalesce(bctn.returned, false) or pay.status = 'Returned'",
            "pay.status = 'Reversed'",
            "a.account_sk is not null",
            "rc.id is not null"
        ) }} as payment_profile_sk,
        {{ sk_hash_ready("'bctn_return_code'", "nullif(trim(bctn.return_code), '')") }} as failure_reason_sk,
        {{ sk_hash_ready("'bctn'", "nullif(trim(bctn.transaction_type), '')") }} as payment_type_sk,
        td.id as transaction_date_sk,
        vd.id as value_date_sk,
        sd.id as status_updated_date_sk,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'DEBIT'
             and pay.status in ('Processed', 'Rejected', 'Returned', 'Reversed', 'ERROR', 'Error')
                then pay.updated_at
            else cast(null as timestamp)
        end as status_updated_at,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT'
                then {{ sk_hash_ready("case bctn.source_system when 'portal_b4b' then 'B4B' when 'portal_b4s' then 'B4S' else bctn.source_system end", "nullif(trim(bctn.counterparty_account), '')") }}
            else {{ sk_unknown() }}
        end as debtor_party_sk,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT'
                then {{ sk_unknown() }}
            else {{ sk_hash_ready("case bctn.source_system when 'portal_b4b' then 'B4B' when 'portal_b4s' then 'B4S' else bctn.source_system end", "nullif(trim(bctn.counterparty_account), '')") }}
        end as creditor_party_sk,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT'
                then {{ country_sk('bctn.counterparty_country') }}
            else {{ sk_unknown() }}
        end as debtor_country_sk,
        case
            when upper(coalesce(bctn.credit_debit_indicator, '')) = 'CREDIT'
                then {{ sk_unknown() }}
            else {{ country_sk('bctn.counterparty_country') }}
        end as creditor_country_sk,
        cast(pay.payment_amount as decimal(18, 4)) as instructed_amount,
        icur.id as instructed_currency_sk,
        cast(null as decimal(18, 4)) as settled_amount,
        cast(null as integer) as settled_currency_sk
    from bctn
    left join pay
        on pay.source_system = bctn.source_system
       and pay.banking_circle_transaction_notification_id = bctn.id
       and pay.rn = 1
    left join dep
        on dep.source_system = bctn.source_system
       and dep.banking_circle_transaction_notification_id = bctn.id
       and dep.rn = 1
    left join vb
        on vb.source_system = bctn.source_system
       and vb.viban_number = bctn.viban_number
       and vb.rn = 1
    left join {{ ref('dim_account') }} a
        on a.source_system = bctn.source_system
       and a.source_pk = cast(
            coalesce(pay.company_id, dep.company_id, vb.company_id) as varchar
        )
    left join {{ source('spike_live', 'dim_payment_rail') }} rc
        on rc.rail_code = regexp_substr(bctn.booking_reference, 'F[0-9]{3}')
       and nullif(rc.rail_code, '') is not null
    left join {{ source('spike_live', 'dim_currency') }} cur
        on cur.currency_code = upper(trim(coalesce(
            bctn.transfer_amount_currency,
            bctn.transaction_amount_currency
        )))
    left join {{ source('spike_live', 'dim_date') }} d
        on d.calendar_date = cast(
            coalesce(bctn.transaction_date, bctn.value_date, bctn.created_at) as date
        )
    left join {{ source('spike_live', 'dim_date') }} td
        on td.calendar_date = cast(bctn.transaction_date as date)
    left join {{ source('spike_live', 'dim_date') }} vd
        on vd.calendar_date = cast(bctn.value_date as date)
    left join {{ source('spike_live', 'dim_date') }} sd
        on sd.calendar_date = cast(
            case
                when upper(coalesce(bctn.credit_debit_indicator, '')) = 'DEBIT'
                 and pay.status in ('Processed', 'Rejected', 'Returned', 'Reversed', 'ERROR', 'Error')
                    then pay.updated_at
                else cast(null as timestamp)
            end as date
        )
    left join {{ source('spike_live', 'dim_currency') }} icur
        on icur.currency_code = upper(trim(pay.payment_currency))
),

unioned as (
    select * from oversight
    union all
    select * from portal
),

final as (
    select
        fnv_hash(source_system || '|' || source_payment_id) as payment_sk,
        source_system,
        case source_system
            when 'portal_b4b' then 'B4B'
            when 'portal_b4s' then 'B4S'
            when 'oversight' then 'OVERSIGHT'
            else source_system
        end as product,
        source_payment_id,
        entity_sk,
        account_sk,
        rail_sk,
        currency_sk,
        date_sk,
        event_ts,
        amount,
        payment_status,
        payment_direction,
        sca_applied,
        payment_status_sk,
        source_status_sk,
        payment_profile_sk,
        failure_reason_sk,
        payment_type_sk,
        transaction_date_sk,
        value_date_sk,
        status_updated_date_sk,
        status_updated_at,
        debtor_party_sk,
        creditor_party_sk,
        debtor_country_sk,
        creditor_country_sk,
        instructed_amount,
        instructed_currency_sk,
        settled_amount,
        settled_currency_sk,
        getdate() as loaded_at,
        '{{ var("pipeline_run_id", "") }}' as batch_run_id
    from unioned
)

select * from final
