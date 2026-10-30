-- Append currency codes present on PassFort FX staging but missing from dim_currency.
-- Crypto Yahoo seeds (BTC, ETH, …) land here with is_iso_seed = false.
-- Idempotent. Run before the first fact_exchange_rate_daily build / after new instruments.

INSERT INTO spike.dim_currency (
    id,
    currency_code,
    currency_name,
    numeric_code,
    minor_units,
    is_iso_seed,
    loaded_at
)
WITH codes AS (
    SELECT DISTINCT upper(trim(base_code)) AS currency_code
    FROM spike.stg_passfort_fx_daily_rates
    WHERE nullif(trim(base_code), '') IS NOT NULL
    UNION
    SELECT DISTINCT upper(trim(quote_code))
    FROM spike.stg_passfort_fx_daily_rates
    WHERE nullif(trim(quote_code), '') IS NOT NULL
    UNION
    SELECT DISTINCT upper(trim(base_code))
    FROM spike.stg_passfort_fx_instruments
    WHERE nullif(trim(base_code), '') IS NOT NULL
    UNION
    SELECT DISTINCT upper(trim(quote_code))
    FROM spike.stg_passfort_fx_instruments
    WHERE nullif(trim(quote_code), '') IS NOT NULL
),
missing AS (
    SELECT c.currency_code
    FROM codes c
    LEFT JOIN spike.dim_currency d
      ON d.currency_code = c.currency_code
    WHERE d.id IS NULL
),
ranked AS (
    SELECT
        currency_code,
        (SELECT coalesce(max(id), 0) FROM spike.dim_currency)
            + row_number() OVER (ORDER BY currency_code) AS id
    FROM missing
)
SELECT
    id,
    currency_code,
    currency_code AS currency_name,
    CAST(NULL AS VARCHAR(8)) AS numeric_code,
    CAST(NULL AS SMALLINT) AS minor_units,
    FALSE AS is_iso_seed,
    getdate() AS loaded_at
FROM ranked;
