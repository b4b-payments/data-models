{{ config(
    alias='dim_risk_rating',
    tags=['country', 'mart']
) }}

-- Ordered B4B financial-crime country risk labels (Compliance methodology).

select
    rating_code,
    rating_label,
    cast(rating_rank as int) as rating_rank
from {{ ref('risk_rating') }}
