{{ config(
    alias='dim_failure_reason',
    tags=['payments', 'mart']
) }}

-- Reason code, not free-text message. BCTN message is populated on payments
-- that have no return code, so it is not the key.

with bctn_codes as (
    select
        nullif(trim(return_code), '') as reason_code
    from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }}
    union
    select nullif(trim(return_code), '')
    from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }}
),
oversight_codes as (
    select
        {{ oversight_error_code('banking_circle_api_response') }} as reason_code,
        {{ oversight_error_text('banking_circle_api_response') }} as reason_text
    from {{ source('spike_stg', 'stg_oversight_payments') }}
),
oversight_one as (
    select
        reason_code,
        max(reason_text) as reason_text
    from oversight_codes
    where reason_code is not null
    group by 1
)

select
    {{ sk_hash_ready("'bctn_return_code'", 'reason_code') }} as failure_reason_sk,
    'bctn_return_code' as reason_source,
    reason_code,
    cast(null as varchar) as reason_text,
    cast(null as varchar) as category,
    cast(null as boolean) as is_retryable
from bctn_codes
where reason_code is not null

union all

select
    {{ sk_hash_ready("'oversight_error'", 'reason_code') }} as failure_reason_sk,
    'oversight_error' as reason_source,
    reason_code,
    reason_text,
    cast(null as varchar) as category,
    cast(null as boolean) as is_retryable
from oversight_one

union all

select
    {{ sk_unknown() }} as failure_reason_sk,
    '~unknown' as reason_source,
    '~unknown' as reason_code,
    'Unknown' as reason_text,
    cast(null as varchar) as category,
    cast(null as boolean) as is_retryable
