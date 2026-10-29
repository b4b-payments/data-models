-- Customer-ledger rows must be the financial balance-posting filter only.
select
    source_system,
    source_ledger_id
from {{ ref('fact_card_balance_posting') }}
where not (
    lower(trim(transaction_class)) = 'financial'
    and ledger_transaction = 1
    and impacts_balance = 1
    and coalesce(declined, 0) = 0
)
