{{ config(
    alias='dim_jurisdiction',
    tags=['country', 'mart', 'compliance'],
    dist='all',
    sort=['jurisdiction_code']
) }}

-- Non-ISO / subdivision jurisdictions from Compliance sheet (XK, UA occupied, PT islands).

select
    fnv_hash(upper(trim(j.iso_code))) as jurisdiction_sk,
    upper(trim(j.iso_code)) as jurisdiction_code,
    j.country_name as jurisdiction_name,
    p.country_sk as parent_country_sk,
    upper(trim(j.parent_iso2)) as parent_alpha2,
    coalesce(rr.rating_label, trim(j.final_rating)) as final_rating,
    rr.rating_rank as final_rating_rank,
    trim(j.previous_rating_v2) as previous_rating_v2,
    trim(j.previous_rating_v1) as previous_rating_v1,
    j.mlro_note,
    'master_v3_jurisdiction.csv' as source_file,
    getdate() as loaded_at
from {{ source('spike_stg', 'stg_compliance_country_jurisdiction') }} j
left join {{ ref('dim_country') }} p
    on p.alpha2 = upper(trim(j.parent_iso2))
left join {{ ref('dim_risk_rating') }} rr
    on lower(rr.rating_label) = lower(trim(j.final_rating))
