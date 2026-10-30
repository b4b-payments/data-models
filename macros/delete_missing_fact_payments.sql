{% macro delete_missing_fact_payments() %}
delete from {{ this }}
using (
    select c.source_system, c.business_key
    from {{ source('spike_ops', 'pipeline_changed_key') }} c
    where c.run_id = '{{ var("pipeline_run_id", "") }}'
      and (
        (
            c.key_role = 'oversight_payment_id'
            and c.source_system = 'oversight'
            and not exists (
                select 1
                from {{ source('spike_stg', 'stg_oversight_payments') }} p
                where cast(p.id as varchar) = c.business_key
            )
        )
        or (
            c.key_role = 'bctn_id'
            and c.source_system = 'portal_b4b'
            and not exists (
                select 1
                from {{ source('spike_stg', 'stg_b4b_banking_circle_transaction_notifications') }} b
                where cast(b.id as varchar) = c.business_key
            )
        )
        or (
            c.key_role = 'bctn_id'
            and c.source_system = 'portal_b4s'
            and not exists (
                select 1
                from {{ source('spike_stg', 'stg_b4s_banking_circle_transaction_notifications') }} b
                where cast(b.id as varchar) = c.business_key
            )
        )
      )
) gone
where {{ this }}.source_system = gone.source_system
  and {{ this }}.source_payment_id = gone.business_key
{% endmacro %}
