-- Grain: one currency.
-- PK: id, a stable integer ordered by currency_code.
-- Natural key: currency_code (ISO 4217 alpha).
-- Seed: ISO 4217, plus any payment currency that is not in that list.
-- Fact FK: fact_payment.currency_sk → dim_currency.id

CREATE TABLE spike.dim_currency (
    id              INTEGER     NOT NULL,
    currency_code   VARCHAR(8)  NOT NULL,
    currency_name   VARCHAR(128),
    numeric_code    VARCHAR(8),
    minor_units     SMALLINT,
    is_iso_seed     BOOLEAN     NOT NULL DEFAULT TRUE,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT GETDATE()
)
DISTSTYLE ALL
SORTKEY (id);
