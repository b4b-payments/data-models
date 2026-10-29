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
