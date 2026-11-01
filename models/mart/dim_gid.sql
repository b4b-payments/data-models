{{ config(
    alias='dim_gid',
    tags=['party', 'mart']
) }}

-- Grain: one row per Global ID (orchestrator). Do not invent GIDs.
-- PK: gid_sk (integer). Natural key: gid (G-…).
-- Warehouse overlay: gid_type (orchestrator has parent_id but no type field).
--   Partner     — root with children and no CLE (e.g. ICP G-15679), or seed overlay
--   PSU         — has B4B/B4S client legal entity id
--   Subaccount  — child with no CLE (asset under a CLE; production sub-account/assets)
-- Vessel float kinds (operational | apa | project_refit) live on the account, not here.

with src as (
    select *
    from {{ source('spike_stg', 'stg_orchestrator_global_identifiers') }}
),

numbered as (
    select
        row_number() over (order by id) as gid_sk,
        cast(id as varchar) as orchestrator_id,
        gid,
        cast(parent_id as varchar) as parent_orchestrator_id,
        zoho_account_id,
        passfort_profile_id,
        cast(b4b_client_legal_entity_id as varchar) as b4b_cle_id,
        cast(b4s_client_legal_entity_id as varchar) as b4s_cle_id,
        risk_level,
        getdate() as loaded_at
    from src
    where nullif(trim(gid), '') is not null
),

has_child as (
    select distinct parent_orchestrator_id as orchestrator_id
    from numbered
    where parent_orchestrator_id is not null
),

overlay_partner as (
    select distinct nullif(trim(gid), '') as gid
    from {{ ref('partner_overlay') }}
    where nullif(trim(gid), '') is not null
),

typed as (
    select
        n.*,
        case
            when n.b4b_cle_id is not null or n.b4s_cle_id is not null then 'PSU'
            when n.parent_orchestrator_id is not null then 'Subaccount'
            when o.gid is not null then 'Partner'
            when c.orchestrator_id is not null then 'Partner'
            else cast(null as varchar)
        end as gid_type
    from numbered n
    left join has_child c
        on c.orchestrator_id = n.orchestrator_id
    left join overlay_partner o
        on o.gid = n.gid
)

select
    t.gid_sk,
    t.gid,
    t.orchestrator_id,
    p.gid_sk as parent_gid_sk,
    t.parent_orchestrator_id,
    t.gid_type,
    t.zoho_account_id,
    t.passfort_profile_id,
    t.b4b_cle_id,
    t.b4s_cle_id,
    t.risk_level,
    t.loaded_at
from typed t
left join typed p
    on p.orchestrator_id = t.parent_orchestrator_id
