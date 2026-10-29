{{ config(
    alias='dim_card_scheme',
    tags=['cards', 'mart']
) }}

-- Grain: one scheme code, from portal card products.
-- GPS facts resolve Mastercard or Visa from source_system against scheme_code.

with codes as (
    select distinct lower(trim(card_scheme)) as scheme_code
    from {{ source('spike_stg', 'stg_b4b_card_products') }}
    where nullif(trim(card_scheme), '') is not null

    union

    select distinct lower(trim(card_scheme)) as scheme_code
    from {{ source('spike_stg', 'stg_b4s_card_products') }}
    where nullif(trim(card_scheme), '') is not null

    union

    select 'mastercard' as scheme_code

    union

    select 'visa' as scheme_code
)

select
    row_number() over (order by scheme_code) as card_scheme_sk,
    scheme_code,
    scheme_code as scheme_name
from codes
