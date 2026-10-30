{{ config(
    alias='dim_payment_profile',
    tags=['payments', 'mart']
) }}

-- One row per flag combination the fact can hash.
-- Directions in the current sources are Incoming and Outgoing. Null is included
-- so a blank direction still resolves.

with direction as (
    select 'Outgoing' as payment_direction
    union all
    select 'Incoming'
    union all
    select cast(null as varchar)
),
sca as (
    select true as sca_applied
    union all
    select false
    union all
    select cast(null as boolean)
),
flag as (
    select true as v
    union all
    select false
)

select
    {{ profile_sk(
        'd.payment_direction',
        's.sca_applied',
        'ret.v',
        'rev.v',
        'acc.v',
        'rail.v'
    ) }} as payment_profile_sk,
    d.payment_direction,
    s.sca_applied,
    ret.v as is_returned,
    rev.v as is_reversed,
    acc.v as account_resolved,
    rail.v as rail_resolved
from direction d
cross join sca s
cross join flag ret
cross join flag rev
cross join flag acc
cross join flag rail
