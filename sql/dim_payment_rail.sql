-- Grain: one rail code (F###).
-- PK: id, ordered by rail_code.
-- Natural key: rail_code.
-- rail_name: long portal description (B4B, then B4S, then BC rail text).
-- payment_rail: BC scheme name for grouping (routing catalogue.rail). Historic payments
--   only had F###; this attribute bridges them to BC payment_rail / payment_scheme vocabulary.
-- reason: Incoming/Outgoing from BC catalogue, else parsed from portal description.
-- Fact FK: fact_payment.rail_sk → dim_payment_rail.id

-- Requires table owner / admin (IAM AdministratorAccess). airbyte_spike cannot DROP this table;
-- until swapped, Cube may read spike.dim_payment_rail_build (same grain/ids).
DROP TABLE IF EXISTS spike.dim_payment_rail;

CREATE TABLE spike.dim_payment_rail (
    id                INTEGER      NOT NULL,
    rail_code         VARCHAR(255) NOT NULL,
    rail_name         VARCHAR(512),
    payment_rail      VARCHAR(64),
    scheme_family     VARCHAR(64),
    reason            VARCHAR(255),
    full_routing_code VARCHAR(32),
    source_system     VARCHAR(64)  NOT NULL,
    active_flag       BOOLEAN,
    loaded_at         TIMESTAMPTZ  NOT NULL DEFAULT GETDATE()
)
DISTSTYLE ALL
SORTKEY (id);

INSERT INTO spike.dim_payment_rail (
    id, rail_code, rail_name, payment_rail, scheme_family, reason,
    full_routing_code, source_system, active_flag, loaded_at
)
WITH bc AS (
    SELECT
        TRIM(code) AS rail_code,
        rail AS bc_rail,
        reason AS bc_reason,
        CAST(NULL AS VARCHAR) AS full_routing_code
    FROM spike.stg_bc_banking_circle_routing_codes
    WHERE code IS NOT NULL AND TRIM(code) <> ''
),
pr AS (
    SELECT
        REGEXP_SUBSTR(code, 'F[0-9]{3}') AS rail_code,
        description AS portal_name,
        TRIM(code) AS full_routing_code
    FROM spike.stg_b4b_payment_routings
    WHERE REGEXP_SUBSTR(code, 'F[0-9]{3}') <> ''
),
pr_b4s AS (
    SELECT
        REGEXP_SUBSTR(code, 'F[0-9]{3}') AS rail_code,
        description AS portal_name,
        TRIM(code) AS full_routing_code
    FROM spike.stg_b4s_payment_routings
    WHERE REGEXP_SUBSTR(code, 'F[0-9]{3}') <> ''
),
codes AS (
    SELECT rail_code FROM bc
    UNION
    SELECT rail_code FROM pr
    UNION
    SELECT rail_code FROM pr_b4s
),
joined AS (
    SELECT
        c.rail_code,
        COALESCE(pr.portal_name, pr_b4s.portal_name, bc.bc_rail) AS rail_name,
        bc.bc_rail,
        bc.bc_reason,
        COALESCE(pr.portal_name, pr_b4s.portal_name) AS portal_name,
        COALESCE(pr.full_routing_code, pr_b4s.full_routing_code) AS full_routing_code,
        CASE
            WHEN bc.rail_code IS NOT NULL AND pr.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'all'
            WHEN bc.rail_code IS NOT NULL AND pr.rail_code IS NOT NULL THEN 'both'
            WHEN bc.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'banking_circle_b4s'
            WHEN pr.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'both_portals'
            WHEN bc.rail_code IS NOT NULL THEN 'banking_circle'
            WHEN pr.rail_code IS NOT NULL THEN 'portal_b4b'
            ELSE 'portal_b4s'
        END AS source_system
    FROM codes c
    LEFT JOIN bc ON bc.rail_code = c.rail_code
    LEFT JOIN pr ON pr.rail_code = c.rail_code
    LEFT JOIN pr_b4s ON pr_b4s.rail_code = c.rail_code
),
derived AS (
    SELECT
        rail_code,
        rail_name,
        COALESCE(
            bc_rail,
            -- Portal-only F-codes: match BC vocabulary embedded in the long description
            CASE
                WHEN portal_name ILIKE '%SEPA (SCT Inst)%' THEN 'SEPA (SCT Inst)'
                WHEN portal_name ILIKE '%SEPA (SCT)%' THEN 'SEPA (SCT)'
                WHEN portal_name ILIKE '%Faster Payments%' THEN 'Faster Payments'
                WHEN portal_name ILIKE '%Local Clearing%' THEN 'Local Clearing'
                WHEN portal_name ILIKE '%IntraRegional%' THEN 'IntraRegional'
                WHEN portal_name ILIKE '%Crossborder%' THEN 'Crossborder'
                WHEN portal_name ILIKE '%RIX-RTGS%' THEN 'RIX-RTGS'
                WHEN portal_name ILIKE '%Kronos2%' THEN 'Kronos2'
                WHEN portal_name ILIKE '%Target%' THEN 'Target'
                WHEN portal_name ILIKE '%Chaps%' THEN 'Chaps'
                WHEN portal_name ILIKE '%BACS%' THEN 'BACS'
                WHEN portal_name ILIKE '%BANKING CIRCLE INTERNAL%' THEN 'Internal'
                WHEN portal_name ILIKE '%Fiduciary Sweep%' THEN 'Internal'
                WHEN portal_name ILIKE '%Internal%' THEN 'Internal'
                ELSE NULL
            END
        ) AS payment_rail,
        COALESCE(
            bc_reason,
            CASE
                WHEN portal_name ILIKE 'Outgoing%' THEN 'Outgoing'
                WHEN portal_name ILIKE 'Incoming%' THEN 'Incoming'
                ELSE NULL
            END
        ) AS reason,
        full_routing_code,
        source_system
    FROM joined
)
SELECT
    ROW_NUMBER() OVER (ORDER BY rail_code) AS id,
    rail_code,
    rail_name,
    payment_rail,
    payment_rail AS scheme_family,
    reason,
    full_routing_code,
    source_system,
    TRUE AS active_flag,
    GETDATE() AS loaded_at
FROM derived;
