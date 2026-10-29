# Decisions — data-models

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
