-- Grain: one currency.
-- PK: id, a stable integer ordered by currency_code.
-- Natural key: currency_code (catalogue code — ISO alpha for fiat, ticker for crypto extras).
-- ISO 4217: iso_currency_code (alpha-3) + numeric_code (numeric-3) + minor_units.
--   iso_currency_code is null for non-ISO instruments (e.g. Yahoo crypto).
-- Seed: ISO 4217, plus FX extras that are not in that list.
-- Fact FK: fact_payment.currency_sk → dim_currency.id

CREATE TABLE spike.dim_currency (
    id                  INTEGER     NOT NULL,
    currency_code       VARCHAR(8)  NOT NULL,
    currency_name       VARCHAR(128),
    iso_currency_code   VARCHAR(3),
    numeric_code        VARCHAR(8),
    minor_units         SMALLINT,
    is_iso_seed         BOOLEAN     NOT NULL DEFAULT TRUE,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT GETDATE()
)
DISTSTYLE ALL
SORTKEY (id);
