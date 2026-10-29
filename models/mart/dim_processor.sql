{{ config(
    alias='dim_processor',
    tags=['cards', 'mart']
) }}

-- Grain: one processor family. Fixed keys so a rebuild does not renumber them.
-- Portal strings that are not in this list stay off the key. The fact keeps processor_code_raw.

select
    processor_sk,
    processor_code,
    processor_name
from (
    select 1 as processor_sk, 'gps_mc' as processor_code, 'GPS Mastercard' as processor_name
    union all
    select 2, 'gps_visa', 'GPS Visa'
    union all
    select 3, 'marqeta', 'Marqeta'
    union all
    select 4, 'pleo', 'Pleo'
    union all
    select 5, 'dps', 'DPS'
) s
