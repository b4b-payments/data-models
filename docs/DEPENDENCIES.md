# Dependencies — data-models

Cross-repo graph for the B4B data stack. Sibling clones: `/root/DEV/` + `data-stack.code-workspace`.

## Provides

| Consumer | What they take |
|---|---|
| [data-cube](https://github.com/b4b-payments/data-cube) | Semantic alignment with mart / `cube/` YAML |
| [data-superset](https://github.com/b4b-payments/data-superset) | Metric/grain meaning (via Cube, not raw SQL) |
| [data-engineering](https://github.com/b4b-payments/data-engineering) | DDL / mapping cross-check |

## Depends on

| Peer | Notes |
|---|---|
| Warehouse DDL / loads | Physical tables must exist in Redshift; ingest path TBD (not Airbyte this phase) |
| [data-engineering](https://github.com/b4b-payments/data-engineering) | Enterprise model docs / SQL references |

## Visibility note

This repo is currently **public** on GitHub; the other three data repos are **private**. Prefer keeping model SoT readable to the private stack (same org). Revisit visibility if secrets or customer-specific logic land here.
