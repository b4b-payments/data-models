# B4B data models

Final reporting star. Schema: `spike`.

A portal company is a currency account. The legal entity is the client legal entity. Facts carry both keys. Global IDs come from the identifier registry only.

**Product** is first-class for reporting: `B4B` | `B4S` | `OVERSIGHT` (see [docs/DECISIONS.md](docs/DECISIONS.md)). Distinct from technical `source_system`.

| Model | Grain |
|---|---|
| `dim_gid` | One global identifier |
| `dim_entity` | One legal entity. PSU is the client legal entity on B4B or Bread for Scrap. Agent and Intermediate are included. |
| `dim_account` | One currency account, linked to the legal entity on the same portal |
| `fact_payment_deposit` | One portal payment notification (B4B or Bread for Scrap), or one Oversight payment |
| `dim_date` | One calendar day. `id` is days since 2000-01-01, plus 1 |
| `dim_currency` | One currency. `id` is a stable integer ordered by ISO code |
| `dim_payment_rail` | One rail code (`F###`) |

`models/mart` is the dbt project for the party dimensions and the payment fact. `sql/` is the reference dimensions those facts join to. `cube/payments.yml` is the reporting layer: `payments`, `entities`, `accounts`, `dates`, `currencies`, `payment_rails`.
