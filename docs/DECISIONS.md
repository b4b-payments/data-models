# Decisions — data-models

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
