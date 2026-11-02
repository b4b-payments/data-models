{% macro signed_by_direction(amount_sql, direction_sql) -%}
case
    when lower(trim(cast({{ direction_sql }} as varchar))) = 'debit'
        then -abs({{ amount_sql }})
    when lower(trim(cast({{ direction_sql }} as varchar))) = 'credit'
        then abs({{ amount_sql }})
    else {{ amount_sql }}
end
{%- endmacro %}

{% macro unique_portal_cards() -%}
select
    processor_card_id,
    card_sk,
    cardholder_sk,
    account_sk,
    entity_sk,
    card_product_sk,
    card_scheme_sk
from (
    select
        processor_card_id,
        card_sk,
        cardholder_sk,
        account_sk,
        entity_sk,
        card_product_sk,
        card_scheme_sk,
        count(*) over (partition by processor_card_id) as card_id_count
    from {{ ref('dim_card') }}
    where processor_card_id is not null
) matched
where card_id_count = 1
{%- endmacro %}

{% macro posting_predicate(alias) -%}
lower(trim({{ alias }}.transaction_class)) = 'financial'
and {{ alias }}.ledger_transaction = 1
and {{ alias }}.impacts_balance = 1
and coalesce({{ alias }}.declined, 0) = 0
{%- endmacro %}

{% macro normalize_wallet(wallet_sql) -%}
case
    when nullif(trim(cast({{ wallet_sql }} as varchar)), '') is null then 'none'
    when upper(trim(cast({{ wallet_sql }} as varchar))) in ('APPLE', 'APPLE_PAY', 'APPLEPAY') then 'apple_pay'
    when upper(trim(cast({{ wallet_sql }} as varchar))) in ('ANDROID', 'GOOGLE', 'GOOGLE_PAY', 'GOOGLEPAY') then 'google_pay'
    when upper(trim(cast({{ wallet_sql }} as varchar))) in ('SAMSUNG', 'SAMSUNG_PAY', 'SAMSUNGPAY') then 'samsung_pay'
    when upper(trim(cast({{ wallet_sql }} as varchar))) in ('MRCHTOKEN', 'MERCHANT_TOKEN') then 'merchant_token'
    else 'other'
end
{%- endmacro %}

{% macro presentment_channel_from_flags(atm_sql, pos_sql, ecommerce_sql, mcc_sql) -%}
case
    when coalesce({{ atm_sql }}, 0) = 1 then 'atm'
    when coalesce({{ ecommerce_sql }}, 0) = 1 then 'online'
    when coalesce({{ pos_sql }}, 0) = 1 then 'pos'
    when lpad(trim(cast({{ mcc_sql }} as varchar)), 4, '0') in ('6010', '6011') then 'atm'
    else 'unknown'
end
{%- endmacro %}

{# GPS localdateutc is MMDDHHMMSS (not an ISO timestamp). Year comes from localdate. #}
{% macro gps_event_ts_utc(localdate_sql, localdateutc_sql) -%}
case
    when {{ localdate_sql }} is null
        and nullif(trim(cast({{ localdateutc_sql }} as varchar)), '') is null
        then cast(null as timestamp)
    when nullif(trim(cast({{ localdateutc_sql }} as varchar)), '') is null
        then cast({{ localdate_sql }} as timestamp)
    when trim(cast({{ localdateutc_sql }} as varchar)) ~ '^[0-9]{10}$'
        then cast(
            to_timestamp(
                lpad(cast(extract(year from {{ localdate_sql }}) as int)::varchar, 4, '0')
                || trim(cast({{ localdateutc_sql }} as varchar)),
                'YYYYMMDDHH24MISS'
            ) as timestamp
        )
    else cast({{ localdate_sql }} as timestamp)
end
{%- endmacro %}
