{{ config(
    alias='dim_country_risk',
    tags=['country', 'mart', 'compliance'],
    dist='country_sk',
    sort=['country_sk']
) }}

-- Type-1 risk outrigger on ISO dim_country. Demo SoT: Compliance Master Sheet v3.

select
    c.country_sk,
    c.alpha2,
    coalesce(rr.rating_label, trim(r.final_rating)) as final_rating,
    rr.rating_rank as final_rating_rank,
    trim(r.previous_rating_v2) as previous_rating_v2,
    trim(r.previous_rating_v1) as previous_rating_v1,
    r.mlro_note,
    r.continent_sheet,
    'master_v3_iso.csv' as source_file,
    getdate() as loaded_at
from {{ ref('dim_country') }} c
inner join {{ source('spike_stg', 'stg_compliance_country_risk') }} r
    on upper(trim(r.iso_code)) = c.alpha2
left join {{ ref('dim_risk_rating') }} rr
    on lower(rr.rating_label) = lower(trim(r.final_rating))
where c.alpha2 <> '~unknown'
