{{ config(
    alias='dim_entity',
    tags=['party', 'mart']
) }}

-- Grain: one organisational entity (Type-1).
-- PSU = CLE (not portal company). Agent / Intermediate included.
-- B4B and B4S are separate portals. The same CLE id can exist on both.
-- PK: entity_sk. Optional gid_sk → dim_gid.

-- CLE staging columns (both portals): id, name, gid, tm_incorporation_country.
with cle as (
    select
        'PSU' as entity_type,
        coalesce(cle.name, cast(cle.id as varchar)) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4b' as source_system,
        cast(cle.id as varchar) as source_pk,
        cast(cle.id as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        coalesce(gi.gid, cle.gid) as gid,
        cast(cle.tm_incorporation_country as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4B' as platform
    from {{ source('spike_stg', 'stg_b4b_client_legal_entities') }} cle
    left join {{ source('spike_stg', 'stg_orchestrator_global_identifiers') }} gi
        on cast(gi.b4b_client_legal_entity_id as varchar) = cast(cle.id as varchar)

    union all

    select
        'PSU' as entity_type,
        coalesce(cle.name, cast(cle.id as varchar)) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4s' as source_system,
        cast(cle.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(cle.id as varchar) as b4s_cle_id,
        coalesce(gi.gid, cle.gid) as gid,
        cast(cle.tm_incorporation_country as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4S' as platform
    from {{ source('spike_stg', 'stg_b4s_client_legal_entities') }} cle
    left join {{ source('spike_stg', 'stg_orchestrator_global_identifiers') }} gi
        on cast(gi.b4s_client_legal_entity_id as varchar) = cast(cle.id as varchar)
),

agents as (
    select
        'Agent' as entity_type,
        c.name as entity_name,
        case when c.enabled then 'enabled' else 'disabled' end as entity_status,
        'oversight' as source_system,
        cast(c.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        cast(null as varchar) as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'OVERSIGHT' as platform
    from {{ source('spike_stg', 'stg_oversight_clients') }} c
),

intermediates as (
    select
        'Intermediate' as entity_type,
        coalesce(i.description, i.code) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4b' as source_system,
        cast(i.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        cast(null as varchar) as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4B' as platform
    from {{ source('spike_stg', 'stg_b4b_institutions') }} i

    union all

    select
        'Intermediate' as entity_type,
        coalesce(i.description, i.code) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4s' as source_system,
        cast(i.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        cast(null as varchar) as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4S' as platform
    from {{ source('spike_stg', 'stg_b4s_institutions') }} i
),

unioned as (
    select * from cle
    union all
    select * from agents
    union all
    select * from intermediates
),

with_sk as (
    select
        row_number() over (
            order by source_system, entity_type, source_pk
        ) as entity_sk,
        u.*,
        g.gid_sk,
        getdate() as loaded_at
    from unioned u
    left join {{ ref('dim_gid') }} g
        on g.gid = u.gid
)

select
    entity_sk,
    gid_sk,
    entity_type,
    entity_name,
    entity_status,
    cast(null as integer) as parent_entity_sk,
    cast(null as integer) as partner_entity_sk,
    cast(null as integer) as institution_entity_sk,
    platform,
    platform as product,
    source_system,
    source_pk,
    b4b_cle_id,
    b4s_cle_id,
    legal_entity_country,
    parent_source_system,
    parent_source_pk,
    loaded_at
from with_sk
