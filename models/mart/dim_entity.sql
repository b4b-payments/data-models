{{ config(
    alias='dim_entity',
    tags=['party', 'mart']
) }}

-- Grain: one organisational entity (Type-1).
-- PSU = CLE (not portal company). Agent / Intermediate / Partner included.
-- Partner = PCS enterprises + reviewed institution overlay (seed partner_overlay).
-- B4B and B4S are separate portals. The same CLE id can exist on both.
-- PK: entity_sk. Optional gid_sk → dim_gid.
-- Partner SKs use a 1_000_000 offset so existing CLE/institution SKs stay stable.

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

partners as (
    select
        'Partner' as entity_type,
        coalesce(e.description, e.code, cast(e.id as varchar)) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4b' as source_system,
        cast(e.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        cast(null as varchar) as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4B' as platform
    from {{ source('spike_stg', 'stg_b4b_enterprises') }} e

    union all

    select
        'Partner' as entity_type,
        coalesce(e.description, e.code, cast(e.id as varchar)) as entity_name,
        cast(null as varchar) as entity_status,
        'portal_b4s' as source_system,
        cast(e.id as varchar) as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        cast(null as varchar) as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        'B4S' as platform
    from {{ source('spike_stg', 'stg_b4s_enterprises') }} e

    union all

    -- Reviewed institution partners with no enterprises row (e.g. ICP → G-15679)
    select
        'Partner' as entity_type,
        o.partner_name as entity_name,
        cast(null as varchar) as entity_status,
        o.link_source_system as source_system,
        o.partner_key as source_pk,
        cast(null as varchar) as b4b_cle_id,
        cast(null as varchar) as b4s_cle_id,
        nullif(trim(o.gid), '') as gid,
        cast(null as varchar) as legal_entity_country,
        cast(null as varchar) as parent_source_pk,
        cast(null as varchar) as parent_source_system,
        o.product as platform
    from {{ ref('partner_overlay') }} o
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
        coalesce(cast(i.enterprise_id as varchar), o.partner_key) as parent_source_pk,
        case
            when i.enterprise_id is not null then 'portal_b4b'
            when o.partner_key is not null then o.link_source_system
        end as parent_source_system,
        'B4B' as platform
    from {{ source('spike_stg', 'stg_b4b_institutions') }} i
    left join {{ ref('partner_overlay') }} o
        on o.product = 'B4B'
       and o.link_kind = 'institution'
       and o.link_pk = cast(i.id as varchar)

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
        coalesce(cast(i.enterprise_id as varchar), o.partner_key) as parent_source_pk,
        case
            when i.enterprise_id is not null then 'portal_b4s'
            when o.partner_key is not null then o.link_source_system
        end as parent_source_system,
        'B4S' as platform
    from {{ source('spike_stg', 'stg_b4s_institutions') }} i
    left join {{ ref('partner_overlay') }} o
        on o.product = 'B4S'
       and o.link_kind = 'institution'
       and o.link_pk = cast(i.id as varchar)
),

legacy as (
    select * from cle
    union all
    select * from agents
    union all
    select * from intermediates
),

legacy_sk as (
    select
        row_number() over (
            order by source_system, entity_type, source_pk
        ) as entity_sk,
        u.*,
        g.gid_sk,
        getdate() as loaded_at
    from legacy u
    left join {{ ref('dim_gid') }} g
        on g.gid = u.gid
),

partner_sk as (
    select
        1000000 + row_number() over (
            order by source_system, source_pk
        ) as entity_sk,
        p.*,
        g.gid_sk,
        getdate() as loaded_at
    from partners p
    left join {{ ref('dim_gid') }} g
        on g.gid = p.gid
),

with_sk as (
    select * from legacy_sk
    union all
    select * from partner_sk
)

select
    e.entity_sk,
    e.gid_sk,
    e.entity_type,
    e.entity_name,
    e.entity_status,
    case
        when e.entity_type = 'Intermediate' then p.entity_sk
        else cast(null as integer)
    end as parent_entity_sk,
    case
        when e.entity_type = 'Intermediate' then p.entity_sk
        else cast(null as integer)
    end as partner_entity_sk,
    cast(null as integer) as institution_entity_sk,
    e.platform,
    e.platform as product,
    e.source_system,
    e.source_pk,
    e.b4b_cle_id,
    e.b4s_cle_id,
    e.legal_entity_country,
    e.parent_source_system,
    e.parent_source_pk,
    e.loaded_at
from with_sk e
left join with_sk p
    on p.entity_type = 'Partner'
   and p.source_system = e.parent_source_system
   and p.source_pk = e.parent_source_pk
