{{ config(
    alias='dim_account_vessel',
    tags=['party', 'mart', 'vessel'],
    dist='account_sk',
    sort=['account_sk'],
    post_hook=["grant select on {{ this }} to airbyte_spike"]
) }}

-- Outrigger on dim_account for yachting floats only.
-- float_type: operational | apa | project (refit not split in 2026-10-15 export).
-- psu_or_subaccount + cle_gid describe CLE money possession vs subaccount under manager CLE.
-- Joins: portal_b4b company_id = dim_account.source_pk.

with floats as (
    select
        cast(company_id as varchar) as company_id,
        lower(float_type) as float_type,
        lower(float_status) as float_status,
        jurisdiction,
        hull_key,
        hull_name,
        institution_id,
        institution_name,
        enterprise_code,
        psu_or_subaccount,
        psu_cle_name,
        passfort_global_id as cle_gid,
        as_of,
        row_number() over (
            partition by cast(company_id as varchar)
            order by hull_key, float_type
        ) as rn
    from {{ source('spike_stg', 'stg_vessel_float_coverage') }}
    where nullif(trim(company_id), '') is not null
)

select
    a.account_sk,
    a.entity_sk,
    v.vessel_sk,
    f.company_id as source_company_id,
    f.float_type,
    f.float_status,
    f.jurisdiction,
    f.hull_key,
    f.hull_name,
    f.institution_id,
    f.institution_name,
    f.enterprise_code,
    f.psu_or_subaccount,
    f.psu_cle_name,
    f.cle_gid,
    f.as_of,
    getdate() as loaded_at
from floats f
inner join {{ ref('dim_account') }} a
    on a.source_system = 'portal_b4b'
   and a.source_pk = f.company_id
left join {{ ref('dim_vessel') }} v
    on v.hull_key = f.hull_key
   and cast(v.institution_id as varchar) = cast(f.institution_id as varchar)
where f.rn = 1
