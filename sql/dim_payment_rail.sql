-- Grain: one rail code (F###).
-- PK: id. Existing ids stay put. A new code takes max(id) + 1 in rail_code order.
-- Fact FK: fact_payment.rail_sk → id. Do not renumber.
--
-- payment_rail comes from spike.stg_bc_payment_rail, loaded from
-- banking_circle_reporting.payments.payment_rail (F### inside transaction_reference).
-- Portal payment_routings and banking_circle_routing_codes are a 2025 snapshot.
-- They still seed rail_name and a fallback label when BC payments has no row.
--
-- spike.dim_payment_rail is owned by the workgroup admin. This script maintains
-- spike.dim_payment_rail_build, which Cube and dbt read.

INSERT INTO spike.dim_payment_rail_build
SELECT c.*
FROM spike.dim_payment_rail c
WHERE NOT EXISTS (
    SELECT 1
    FROM spike.dim_payment_rail_build b
    WHERE b.rail_code = c.rail_code
);

UPDATE spike.dim_payment_rail_build
SET payment_rail = s.payment_rail,
    scheme_family = s.payment_rail,
    loaded_at = GETDATE()
FROM spike.stg_bc_payment_rail s
WHERE dim_payment_rail_build.rail_code = s.rail_code
  AND s.payment_rail IS NOT NULL
  AND COALESCE(dim_payment_rail_build.payment_rail, '') <> s.payment_rail;

INSERT INTO spike.dim_payment_rail_build (
    id, rail_code, rail_name, payment_rail, scheme_family, reason,
    full_routing_code, source_system, active_flag, loaded_at
)
SELECT
    mx.max_id + ROW_NUMBER() OVER (ORDER BY s.rail_code) AS id,
    s.rail_code,
    s.payment_rail AS rail_name,
    s.payment_rail,
    s.payment_rail AS scheme_family,
    s.direction AS reason,
    '010' || s.rail_code AS full_routing_code,
    'banking_circle_payments' AS source_system,
    TRUE AS active_flag,
    GETDATE() AS loaded_at
FROM spike.stg_bc_payment_rail s
CROSS JOIN (
    SELECT COALESCE(MAX(id), 0) AS max_id
    FROM spike.dim_payment_rail_build
) mx
WHERE s.payment_rail IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM spike.dim_payment_rail_build b
      WHERE b.rail_code = s.rail_code
  );
