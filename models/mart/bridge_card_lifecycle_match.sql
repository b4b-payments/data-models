{{ config(
    alias='bridge_card_lifecycle_match',
    tags=['cards', 'mart']
) }}

-- Grain: one link between two pieces of evidence.
-- First build. superseded_by_match_sk is empty. A later rule inserts a new
-- row rather than updating this one. This materialisation replaces the table.
-- Link order: trace id, then portal transaction_link, then AuthId or FinId
-- to the portal processor transaction id, then processor_ref to LoadUnloadId.
-- A weaker method is not also written when a stronger one already matches.
-- One authorisation may link to many financials. Amounts stay on the facts.

with auth as (
    select
        auth_sk,
        source_system,
        source_auth_id,
        traceid_lifecycle
    from {{ ref('fact_card_authorisation') }}
),

fin as (
    select
        financial_sk,
        source_system,
        source_fin_id,
        source_auth_id,
        traceid_lifecycle
    from {{ ref('fact_card_financial') }}
),

posting as (
    select
        posting_sk as evidence_sk,
        'fact_card_balance_posting' as fact_name,
        source_system,
        source_ledger_id,
        processor_transaction_id,
        processor_traceid,
        transaction_link
    from {{ ref('fact_card_balance_posting') }}
),

ehi as (
    select
        observation_sk as evidence_sk,
        'fact_card_ehi_observation' as fact_name,
        source_system,
        source_ledger_id,
        processor_transaction_id,
        processor_traceid,
        transaction_link
    from {{ ref('fact_card_ehi_observation') }}
),

portal as (
    select * from posting
    union all
    select * from ehi
),

trace_auth_fin as (
    select
        'fact_card_authorisation' as left_fact,
        a.auth_sk as left_sk,
        'fact_card_financial' as right_fact,
        f.financial_sk as right_sk,
        'traceid_lifecycle' as match_method,
        'trace|' || a.source_system || '|' || a.traceid_lifecycle as group_key
    from auth a
    inner join fin f
        on f.source_system = a.source_system
       and f.traceid_lifecycle = a.traceid_lifecycle
    where a.traceid_lifecycle is not null
),

portal_trace as (
    select
        p.fact_name as left_fact,
        p.evidence_sk as left_sk,
        'fact_card_financial' as right_fact,
        f.financial_sk as right_sk,
        'traceid_lifecycle' as match_method,
        'trace|' || f.source_system || '|' || f.traceid_lifecycle as group_key
    from portal p
    inner join fin f
        on f.traceid_lifecycle = p.processor_traceid
    where p.processor_traceid is not null
      and f.traceid_lifecycle is not null
),

portal_has_trace as (
    select distinct left_fact, left_sk
    from portal_trace
),

link_anchor as (
    select
        source_system,
        transaction_link,
        min(source_ledger_id) as anchor_ledger_id
    from portal
    where transaction_link is not null
    group by 1, 2
    having count(*) > 1
),

known_group as (
    select
        fact_name,
        evidence_sk,
        min(group_key) as group_key
    from (
        select left_fact as fact_name, left_sk as evidence_sk, group_key from trace_auth_fin
        union all
        select right_fact, right_sk, group_key from trace_auth_fin
        union all
        select left_fact, left_sk, group_key from portal_trace
        union all
        select right_fact, right_sk, group_key from portal_trace
    ) grouped
    group by 1, 2
),

portal_link as (
    select
        p.fact_name as left_fact,
        p.evidence_sk as left_sk,
        a.fact_name as right_fact,
        a.evidence_sk as right_sk,
        'transaction_link' as match_method,
        coalesce(
            kg.group_key,
            'tlink|' || p.source_system || '|' || p.transaction_link
        ) as group_key
    from portal p
    inner join link_anchor k
        on k.source_system = p.source_system
       and k.transaction_link = p.transaction_link
       and k.anchor_ledger_id <> p.source_ledger_id
    inner join portal a
        on a.source_system = p.source_system
       and a.source_ledger_id = k.anchor_ledger_id
    left join known_group kg
        on kg.fact_name = a.fact_name
       and kg.evidence_sk = a.evidence_sk
    left join portal_has_trace t
        on t.left_fact = p.fact_name
       and t.left_sk = p.evidence_sk
    where t.left_sk is null
),

