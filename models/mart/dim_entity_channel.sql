{{ config(
    alias='dim_entity_channel',
    tags=['party', 'mart', 'partners'],
    dist='entity_sk',
    sort=['entity_sk'],
    post_hook=["grant select on {{ this }} to airbyte_spike"]
) }}

-- Type-1 outrigger on CLE (PSU) entities.
-- Partner channel = hosting institution has companies for more than one CLE.
-- Primary institution = the one with the most companies for this CLE.

with company as (
    -- B4B: CLE id is on the company row
    select
        'B4B' as product,
        'portal_b4b' as source_system,
        cast(client_legal_entity_id as varchar) as cle_id,
        cast(institution_id as varchar) as institution_id
    from {{ source('spike_stg', 'stg_b4b_companies') }}
    where client_legal_entity_id is not null
      and institution_id is not null

    union all

    -- B4S: no CLE column on company; resolve via dim_account → CLE entity
    select
        'B4S' as product,
        'portal_b4s' as source_system,
        e.source_pk as cle_id,
        cast(co.institution_id as varchar) as institution_id
    from {{ source('spike_stg', 'stg_b4s_companies') }} co
    inner join {{ ref('dim_account') }} a
        on a.source_system = 'portal_b4s'
       and a.source_pk = cast(co.id as varchar)
    inner join {{ ref('dim_entity') }} e
        on e.entity_sk = a.entity_sk
       and e.entity_type = 'PSU'
    where co.institution_id is not null
),

institution_stats as (
    select
        product,
        institution_id,
        count(distinct cle_id) as institution_cle_count,
        count(*) as institution_company_count
    from company
    group by 1, 2
),

cle_institution as (
    select
        c.product,
        c.source_system,
        c.cle_id,
        c.institution_id,
        count(*) as company_count,
        row_number() over (
            partition by c.product, c.cle_id
            order by count(*) desc, c.institution_id
        ) as rn
    from company c
    group by 1, 2, 3, 4
),

institution_name as (
    select
        'B4B' as product,
        cast(id as varchar) as institution_id,
        coalesce(description, code) as institution_name,
        code as institution_code
    from {{ source('spike_stg', 'stg_b4b_institutions') }}

    union all

    select
        'B4S' as product,
        cast(id as varchar) as institution_id,
        coalesce(description, code) as institution_name,
        code as institution_code
    from {{ source('spike_stg', 'stg_b4s_institutions') }}
),

primary_channel as (
    select
        ci.product,
        ci.source_system,
        ci.cle_id,
        ci.institution_id,
        ci.company_count as cle_company_count_at_institution,
        s.institution_cle_count,
        s.institution_company_count,
        (s.institution_cle_count > 1) as is_partner_channel,
        n.institution_name,
        n.institution_code
    from cle_institution ci
    inner join institution_stats s
        on s.product = ci.product
       and s.institution_id = ci.institution_id
    left join institution_name n
        on n.product = ci.product
       and n.institution_id = ci.institution_id
    where ci.rn = 1
)

select
    e.entity_sk,
    e.product,
    e.entity_name as cle_name,
    coalesce(e.b4b_cle_id, e.b4s_cle_id) as cle_id,
    p.institution_id as primary_institution_id,
    p.institution_code as primary_institution_code,
    p.institution_name as primary_institution_name,
    inst.partner_entity_sk,
    partner.entity_name as partner_name,
    p.institution_cle_count,
    p.institution_company_count,
    p.cle_company_count_at_institution,
    -- Partner channel = linked Partner entity only (enterprise or overlay). Multi-CLE alone is not a partner.
    (partner.entity_sk is not null) as is_partner_channel,
    case
        when partner.entity_sk is not null then 'Enterprise partner'
        when coalesce(p.is_partner_channel, false) then 'Multi-CLE institution'
        when p.institution_id is not null then 'Single-CLE institution'
        else 'Unlinked'
    end as channel_type,
    getdate() as loaded_at
from {{ ref('dim_entity') }} e
left join primary_channel p
    on p.source_system = e.source_system
   and p.cle_id = e.source_pk
left join {{ ref('dim_entity') }} inst
    on inst.entity_type = 'Intermediate'
   and inst.source_system = p.source_system
   and inst.source_pk = p.institution_id
left join {{ ref('dim_entity') }} partner
    on partner.entity_sk = inst.partner_entity_sk
where e.entity_type = 'PSU'
