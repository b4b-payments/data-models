{{ config(
    alias='fact_payment',
    tags=['payments', 'mart'],
    dist='entity_sk',
    sort=['date_sk', 'source_system']
) }}

-- Grain: one portal payment notification (B4B or B4S), or one Oversight payment.
-- Incoming and outgoing. Deposit is only the incoming leg.
-- Portal account: COALESCE(payments.company_id, deposits.company_id, viban→company_id)
-- on the same portal, then dim_account / entity_sk via that company.

with oversight as (
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
        nullif(
            json_extract_path_text(p.banking_circle_api_response, 'payment', 'classification'),
            ''
        ) as payment_direction,
        case
            when p.sca_applied then true
            when p.sca_applied is false then false
            else null
        end as sca_applied
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
),

-- Latest portal payment row per BCTN (enrich company_id), per portal
pay_src as (
    select
        'portal_b4b' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id
    from {{ source('spike_stg', 'stg_b4b_payments') }}
    where banking_circle_transaction_notification_id is not null
    union all
    select
        'portal_b4s' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id
    from {{ source('spike_stg', 'stg_b4s_payments') }}
    where banking_circle_transaction_notification_id is not null
),

pay as (
    select
        source_system,
        banking_circle_transaction_notification_id,
        company_id,
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
    union all
    select
        'portal_b4s' as source_system,
        id,
        banking_circle_transaction_notification_id,
        company_id
    from {{ source('spike_stg', 'stg_b4s_company_deposits') }}
    where banking_circle_transaction_notification_id is not null
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
        transaction_amount_currency
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
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
        transaction_amount_currency
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
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
        cast(null as boolean) as sca_applied
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
),

unioned as (
    select * from oversight
    union all
    select * from portal
),

final as (
    select
        row_number() over (order by source_system, source_payment_id) as payment_sk,
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
        getdate() as loaded_at
    from unioned
)

select * from final