portal_has_link as (
    select left_fact, left_sk from portal_has_trace
    union
    select left_fact, left_sk from portal_link
),

fin_one as (
    select source_fin_id, financial_sk, source_system
    from (
        select
            source_fin_id,
            financial_sk,
            source_system,
            traceid_lifecycle,
            count(*) over (partition by source_fin_id) as fin_count
        from fin
        where source_fin_id is not null
    ) f
    where fin_count = 1
),

auth_one as (
    select source_auth_id, auth_sk, source_system
    from (
        select
            source_auth_id,
            auth_sk,
            source_system,
            count(*) over (partition by source_auth_id) as auth_count
        from auth
        where source_auth_id is not null
    ) a
    where auth_count = 1
),

portal_fin as (
    select
        p.fact_name as left_fact,
        p.evidence_sk as left_sk,
        'fact_card_financial' as right_fact,
        f.financial_sk as right_sk,
        'fin_id_to_txn_id' as match_method,
        coalesce(
            kg.group_key,
            'fin|' || f.source_system || '|' || f.source_fin_id
        ) as group_key
    from portal p
    inner join fin_one f
        on f.source_fin_id = p.processor_transaction_id
    left join known_group kg
        on kg.fact_name = 'fact_card_financial'
       and kg.evidence_sk = f.financial_sk
    left join portal_has_link earlier
        on earlier.left_fact = p.fact_name
       and earlier.left_sk = p.evidence_sk
    where p.processor_transaction_id is not null
      and earlier.left_sk is null
),

portal_has_fin as (
    select left_fact, left_sk from portal_has_link
    union
    select left_fact, left_sk from portal_fin
),

portal_auth as (
    select
        p.fact_name as left_fact,
        p.evidence_sk as left_sk,
        'fact_card_authorisation' as right_fact,
        a.auth_sk as right_sk,
        'auth_id_to_txn_id' as match_method,
        coalesce(
            kg.group_key,
            'auth|' || a.source_system || '|' || a.source_auth_id
        ) as group_key
    from portal p
    inner join auth_one a
        on a.source_auth_id = p.processor_transaction_id
    left join known_group kg
        on kg.fact_name = 'fact_card_authorisation'
       and kg.evidence_sk = a.auth_sk
    left join portal_has_fin earlier
        on earlier.left_fact = p.fact_name
       and earlier.left_sk = p.evidence_sk
    where p.processor_transaction_id is not null
      and earlier.left_sk is null
),

load_link as (
    select
        'fact_card_load' as left_fact,
        portal_load.load_sk as left_sk,
        'fact_card_load' as right_fact,
        gps_load.load_sk as right_sk,
        'processor_ref' as match_method,
        'load|' || gps_load.source_system || '|' || gps_load.source_load_id as group_key
    from {{ ref('fact_card_load') }} portal_load
    inner join {{ ref('fact_card_load') }} gps_load
        on gps_load.source_system in ('gps_mc', 'gps_visa')
       and gps_load.source_load_id = portal_load.processor_ref
    where portal_load.source_system in ('portal_b4b', 'portal_b4s')
      and portal_load.processor_ref is not null
),

links as (
    select * from trace_auth_fin
    union all
    select * from portal_trace
    union all
    select * from portal_link
    union all
    select * from portal_fin
    union all
    select * from portal_auth
    union all
    select * from load_link
)

select
    row_number() over (order by match_method, left_fact, left_sk, right_fact, right_sk) as match_sk,
    dense_rank() over (order by group_key) as lifecycle_group_sk,
    left_fact,
    left_sk,
    right_fact,
    right_sk,
    match_method,
    'exact' as confidence,
    '2026-10-28' as rule_version,
    getdate() as loaded_at,
    cast(null as bigint) as superseded_by_match_sk,
    cast(null as varchar) as manual_reason
from links
