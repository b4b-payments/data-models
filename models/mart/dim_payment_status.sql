{{ config(
    alias='dim_payment_status',
    tags=['payments', 'mart']
) }}

-- One row per status source and source status, plus the single unknown row.
-- payment_status_sk is fnv_hash(status_source || '|' || source_status).

with mapped as (
    select
        {{ sk_hash_ready('status_source', "nullif(trim(source_status), '')") }} as payment_status_sk,
        status_source,
        source_status,
        normalised_status,
        is_terminal is true as is_terminal,
        cast(sort_order as integer) as sort_order,
        description
    from {{ ref('payment_status_map') }}
)

select * from mapped
union all
select
    {{ sk_unknown() }} as payment_status_sk,
    '~unknown' as status_source,
    '~unknown' as source_status,
    '~unknown' as normalised_status,
    false as is_terminal,
    0 as sort_order,
    'Unknown' as description
