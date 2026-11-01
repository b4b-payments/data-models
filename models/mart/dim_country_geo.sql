{{ config(
    alias='dim_country_geo',
    tags=['country', 'mart', 'geonames'],
    dist='country_sk',
    sort=['country_sk']
) }}

-- Type-1 geo outrigger on ISO dim_country. SoT: GeoNames countryInfo.

select
    c.country_sk,
    c.alpha2,
    g.iso3 as geonames_iso3,
    g.iso_numeric,
    g.continent_code,
    g.continent_name,
    g.capital,
    cast(g.area_km2 as double precision) as area_km2,
    cast(g.population as bigint) as population,
    g.tld,
    g.currency_code,
    g.phone_prefix,
    g.postal_code_format,
    g.postal_code_regex,
    g.languages,
    cast(g.geonames_id as bigint) as geonames_id,
    g.neighbours,
    'geonames_countryInfo' as source_file,
    getdate() as loaded_at
from {{ ref('dim_country') }} c
inner join {{ source('spike_stg', 'stg_geonames_country') }} g
    on upper(trim(g.iso2)) = c.alpha2
where c.alpha2 <> '~unknown'
