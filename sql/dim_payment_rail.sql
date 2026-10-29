-- Grain: one rail code (F###).
-- PK: id, ordered by rail_code.
-- Natural key: rail_code. Display name prefers the B4B portal description, then Bread for Scrap, then the routing catalogue.
-- Fact FK: fact_payment.rail_sk → dim_payment_rail.id

CREATE TABLE spike.dim_payment_rail (
    id                INTEGER      NOT NULL,
    rail_code         VARCHAR(255) NOT NULL,
    rail_name         VARCHAR(512),
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
    id, rail_code, rail_name, scheme_family, reason,
    full_routing_code, source_system, active_flag, loaded_at
)
WITH bc AS (
    SELECT
        TRIM(code) AS rail_code,
        rail AS rail_name,
        reason,
        CAST(NULL AS VARCHAR) AS full_routing_code
    FROM spike.stg_bc_banking_circle_routing_codes
    WHERE code IS NOT NULL AND TRIM(code) <> ''
),
pr AS (
    SELECT
        REGEXP_SUBSTR(code, 'F[0-9]{3}') AS rail_code,
        description AS rail_name,
        CAST(NULL AS VARCHAR) AS reason,
        TRIM(code) AS full_routing_code
    FROM spike.stg_b4b_payment_routings
    WHERE REGEXP_SUBSTR(code, 'F[0-9]{3}') <> ''
),
pr_b4s AS (
    SELECT
        REGEXP_SUBSTR(code, 'F[0-9]{3}') AS rail_code,
        description AS rail_name,
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
ranked AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY c.rail_code) AS id,
        c.rail_code,
        COALESCE(pr.rail_name, pr_b4s.rail_name, bc.rail_name) AS rail_name,
        CAST(NULL AS VARCHAR) AS scheme_family,
        bc.reason,
        COALESCE(pr.full_routing_code, pr_b4s.full_routing_code) AS full_routing_code,
        CASE
            WHEN bc.rail_code IS NOT NULL AND pr.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'all'
            WHEN bc.rail_code IS NOT NULL AND pr.rail_code IS NOT NULL THEN 'both'
            WHEN bc.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'banking_circle_b4s'
            WHEN pr.rail_code IS NOT NULL AND pr_b4s.rail_code IS NOT NULL THEN 'both_portals'
            WHEN bc.rail_code IS NOT NULL THEN 'banking_circle'
            WHEN pr.rail_code IS NOT NULL THEN 'portal_b4b'
            ELSE 'portal_b4s'
        END AS source_system,
        TRUE AS active_flag,
        GETDATE() AS loaded_at
    FROM codes c
    LEFT JOIN bc ON bc.rail_code = c.rail_code
    LEFT JOIN pr ON pr.rail_code = c.rail_code
    LEFT JOIN pr_b4s ON pr_b4s.rail_code = c.rail_code
)
SELECT * FROM ranked;
