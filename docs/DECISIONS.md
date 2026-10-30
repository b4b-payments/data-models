# Decisions — data-models

## 2026-10-30 — EUR payment volume is a view over as-of Yahoo FX (final)

**Decision (final):** Do not store `amount_eur` on `fact_payment` — FX is late-arriving. Publish `fact_exchange_rate_daily` (incremental, grain `from_currency_sk`, `to_currency_sk`, `date_sk`, `vendor`) from `stg_passfort_fx_daily_rates`.

Yahoo pairs are USD-crossed (DKK_USD, USD_EUR, …), not direct DKK_EUR. Convert with identity / direct `from→reporting` / else `from→USD * USD→reporting`, as-of booking date.

**Shape (updated):** Keep `fact_payment`. Add a **slim materialized reporting fact** (`payment_sk` + `amount_gbp` / `amount_eur` / `amount_usd`) to conjoin 1:1; rebuild when FX arrives late. Interim `v_fact_payment_amount_eur` proved as-of via_usd (EUR only). Pickup: data-engineering `docs/31_fx_reporting_pickup.md`.

Staging keeps up with the PassFort sync cron via watermark merge (`run_fx_incremental.sh`); dbt incremental uses `source_updated_at` plus a 3-day `rate_date` lookback.

## 2026-10-30 — Counterparty grain is the account, and the other role is unknown (final for this phase)

**Decision (final for this phase):** From the council review of the same date. `dim_party` is one row per product and trimmed counterparty account for B4B and B4S, and one row per product and `beneficiary_id` for OVERSIGHT. The fact hashes that key from the payment row. A blank account hashes the single token `~unknown`. The name is a label, not part of the key.

The client stays on the fact as `account_sk` and `entity_sk`. There is no party bridge. Outgoing, including an Oversight row defaulted to Outgoing, writes the external key to `creditor_party_sk` and `~unknown` to `debtor_party_sk`. Incoming does the opposite. The client is not written into either role key.

The micro-batch may keep the spelling from the row that first inserts the key. The weekly refresh sets the display name to the most common non-blank spelling, and stores a client count and a name count. Those counts are not in the hash. A later spelling changes the label. The key and the amounts stay as booked. Financial institution and country are weekly attributes on the party. They are blank too often to be part of the hash. B4B institution is blank on 121,000 of 1,213,313 notifications, and country is blank on 49,864.

B4B and B4S stay separate until overlap is measured. Product is in the key, so a later collapse rewrites party keys already stored on the fact. OVERSIGHT uses `beneficiary_id` until a beneficiary table is staged. Whether one `beneficiary_id` is reused across clients is unmeasured.

In Cube, the external party on a fact row is the role key that is not `~unknown`. Questions about who pays a party, top counterparties, and whether two clients share a party exclude that token. A party that is a creditor on one payment and a debtor on another is the same party, so those questions read both role keys.

The account used by 1,398 B4B clients and the account that carries 775 names are separate maxima. They were not shown to be the same account, and what either is remains unknown. Payment count and value on each are unmeasured, so neither is treated as dominating the book.

## 2026-10-30 — New payment keys are hashes computed on the fact (final)

**Decision (final):** Each new payment surrogate key (`payment_status_sk`, `source_status_sk`, `payment_profile_sk`, `failure_reason_sk`, `payment_type_sk`, `debtor_party_sk`, `creditor_party_sk`, `debtor_country_sk`, `creditor_country_sk`) is `fnv_hash` of its natural key, calculated in `fact_payment`. The dimension uses the same expression. A null natural key hashes the token `~unknown`, and every new dimension carries that row.

The fact does not join a dimension to obtain the key. The dimension and the fact can build in either order, an incremental tick does not wait on a dimension refresh, and a rebuild does not renumber a key. `payment_sk` already works this way.

Schema work still waits on the open thin-fact gates in data-engineering `tasks/todo.md`.

## 2026-10-30 — Counterparty name is visible in Cube for now (final for this phase)

**Decision (final for this phase):** `dim_party` name, financial institution, and country go into the Cube payments model. Every person who can open B4B BI can see them. The account number stays off Cube; `dim_party` stores a hash of it.

Restrictions wait until the BI rollout. Cube has one SQL password and no per-user rules today, so there is no second role to attach the name to.

## 2026-10-30 — Payment fact stays thin (proposed, not final)

**Status:** open. Do not change `fact_payment` until this is accepted.

**Proposal:** `fact_payment` keeps surrogate keys, `source_system`, `source_payment_id`, additive amounts, and `loaded_at` / `batch_run_id`. Status labels, direction, SCA, names, account numbers, country names, and reason text move to dimensions. Rates and ratios are calculated in Cube.

Grain stays one BCTN for B4B and B4S, and one Oversight payment. Evidence and the column list are in data-engineering [30_payment_fact_gap_analysis.md](../../data-engineering/docs/30_payment_fact_gap_analysis.md).

Lifecycle status for a linked portal outgoing payment is `payments.status`, not BCTN `status`. BCTN `status` is only `pending` or `failed` and stays on the fact as the raw operational status until the status dimension exists. The outgoing status clock is `payments.updated_at`. Portal `transaction_date` is a date, so `event_ts` stays the booking date at midnight until charts move.

One external party per payment. The accepted party grain is the 30 Oct 2026 council decision above. Debtor and creditor are role keys, not a bridge. The client side remains `account_sk`. CLE country is not the payment country.

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
