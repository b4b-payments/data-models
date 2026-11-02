{{ config(
    alias='dim_mcc',
    tags=['cards', 'mart']
) }}

-- Grain: one merchant category code (ISO / network MCC list).
-- Seed: seeds/mcc.csv (standard list + coarse mcc_group).
-- Codes seen on card facts but missing from the seed still get a row.

with seed as (
    select
        lpad(trim(cast(mcc_code as varchar)), 4, '0') as mcc_code,
        nullif(trim(mcc_name), '') as mcc_name,
        nullif(trim(mcc_group), '') as mcc_group
    from {{ ref('mcc') }}
),

seen as (
    select distinct lpad(trim(cast(mcc_code as varchar)), 4, '0') as mcc_code
    from {{ ref('fact_card_financial') }}
    where nullif(trim(cast(mcc_code as varchar)), '') is not null

    union

    select distinct lpad(trim(cast(mcc_code as varchar)), 4, '0')
    from {{ ref('fact_card_authorisation') }}
    where nullif(trim(cast(mcc_code as varchar)), '') is not null

    union

    select distinct lpad(trim(cast(mcc_code as varchar)), 4, '0')
    from {{ ref('fact_card_ehi_observation') }}
    where nullif(trim(cast(mcc_code as varchar)), '') is not null

    union

    select distinct lpad(trim(cast(mcc_code as varchar)), 4, '0')
    from {{ ref('fact_card_balance_posting') }}
    where nullif(trim(cast(mcc_code as varchar)), '') is not null
),

combined as (
    select
        coalesce(s.mcc_code, x.mcc_code) as mcc_code,
        coalesce(s.mcc_name, 'Unknown MCC ' || coalesce(s.mcc_code, x.mcc_code)) as mcc_name,
        coalesce(s.mcc_group, 'unclassified') as mcc_group
    from seed s
    full outer join seen x
        on x.mcc_code = s.mcc_code
)

select
    {{ sk_hash_ready("'mcc'", 'mcc_code') }} as mcc_sk,
    mcc_code,
    mcc_name,
    mcc_group,
    getdate() as loaded_at
from combined
where mcc_code is not null
