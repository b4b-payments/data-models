{{ config(
    alias='dim_account',
    tags=['party', 'mart']
) }}

-- Grain: one portal/Oversight company = float/currency account.
-- Always links to CLE entity via entity_sk (portal). No GID on accounts.
--
-- Live staging column notes (portal companies):
--   display_name, name, currency, client_legal_entity_id, closed
--   NO trading_name / status / bc_company_number
-- Oversight companies:
--   legal_name, trading_name, client_id — NO name / enabled / bc_company_number
--   (bc_company_number + enabled live on oversight clients)

with portal_accounts as (
    select
        'portal_b4b' as source_system,
        cast(c.id as varchar) as source_pk,
        coalesce(c.display_name, c.name, cast(c.id as varchar)) as account_name,
        upper(trim(c.currency)) as currency_code,
        cast(c.client_legal_entity_id as varchar) as b4b_cle_id,
        case
            when c.closed then 'closed'
            when c.closed is false then 'open'
            else null
        end as account_status,
        cast(null as varchar) as bc_company_number
    from {{ source('spike_stg', 'stg_b4b_companies') }} c
    where c.client_legal_entity_id is not null
),

oversight_accounts as (
    -- Oversight company is an account under an Agent.
    -- entity_sk stays null until that company is linked to a client legal entity.
    select
        'oversight' as source_system,
        cast(c.id as varchar) as source_pk,
        coalesce(c.legal_name, c.trading_name, cast(c.id as varchar)) as account_name,
        cast(null as varchar) as currency_code,
        cast(null as varchar) as b4b_cle_id,
        case
            when cl.enabled then 'enabled'
            when cl.enabled is false then 'disabled'
            else null
        end as account_status,
        cast(cl.bc_company_number as varchar) as bc_company_number
    from {{ source('spike_stg', 'stg_oversight_companies') }} c
    left join {{ source('spike_stg', 'stg_oversight_clients') }} cl
        on cl.id = c.client_id
),

unioned as (
    select * from portal_accounts
    union all
    select * from oversight_accounts
),

joined as (
    select
        row_number() over (order by u.source_system, u.source_pk) as account_sk,
        e.entity_sk,
        u.source_system,
        u.source_pk,
        u.account_name,
        cur.id as currency_sk,
        u.account_status,
        u.bc_company_number,
        getdate() as loaded_at
    from unioned u
    left join {{ ref('dim_entity') }} e
        on e.source_system = 'portal_b4b'
       and e.entity_type = 'PSU'
       and e.source_pk = u.b4b_cle_id
    left join {{ source('spike_live', 'dim_currency') }} cur
        on cur.currency_code = u.currency_code
)

select
    account_sk,
    entity_sk,
    source_system,
    source_pk,
    account_name,
    currency_sk,
    account_status,
    bc_company_number,
    loaded_at
from joined
