{{ config(
    alias='dim_gid',
    tags=['party', 'mart']
) }}

-- Grain: one row per Global ID (orchestrator). Do not invent GIDs.
-- PK: gid_sk (integer). Natural key: gid (G-…).

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
)

select
    gid_sk,
    gid,
    orchestrator_id,
    cast(null as integer) as parent_gid_sk,  -- filled in post-pass / next model iteration
    parent_orchestrator_id,
    zoho_account_id,
    passfort_profile_id,
    b4b_cle_id,
    b4s_cle_id,
    risk_level,
    loaded_at
from numbered
