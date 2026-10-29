{{ config(
    alias='fact_card_load',
    tags=['cards', 'mart'],
    sort=['date_sk', 'source_system']
) }}

-- Grain: one load or unload instruction.
-- Portal and GPS rows share the fact and stay apart on source_system.
-- A customer load total uses successful portal rows only. GPS amounts are not added.
-- Unload amounts are negative.

with portal as (
    select
        'portal_b4b' as source_system,
        'load' as direction,
        cast(id as varchar) as source_load_id,
        cast(null as varchar) as related_source_load_id,
        nullif(trim(processor_card_id), '') as processor_card_id,
        company_id,
        cast(coalesce(transaction_date, created_on) as date) as txn_date,
        cast(null as date) as settlement_date,
        case when lower(direction_label) = 'unload' then -abs(amount) else abs(amount) end as amount,
        cast(null as decimal(18, 2)) as fixed_fee_amount,
        cast(null as decimal(18, 2)) as rate_fee_amount,
        successful,
        nullif(trim(processor_ref), '') as processor_ref,
        cast(null as varchar) as voided_load_id,
        channel,
        upper(trim(currency)) as currency_code
    from (
        select
            id,
            processor_card_id,
            company_id,
            transaction_date,
            created_on,
            amount,
            successful,
            processor_ref,
            channel,
            currency,
            'load' as direction_label
        from {{ source('spike_stg', 'stg_b4b_card_loads') }}
    ) l

    union all

    select
        'portal_b4b' as source_system,
        'unload' as direction,
        cast(id as varchar) as source_load_id,
        cast(card_load_id as varchar) as related_source_load_id,
        nullif(trim(processor_card_id), '') as processor_card_id,
        company_id,
        cast(created_at as date) as txn_date,
        cast(null as date) as settlement_date,
        -abs(amount) as amount,
        cast(null as decimal(18, 2)) as fixed_fee_amount,
        cast(null as decimal(18, 2)) as rate_fee_amount,
        successful,
        nullif(trim(processor_ref), '') as processor_ref,
        cast(null as varchar) as voided_load_id,
        channel,
        upper(trim(currency)) as currency_code
    from {{ source('spike_stg', 'stg_b4b_card_unloads') }}

    union all

    select
        'portal_b4s' as source_system,
        'load' as direction,
        cast(id as varchar) as source_load_id,
        cast(null as varchar) as related_source_load_id,
        nullif(trim(processor_card_id), '') as processor_card_id,
        company_id,
        cast(coalesce(transaction_date, created_on) as date) as txn_date,
        cast(null as date) as settlement_date,
        abs(amount) as amount,
        cast(null as decimal(18, 2)) as fixed_fee_amount,
        cast(null as decimal(18, 2)) as rate_fee_amount,
        successful,
        nullif(trim(processor_ref), '') as processor_ref,
        cast(null as varchar) as voided_load_id,
        channel,
        upper(trim(currency)) as currency_code
    from {{ source('spike_stg', 'stg_b4s_card_loads') }}

    union all

    select
        'portal_b4s' as source_system,
        'unload' as direction,
        cast(id as varchar) as source_load_id,
        cast(card_load_id as varchar) as related_source_load_id,
        nullif(trim(processor_card_id), '') as processor_card_id,
        company_id,
        cast(created_at as date) as txn_date,
        cast(null as date) as settlement_date,
        -abs(amount) as amount,
        cast(null as decimal(18, 2)) as fixed_fee_amount,
        cast(null as decimal(18, 2)) as rate_fee_amount,
        successful,
        nullif(trim(processor_ref), '') as processor_ref,
        cast(null as varchar) as voided_load_id,
        channel,
        upper(trim(currency)) as currency_code
    from {{ source('spike_stg', 'stg_b4s_card_unloads') }}
),

gps as (
    select
        'gps_mc' as source_system,
        g.*
    from {{ source('spike_stg', 'stg_gps_mc_card_load_unload') }} g

    union all

    select
        'gps_visa' as source_system,
        g.*
    from {{ source('spike_stg', 'stg_gps_visa_card_load_unload') }} g
),

