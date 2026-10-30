{{ config(
    alias='dim_country',
    tags=['payments', 'mart']
) }}

-- country_sk is fnv_hash(alpha2). NA stays Namibia and is flagged.
-- The unknown row is hashed in SQL so it matches the fact.

select
    fnv_hash(upper(trim(alpha2))) as country_sk,
    upper(trim(alpha2)) as alpha2,
    upper(trim(alpha3)) as alpha3,
    name as country_name,
    nullif(trim(region), '') as region,
    is_placeholder_suspect is true as is_placeholder_suspect
from {{ ref('iso_3166_countries') }}

union all

select
    {{ sk_unknown() }} as country_sk,
    '~unknown' as alpha2,
    cast(null as varchar) as alpha3,
    'Unknown' as country_name,
    cast(null as varchar) as region,
    false as is_placeholder_suspect
