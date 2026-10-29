{{ config(
    alias='dim_card',
    tags=['cards', 'mart']
) }}

-- Grain: one portal card (cards.id) on B4B or B4S.
-- Account path is cards.user_id -> users.company_id -> dim_account.
-- A company with no legal entity is not in dim_account. The card remains.
-- entity_sk stays empty. Full PAN and pan_token are not on this table.

with cards as (
    select
        'portal_b4b' as source_system,
        id,
        cardholder_id,
        user_id,
        product,
        status,
        virtual,
        last_4_digits,
        expiry_date,
        processor_card_id,
        processor_token,
        processor_node
    from {{ source('spike_stg', 'stg_b4b_cards') }}

    union all

    select
        'portal_b4s' as source_system,
        id,
        cardholder_id,
        user_id,
        product,
        status,
        virtual,
        last_4_digits,
        expiry_date,
        processor_card_id,
        processor_token,
        processor_node
    from {{ source('spike_stg', 'stg_b4s_cards') }}
),

users as (
    select 'portal_b4b' as source_system, id, company_id
    from {{ source('spike_stg', 'stg_b4b_users') }}

    union all

    select 'portal_b4s' as source_system, id, company_id
    from {{ source('spike_stg', 'stg_b4s_users') }}
)

select
    row_number() over (order by c.source_system, c.id) as card_sk,
    c.source_system,
    cast(c.id as varchar) as source_card_id,
    h.cardholder_sk,
    a.account_sk,
    a.entity_sk,
    p.card_product_sk,
    s.card_scheme_sk,
    pr.processor_sk,
    c.status,
    c.virtual,
    c.last_4_digits,
    c.expiry_date,
    nullif(trim(c.processor_card_id), '') as processor_card_id,
    c.processor_token,
    c.processor_node,
    getdate() as loaded_at
from cards c
left join users u
    on u.source_system = c.source_system
   and u.id = c.user_id
left join {{ ref('dim_account') }} a
    on a.source_system = c.source_system
   and a.source_pk = cast(u.company_id as varchar)
left join {{ ref('dim_cardholder') }} h
    on h.source_system = c.source_system
   and h.source_cardholder_id = cast(c.cardholder_id as varchar)
left join {{ ref('dim_card_product') }} p
    on p.source_system = c.source_system
   and nullif(trim(p.product_code), '') = nullif(trim(c.product), '')
left join {{ ref('dim_card_scheme') }} s
    on s.scheme_code = p.scheme_code
left join {{ ref('dim_processor') }} pr
    on pr.processor_code = lower(trim(p.processor_code_raw))
