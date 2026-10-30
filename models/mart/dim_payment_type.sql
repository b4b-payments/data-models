{{ config(
    alias='dim_payment_type',
    tags=['payments', 'mart']
) }}

with bctn_types as (
    select nullif(trim(transaction_type), '') as type_code
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    union
    select nullif(trim(transaction_type), '')
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
),
oversight_types as (
    select
        nullif(trim(json_extract_path_text(banking_circle_api_response, 'payment', 'paymentRail')), '') as rail,
        nullif(trim(json_extract_path_text(banking_circle_api_response, 'payment', 'subClassification')), '') as sub_classification
    from {{ source('spike_stg', 'stg_oversight_payments') }}
),
oversight_one as (
    select distinct rail, sub_classification
    from oversight_types
    where rail is not null or sub_classification is not null
)

select
    {{ sk_hash_ready("'bctn'", 'type_code') }} as payment_type_sk,
    'bctn' as type_source,
    type_code,
    type_code as type_label,
    cast(null as varchar) as scheme_family
from bctn_types
where type_code is not null

union all

select
    {{ sk_hash_ready(
        "'oversight'",
        "coalesce(rail, '') || '|' || coalesce(sub_classification, '')"
    ) }} as payment_type_sk,
    'oversight' as type_source,
    coalesce(rail, '') || '|' || coalesce(sub_classification, '') as type_code,
    coalesce(rail, sub_classification) as type_label,
    sub_classification as scheme_family
from oversight_one

union all

select
    {{ sk_unknown() }} as payment_type_sk,
    '~unknown' as type_source,
    '~unknown' as type_code,
    'Unknown' as type_label,
    cast(null as varchar) as scheme_family
