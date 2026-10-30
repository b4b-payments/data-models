{{ config(
    alias='dim_party',
    tags=['payments', 'mart'],
    materialized='incremental',
    incremental_strategy='append',
    unique_key='party_sk',
    dist='party_sk',
    sort='party_sk'
) }}

-- One external party per product and trimmed account (B4B, B4S),
-- or per product and beneficiary_id (OVERSIGHT).
-- The raw account number is not stored. party_token is sha2 of the natural key.
-- A tick inserts a key that is not already present. The weekly full refresh
-- sets the display name to the most common non-blank spelling and fills the counts.

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
pay as (
    select
        source_system,
        banking_circle_transaction_notification_id,
        company_id,
        row_number() over (
            partition by source_system, banking_circle_transaction_notification_id
            order by id desc
        ) as rn
    from (
        select
            'portal_b4b' as source_system,
            id,
            banking_circle_transaction_notification_id,
            company_id
        from {{ source('spike_stg', 'stg_b4b_payments') }}
        where banking_circle_transaction_notification_id is not null
        {% if is_incremental() %}
          and cast(banking_circle_transaction_notification_id as varchar) in (
              select business_key from changed_bctn where source_system = 'portal_b4b'
          )
        {% endif %}
        union all
        select
            'portal_b4s',
            id,
            banking_circle_transaction_notification_id,
            company_id
        from {{ source('spike_stg', 'stg_b4s_payments') }}
        where banking_circle_transaction_notification_id is not null
        {% if is_incremental() %}
          and cast(banking_circle_transaction_notification_id as varchar) in (
              select business_key from changed_bctn where source_system = 'portal_b4s'
          )
        {% endif %}
    ) pay_src
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
    from (
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
            'portal_b4s',
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
    ) dep_src
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
    from (
        select
            'portal_b4b' as source_system,
            v.viban_number,
            cv.company_id
        from {{ source('spike_stg', 'stg_b4b_vibans') }} v
        inner join {{ source('spike_stg', 'stg_b4b_companies_vibans') }} cv
            on cv.viban_id = v.id
        where nullif(trim(v.viban_number), '') is not null
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
            'portal_b4s',
            v.viban_number,
            cv.company_id
        from {{ source('spike_stg', 'stg_b4s_vibans') }} v
        inner join {{ source('spike_stg', 'stg_b4s_companies_vibans') }} cv
            on cv.viban_id = v.id
        where nullif(trim(v.viban_number), '') is not null
        {% if is_incremental() %}
          and v.viban_number in (
              select b.viban_number
              from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }} b
              where cast(b.id as varchar) in (
                  select business_key from changed_bctn where source_system = 'portal_b4s'
              )
          )
        {% endif %}
    ) vb_src
),
bctn as (
    select
        'B4B' as product,
        'portal_b4b' as source_system,
        id,
        nullif(trim(counterparty_account), '') as natural_key,
        nullif(trim(counterparty), '') as party_name,
        nullif(trim(counterparty_financial_institution), '') as institution,
        nullif(upper(trim(counterparty_country)), '') as country_code,
        viban_number
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    {% if is_incremental() %}
    where cast(id as varchar) in (
        select business_key from changed_bctn where source_system = 'portal_b4b'
    )
    {% endif %}
    union all
    select
        'B4S',
        'portal_b4s',
        id,
        nullif(trim(counterparty_account), ''),
        nullif(trim(counterparty), ''),
        nullif(trim(counterparty_financial_institution), ''),
        nullif(upper(trim(counterparty_country)), ''),
        viban_number
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
    {% if is_incremental() %}
    where cast(id as varchar) in (
        select business_key from changed_bctn where source_system = 'portal_b4s'
    )
    {% endif %}
),
portal_events as (
    select
        bctn.product,
        bctn.natural_key,
        bctn.party_name,
        bctn.institution,
        bctn.country_code,
        cast(coalesce(pay.company_id, dep.company_id, vb.company_id) as varchar) as company_id
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
    where bctn.natural_key is not null
),
oversight_events as (
    select
        'OVERSIGHT' as product,
        nullif(trim(cast(beneficiary_id as varchar)), '') as natural_key,
        nullif(trim(json_extract_path_text(
            banking_circle_api_response, 'payment', 'transfer', 'creditorName'
        )), '') as party_name,
        cast(null as varchar) as institution,
        nullif(upper(trim(json_extract_path_text(
            banking_circle_api_response, 'payment', 'transfer', 'creditorAccount', 'country'
        ))), '') as country_code,
        cast(company_id as varchar) as company_id
    from {{ source('spike_stg', 'stg_oversight_payments') }}
    where nullif(trim(cast(beneficiary_id as varchar)), '') is not null
    {% if is_incremental() %}
      and cast(id as varchar) in (select business_key from changed_oversight)
    {% endif %}
),
events as (
    select * from portal_events
    union all
    select * from oversight_events
),
name_ranked as (
    select
        product,
        natural_key,
        party_name,
        row_number() over (
            partition by product, natural_key
            order by count(*) desc, party_name
        ) as rn
    from events
    where party_name is not null
    group by product, natural_key, party_name
),
institution_ranked as (
    select
        product,
        natural_key,
        institution,
        row_number() over (
            partition by product, natural_key
            order by count(*) desc, institution
        ) as rn
    from events
    where institution is not null
    group by product, natural_key, institution
),
country_ranked as (
    select
        product,
        natural_key,
        country_code,
        row_number() over (
            partition by product, natural_key
            order by count(*) desc, country_code
        ) as rn
    from events
    where country_code is not null
    group by product, natural_key, country_code
),
counted as (
    select
        product,
        natural_key,
        count(distinct company_id) as client_count,
        count(distinct party_name) as name_count,
        count(distinct institution) as institution_count,
        count(distinct country_code) as country_count
    from events
    group by product, natural_key
),
keyed as (
    select
        fnv_hash(c.product || '|' || c.natural_key) as party_sk,
        c.product,
        sha2(c.natural_key, 256) as party_token,
        n.party_name as display_name,
        i.institution as display_institution,
        y.country_code as display_country_code,
        c.client_count,
        c.name_count,
        c.institution_count,
        c.country_count
    from counted c
    left join name_ranked n
        on n.product = c.product
       and n.natural_key = c.natural_key
       and n.rn = 1
    left join institution_ranked i
        on i.product = c.product
       and i.natural_key = c.natural_key
       and i.rn = 1
    left join country_ranked y
        on y.product = c.product
       and y.natural_key = c.natural_key
       and y.rn = 1
)

select * from keyed
{% if is_incremental() %}
where party_sk not in (select party_sk from {{ this }})
{% endif %}

union all

select
    {{ sk_unknown() }} as party_sk,
    cast(null as varchar) as product,
    cast(null as varchar) as party_token,
    'Unknown' as display_name,
    cast(null as varchar) as display_institution,
    cast(null as varchar) as display_country_code,
    cast(null as bigint) as client_count,
    cast(null as bigint) as name_count,
    cast(null as bigint) as institution_count,
    cast(null as bigint) as country_count
{% if is_incremental() %}
from (select 1) as unknown_row
where {{ sk_unknown() }} not in (select party_sk from {{ this }})
{% endif %}