gps_shaped as (
    select
        g.source_system,
        lower(trim(cast(g.recordtype as varchar))) as direction,
        nullif(trim(g.loadunloadid), '') as source_load_id,
        cast(null as varchar) as related_source_load_id,
        nullif(trim(g.cardid), '') as processor_card_id,
        cast(null as bigint) as company_id,
        cast(g.localdate as date) as txn_date,
        g.settlementdate as settlement_date,
        case
            when upper(trim(cast(g.recordtype as varchar))) = 'UNLOAD' then -abs(g."amount-value")
            when upper(trim(cast(g.recordtype as varchar))) = 'LOAD' then abs(g."amount-value")
            else g."amount-value"
        end as amount,
        g."load-fixedfee" as fixed_fee_amount,
        g."load-rate_fee" as rate_fee_amount,
        cast(null as integer) as successful,
        nullif(trim(g.loadunloadid), '') as processor_ref,
        nullif(trim(cast(g.voidedloadunloadid as varchar)), '') as voided_load_id,
        cast(g."load-source" as varchar) as channel,
        upper(trim(g."amount-currency")) as currency_code,
        nullif(trim(g."card-programid"), '') as processor_program_id
    from gps g
),

shaped as (
    select
        source_system,
        direction,
        source_load_id,
        related_source_load_id,
        processor_card_id,
        cast(company_id as varchar) as company_id,
        txn_date,
        settlement_date,
        cast(amount as decimal(18, 4)) as amount,
        cast(fixed_fee_amount as decimal(18, 4)) as fixed_fee_amount,
        cast(rate_fee_amount as decimal(18, 4)) as rate_fee_amount,
        successful,
        processor_ref,
        voided_load_id,
        cast(channel as varchar) as channel,
        currency_code,
        cast(null as varchar) as processor_program_id
    from portal

    union all

    select
        source_system,
        direction,
        source_load_id,
        related_source_load_id,
        processor_card_id,
        cast(company_id as varchar) as company_id,
        txn_date,
        settlement_date,
        cast(amount as decimal(18, 4)) as amount,
        cast(fixed_fee_amount as decimal(18, 4)) as fixed_fee_amount,
        cast(rate_fee_amount as decimal(18, 4)) as rate_fee_amount,
        successful,
        processor_ref,
        voided_load_id,
        cast(channel as varchar) as channel,
        currency_code,
        processor_program_id
    from gps_shaped
)

select
    row_number() over (
        order by s.source_system, s.direction, s.source_load_id
    ) as load_sk,
    s.source_system,
    s.source_load_id,
    s.direction,
    s.related_source_load_id,
    case when upper(s.processor_program_id) like 'WV%' then null else c.card_sk end as card_sk,
    case when upper(s.processor_program_id) like 'WV%' then null else c.cardholder_sk end as cardholder_sk,
    case
        when upper(s.processor_program_id) like 'WV%' then null
        when s.source_system in ('portal_b4b', 'portal_b4s') then a.entity_sk
        else c.entity_sk
    end as entity_sk,
    case
        when upper(s.processor_program_id) like 'WV%' then null
        when s.source_system in ('portal_b4b', 'portal_b4s') then a.account_sk
        else c.account_sk
    end as account_sk,
    p.processor_sk,
    case when upper(s.processor_program_id) like 'WV%' then null else c.card_product_sk end as card_product_sk,
    cur.id as currency_sk,
    d.id as date_sk,
    sd.id as settlement_date_sk,
    s.amount,
    s.fixed_fee_amount,
    s.rate_fee_amount,
    s.successful,
    s.processor_ref,
    s.processor_card_id,
    s.voided_load_id,
    s.channel,
    getdate() as loaded_at
from shaped s
left join (
    {{ unique_portal_cards() }}
) c
    on c.processor_card_id = s.processor_card_id
left join {{ ref('dim_account') }} a
    on a.source_system = s.source_system
   and a.source_pk = s.company_id
   and s.source_system in ('portal_b4b', 'portal_b4s')
left join {{ ref('dim_processor') }} p
    on p.processor_code = case
        when s.source_system in ('gps_mc', 'gps_visa') then s.source_system
    end
left join {{ source('spike_live', 'dim_currency') }} cur
    on cur.currency_code = s.currency_code
left join {{ source('spike_live', 'dim_date') }} d
    on d.calendar_date = s.txn_date
left join {{ source('spike_live', 'dim_date') }} sd
    on sd.calendar_date = s.settlement_date
