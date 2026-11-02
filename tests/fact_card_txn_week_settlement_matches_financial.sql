-- Presentment settlement on fact_card_txn must equal fact_card_financial for the week window.
with bounds as (
    select
        min(id) as start_sk,
        max(id) as end_sk
    from spike.dim_date
    where calendar_date between cast('{{ var("card_txn_week_start", "2026-10-20") }}' as date)
                           and cast('{{ var("card_txn_week_end", "2026-10-26") }}' as date)
),
fin as (
    select coalesce(sum(f.settlement_amount), 0) as amt
    from {{ ref('fact_card_financial') }} f
    cross join bounds b
    where f.date_sk between b.start_sk and b.end_sk
),
txn as (
    select coalesce(sum(t.settlement_amount), 0) as amt
    from {{ ref('fact_card_txn') }} t
    where t.txn_outcome = 'presentment'
)
select
    f.amt as financial_settlement,
    t.amt as txn_settlement
from fin f
cross join txn t
where abs(f.amt - t.amt) > 0.01
