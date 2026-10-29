{{ config(
    alias='fct_card_transaction_snapshot',
    tags=['cards', 'mart']
) }}

-- Grain: one current lifecycle group.
-- Amounts stay on the atomic facts. This row carries counts, state, and keys.
-- Several presentments in one group do not become one summed amount.
-- States: reversed, confirmed_gps, observed_ehi, unmatched.
-- Chargeback is reserved. CardChrgBackRepRes is not in this build.
-- Rebuilding this table does not write a closed-period extract. That extract
-- is not in this build, so a rematch cannot change one.

with current_bridge as (
    select *
    from {{ ref('bridge_card_lifecycle_match') }}
    where superseded_by_match_sk is null
),

endpoints as (
    select lifecycle_group_sk, left_fact as fact_name, left_sk as evidence_sk
    from current_bridge

    union

    select lifecycle_group_sk, right_fact as fact_name, right_sk as evidence_sk
    from current_bridge
),

grouped as (
    select
        lifecycle_group_sk,
        count(distinct case when fact_name = 'fact_card_authorisation' then evidence_sk end) as auth_count,
        count(distinct case when fact_name = 'fact_card_financial' then evidence_sk end) as financial_count,
        count(distinct case when fact_name = 'fact_card_fee' then evidence_sk end) as fee_count,
        count(distinct case when fact_name = 'fact_card_load' then evidence_sk end) as load_count,
        count(distinct case when fact_name = 'fact_card_balance_posting' then evidence_sk end) as posting_count,
        count(distinct case when fact_name = 'fact_card_ehi_observation' then evidence_sk end) as ehi_count
    from endpoints
    group by lifecycle_group_sk
),

party as (
    select
        e.lifecycle_group_sk,
        max(f.card_sk) as card_sk,
        max(f.account_sk) as account_sk,
        max(f.entity_sk) as entity_sk,
        max(case
            when lower(coalesce(f.txn_code_type, '')) like '%rev%'
              or lower(coalesce(f.txn_code_group, '')) like '%rev%'
            then 1 else 0
        end) as is_reversed
    from endpoints e
    inner join {{ ref('fact_card_financial') }} f
        on e.fact_name = 'fact_card_financial'
       and e.evidence_sk = f.financial_sk
    group by e.lifecycle_group_sk
),

matched as (
    select
        g.lifecycle_group_sk,
        case
            when coalesce(p.is_reversed, 0) = 1 then 'reversed'
            when g.financial_count > 0 or g.auth_count > 0 then 'confirmed_gps'
            when g.ehi_count > 0 then 'observed_ehi'
            else 'unmatched'
        end as lifecycle_state,
        g.auth_count,
        g.financial_count,
        g.fee_count,
        g.load_count,
        g.posting_count,
        g.ehi_count,
        p.card_sk,
        p.account_sk,
        p.entity_sk
    from grouped g
    left join party p
        on p.lifecycle_group_sk = g.lifecycle_group_sk
),

unmatched_auth as (
    select
        'unmatched-auth-' || cast(a.auth_sk as varchar) as group_key,
        'unmatched' as lifecycle_state,
        1 as auth_count,
        0 as financial_count,
        0 as fee_count,
        0 as load_count,
        0 as posting_count,
        0 as ehi_count,
        a.card_sk,
        a.account_sk,
        a.entity_sk
    from {{ ref('fact_card_authorisation') }} a
    left join endpoints e
        on e.fact_name = 'fact_card_authorisation'
       and e.evidence_sk = a.auth_sk
    where e.evidence_sk is null
),

unmatched_fin as (
    select
        'unmatched-fin-' || cast(f.financial_sk as varchar) as group_key,
        'unmatched' as lifecycle_state,
        0 as auth_count,
        1 as financial_count,
        0 as fee_count,
        0 as load_count,
        0 as posting_count,
        0 as ehi_count,
        f.card_sk,
        f.account_sk,
        f.entity_sk
    from {{ ref('fact_card_financial') }} f
    left join endpoints e
        on e.fact_name = 'fact_card_financial'
       and e.evidence_sk = f.financial_sk
    where e.evidence_sk is null
),

unmatched_ehi as (
    select
        'unmatched-ehi-' || o.source_system || '-' || o.source_ledger_id as group_key,
        'observed_ehi' as lifecycle_state,
        0 as auth_count,
        0 as financial_count,
        0 as fee_count,
        0 as load_count,
        0 as posting_count,
        1 as ehi_count,
        o.card_sk,
        o.account_sk,
        o.entity_sk
    from {{ ref('fact_card_ehi_observation') }} o
    left join endpoints e
        on e.fact_name = 'fact_card_ehi_observation'
       and e.evidence_sk = o.observation_sk
    where e.evidence_sk is null
),

unmatched_posting as (
    select
        'unmatched-posting-' || p.source_system || '-' || p.source_ledger_id as group_key,
        'unmatched' as lifecycle_state,
        0 as auth_count,
        0 as financial_count,
        0 as fee_count,
        0 as load_count,
        1 as posting_count,
        0 as ehi_count,
        p.card_sk,
        p.account_sk,
        p.entity_sk
    from {{ ref('fact_card_balance_posting') }} p
    left join endpoints e
        on e.fact_name = 'fact_card_balance_posting'
       and e.evidence_sk = p.posting_sk
    where e.evidence_sk is null
),

combined as (
    select
        cast(lifecycle_group_sk as varchar) as group_key,
        lifecycle_state,
        auth_count,
        financial_count,
        fee_count,
        load_count,
        posting_count,
        ehi_count,
        card_sk,
        account_sk,
        entity_sk
    from matched

    union all

    select * from unmatched_auth
    union all
    select * from unmatched_fin
    union all
    select * from unmatched_ehi
    union all
    select * from unmatched_posting
)

select
    row_number() over (order by group_key) as snapshot_sk,
    group_key as lifecycle_group_key,
    lifecycle_state,
    auth_count,
    financial_count,
    fee_count,
    load_count,
    posting_count,
    ehi_count,
    card_sk,
    account_sk,
    entity_sk,
    getdate() as loaded_at
from combined
