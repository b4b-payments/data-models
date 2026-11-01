{{ config(
    alias='dim_vessel',
    tags=['party', 'mart', 'vessel'],
    post_hook=["grant select on {{ this }} to airbyte_spike"]
) }}

-- Grain: one hull (vessel asset) from the 2026-10-15 Grid coverage book.
-- Prototype for production Subaccount/asset under a CLE (PSU).
-- Does not invent GIDs — passfort_global_id is the CLE money-holder GID when present.

select
    row_number() over (order by hull_key, institution_id) as vessel_sk,
    hull_key,
    hull_name,
    institution_id,
    institution_name,
    enterprise_code,
    psu_or_subaccount,
    psu_cle_name,
    passfort_global_id as cle_gid,
    passfort_profile_id,
    passfort_found,
    jurisdictions,
    account_mix,
    case when upper(has_operational) = 'Y' then true else false end as has_operational,
    case when upper(has_apa) = 'Y' then true else false end as has_apa,
    case when upper(has_project) = 'Y' then true else false end as has_project,
    case when upper(has_open_float) = 'Y' then true else false end as has_open_float,
    case when upper(grid_ever) = 'Y' then true else false end as grid_ever,
    case when upper(grid_ongoing) = 'Y' then true else false end as grid_ongoing,
    case when upper(folder_found) = 'Y' then true else false end as folder_found,
    vessel_registration_stage,
    org_structure_stage,
    ubo_stage,
    as_of,
    getdate() as loaded_at
from {{ source('spike_stg', 'stg_vessel_hull_coverage') }}
where nullif(trim(hull_key), '') is not null
