{{ config(
    alias='dim_card_product',
    tags=['cards', 'mart']
) }}

-- Grain: one portal card product. Natural key source_system + product code.
-- The same code can exist on B4B and on B4S. source_system keeps them apart.

with products as (
    select
        'portal_b4b' as source_system,
        id as source_product_id,
        code as product_code,
        currency,
        ica,
        country_of_issuance,
        processor,
        bin_type,
        card_scheme,
        active
    from {{ source('spike_stg', 'stg_b4b_card_products') }}

    union all

    select
        'portal_b4s' as source_system,
        id as source_product_id,
        code as product_code,
        currency,
        ica,
        country_of_issuance,
        processor,
        bin_type,
        card_scheme,
        active
    from {{ source('spike_stg', 'stg_b4s_card_products') }}
)

select
    row_number() over (order by source_system, source_product_id) as card_product_sk,
    source_system,
    cast(source_product_id as varchar) as source_product_id,
    product_code,
    upper(trim(currency)) as currency_code,
    cast(ica as varchar) as ica,
    country_of_issuance,
    processor as processor_code_raw,
    bin_type,
    lower(trim(card_scheme)) as scheme_code,
    active,
    getdate() as loaded_at
from products
