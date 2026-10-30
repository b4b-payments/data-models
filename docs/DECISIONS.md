# Decisions — data-models

## 2026-10-30 — Payment fact stays thin (proposed, not final)

**Status:** open. Do not change `fact_payment` until this is accepted.

**Proposal:** `fact_payment` keeps surrogate keys, `source_system`, `source_payment_id`, additive amounts, and `loaded_at` / `batch_run_id`. Status labels, direction, SCA, names, account numbers, country names, and reason text move to dimensions. Rates and ratios are calculated in Cube.

Grain stays one BCTN for B4B and B4S, and one Oversight payment. Evidence and the column list are in data-engineering [30_payment_fact_gap_analysis.md](../../data-engineering/docs/30_payment_fact_gap_analysis.md).

Lifecycle status for a linked portal outgoing payment is `payments.status`, not BCTN `status`. BCTN `status` is only `pending` or `failed` and stays on the fact as the raw operational status until the status dimension exists. The outgoing status clock is `payments.updated_at`. Portal `transaction_date` is a date, so `event_ts` stays the booking date at midnight until charts move.

One external party per payment. Debtor and creditor are role keys, not a bridge. The client side remains `account_sk`. CLE country is not the payment country.

`fee_amount` is out until a payment fee source exists. `fact_exchange_rate` is for reporting conversion only, and it needs a refresh: the current 513,378 rows were loaded on 5 Aug 2026.

## 2026-10-30 — An incremental run drops a fact row whose source key is gone

**Decision:** Before `delete+insert`, an incremental `fact_payment` run deletes a row when its changed Oversight payment id or Banking Circle notification id is in `pipeline_changed_key` for this `pipeline_run_id` and is no longer in staging. A key that is still in staging is updated by the existing select. A full refresh does not use this delete.

## 2026-10-29 — fact_payment incremental keys (final for the micro-batch)

**Decision:** `fact_payment` is incremental with `unique_key` `(source_system, source_payment_id)` and `delete+insert`. `payment_sk` is `fnv_hash(source_system || '|' || source_payment_id)`, so a rebuild does not renumber the fact. An incremental run reads only the Banking Circle notification ids and Oversight payment ids in `spike.pipeline_changed_key` for `pipeline_run_id`. A full refresh ignores that filter. The full `payment_sk` uniqueness test is tagged `weekly_reconcile` and is not part of the micro-batch test selection.

## 2026-10-29 — dbt extension language server (final for this project)

**Decision (final):** The published project opts into dbt v2 static analysis so the dbt VS Code extension can run its full language server (column lineage, column go-to-definition, type checks).

- `dbt_project.yml` sets `+static_analysis: strict` on models, data tests, and sources.
- Property YAML uses `data_tests` (the `tests` key is the deprecated alias).
- `require-dbt-version` is `[">=1.12.0", "<3.0.0"]` so dbt v2 can parse the project. The UAT runner stays `dbt-core==1.12.6` in `~/.local/share/dbt/venv`. dbt version ranges are a single AND, so the project file can no longer exclude the 1.13 beta by itself.

Strict mode is enforced by dbt v2. dbt 1.12 stores the config and does not run static analysis.

## 2026-10-28 — Product is first-class (final)

**Decision (final):** **Product** is a native reporting attribute for payments and party dims. Dashboards and Cube must filter / break down by product without inventing joins.

| Code | Meaning |
|---|---|
| `B4B` | Bread for Business portal |
| `B4S` | Bread for Scrap portal |
| `OVERSIGHT` | Oversight |

**Not the same as** `source_system` (`portal_b4b` / `portal_b4s` / `oversight`) — that is technical lineage. Product is the business lens users see.

**Model:**

- `dim_entity.platform` holds these codes. As of 29 Oct 2026 the mart also selects `product` with the same value. Cube `entities.product` reads `product`. `platform` stays so older SQL still runs.
- Facts must always resolve to a product (via entity, or a denormalised `product` on the fact).
- Cube exposes a **`product`** dimension on payments and entities (not only `source_system`).

Related: Airbyte not in active path (2026-10-28); no user-facing “star” naming.

## 2026-10-29 — Oversight null payment_direction defaults to Outgoing (final)

Oversight rows without `banking_circle_api_response.payment.classification` are failed BC error payloads (no payment object). Product is outbound initiation; coalesce those to `Outgoing` in `fact_payment` instead of leaving null.
