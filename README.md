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
| `dim_card` | One portal card on B4B or Bread for Scrap. No PAN |
| `dim_cardholder` | One portal cardholder |
| `dim_card_product` | One portal card product |
| `dim_card_scheme` | One scheme code |
| `dim_processor` | One processor family |
| `fact_card_financial` | One GPS presentment. Scheme settlement |
| `fact_card_balance_posting` | One portal row that posts to the customer balance |
| `fact_card_ehi_observation` | One other portal card message. Amounts are not measures |
| `fact_card_authorisation` | One GPS authorisation, including declines |
| `fact_card_fee` | One GPS scheme fee |
| `fact_card_load` | One portal or GPS load or unload. The two sources are not added |
| `bridge_card_lifecycle_match` | One link between card evidence. No amounts |
| `fct_card_transaction_snapshot` | One current lifecycle group. Counts only |

`models/mart` is the dbt project. `sql/` is the reference dimensions the payment fact joins to. `cube/payments.yml` is payments, entities, accounts, dates, currencies, and payment rails. `cube/cards.yml` names a separate measure on each cards fact.
