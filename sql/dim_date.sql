-- Grain: one calendar day.
-- PK: id = DATEDIFF(day, DATE '2000-01-01', calendar_date) + 1
-- Range: 2000-01-01 .. 2040-12-31. Do not prepend dates; that would shift every id.
-- Fact FK: fact_payment.date_sk → dim_date.id

CREATE TABLE spike.dim_date (
    id              INTEGER     NOT NULL,
    calendar_date   DATE        NOT NULL,
    yyyymmdd        INTEGER     NOT NULL,
    year_num        SMALLINT    NOT NULL,
    quarter_num     SMALLINT    NOT NULL,
    month_num       SMALLINT    NOT NULL,
    month_name      VARCHAR(16) NOT NULL,
    day_num         SMALLINT    NOT NULL,
    day_of_week     SMALLINT    NOT NULL,
    day_name        VARCHAR(16) NOT NULL,
    is_weekend      BOOLEAN     NOT NULL,
    is_month_end    BOOLEAN     NOT NULL,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT GETDATE()
)
DISTSTYLE ALL
SORTKEY (id);
