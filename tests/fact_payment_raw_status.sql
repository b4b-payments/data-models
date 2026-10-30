-- Portal raw status stays the Banking Circle notification status.

select payment_sk
from {{ ref('fact_payment') }}
where source_system in ('portal_b4b', 'portal_b4s')
  and payment_status not in ('pending', 'failed')
