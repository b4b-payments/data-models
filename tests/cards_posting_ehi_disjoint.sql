-- A portal transaction is a balance posting or an EHI observation, not both.
select
    p.source_system,
    p.source_ledger_id
from {{ ref('fact_card_balance_posting') }} p
inner join {{ ref('fact_card_ehi_observation') }} e
    on e.source_system = p.source_system
   and e.source_ledger_id = p.source_ledger_id
