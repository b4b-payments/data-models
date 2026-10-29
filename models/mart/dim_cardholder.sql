{{ config(
    alias='dim_cardholder',
    tags=['cards', 'mart']
) }}

-- Grain: one portal cardholder. Personal attributes stay on this dimension.

with holders as (
    select
        'portal_b4b' as source_system,
        id,
        title,
        first_name,
        middle_name,
        last_name,
        dob,
        email,
        mobile
    from {{ source('spike_stg', 'stg_b4b_cardholders') }}

    union all

    select
        'portal_b4s' as source_system,
        id,
        title,
        first_name,
        middle_name,
        last_name,
        dob,
        email,
        mobile
    from {{ source('spike_stg', 'stg_b4s_cardholders') }}
)

select
    row_number() over (order by source_system, id) as cardholder_sk,
    source_system,
    cast(id as varchar) as source_cardholder_id,
    title,
    first_name,
    middle_name,
    last_name,
    dob,
    email,
    mobile,
    getdate() as loaded_at
from holders
