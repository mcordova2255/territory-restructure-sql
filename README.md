# Territory Restructure & Master Data Governance - SQL

Author: Maria Cordova<br>
Tools: SQL (SQLite, PostgreSQL-compatible notes) · Python · pandas<br>
Companion project: [territory-coverage-capstone](https://github.com/mcordova2255/territory-coverage-capstone) - the same domain in Python and pandas

All data in this repository is generated. It models the structure and the failure modes of an enterprise coverage dataset. No client or employer data is used anywhere in this project.

---

## The problem this models

A corporate book is being restructured inside a planning cycle. Organizations sit under sales territories; master data cases move, merge, rename, retire and create them; and the addressable market attached to each territory shifts as a result.

Two things make this harder than a cleanup exercise:

1. Changes can only be raised inside a deployment window. Sequence matters more than speed, because a correction raised against the wrong window lands in the wrong half and is measured against the wrong quota period.
2. The book has to reconcile. Closing value must equal opening value plus the movement the cases caused plus the movement the forecast refresh caused. If it does not tie, value went missing in the restructure and the whole exercise is indefensible.

Query 10 is the one that matters. Everything before it is diagnosis.

---

## Schema

Eight tables. The design decisions worth noting:

| Table | Why it looks like this |
| ----- | ---------------------- |
| `organizations` | Self-referencing `parent_org_id` for the group hierarchy. `registry_no` is the statutory company number, which is the join key back to the public register, so two live records sharing one is always a defect. `legal_name` is held separately from `org_name` because the CRM name and the filed name drift apart. |
| `org_assignment` | Validity dated. A territory move writes a new row and closes the old one rather than overwriting, so the history survives the restructure. |
| `master_data_cases` / `case_actions` | Split one-to-many. A case is the unit of approval; an action is the unit of change. One approval routinely covers several changes, and collapsing them loses the distinction between what was asked for and what was done. |
| `tam_movement` | Covers every named territory that opened the cycle, so retired territories close to zero rather than dropping out. Two separate delta columns: case-driven movement is held apart from reforecast movement, so one contributor's effect can be isolated from background change. |
| `verification_log` | Every organization checked against the current filing, with the verdict and an evidence tier recorded, so the position stays defensible after the cycle closes. |

Evidence tiers follow a single rule: FACT taken verbatim from a statutory filing, DERIVED calculated from verified figures with the method stated, ESTIMATE where no statutory source exists. Anything unverifiable is logged as a gap rather than inferred.

---

## Dataset shape

| Table | Rows | Contents |
| ----- | ---- | -------- |
| `sales_territories` | 89 | 88 named territories opening, 14 retired during the cycle, plus the volume segment |
| `organizations` | 415 | Group parents and their subsidiaries, including deliberate defects |
| `org_assignment` | 415 | Validity-dated territory assignments |
| `master_data_cases` | 96 | Cases across the full lifecycle |
| `case_actions` | 138 | Actions carried by those cases |
| `tam_movement` | 88 | Every named territory that opened the cycle; the retired ones close to zero |
| `verification_log` | 415 | One verification verdict per organization |

Defects are seeded on purpose, at rates drawn from what a book that has not been re-tested actually looks like:

| Defect | Records | Share of book |
| ------ | ------- | ------------- |
| Recorded name differs from filed legal name | 52 | 12.5% |
| Dissolved or in liquidation, still assigned | 32 | 7.7% |
| Duplicate record | 27 | 6.5% |
| Mis-parented, parent sits under a different territory | 22 | 5.3% |
| Orphan, no open territory assignment | 17 | 4.1% |
| Registered country differs from territory country | 11 | 2.7% |

---

## The queries

`02_analysis.sql`, in the order the work is actually done.

| # | Query | What it demonstrates |
| - | ----- | -------------------- |
| 1 | Book at a glance | Aggregation, `UNION ALL` control totals |
| 2 | Group hierarchy flattened | Recursive CTE with cycle guard, window function to pick the top of each chain |
| 3 | Account health by defect class | Correlated existence checks, share-of-book calculation |
| 4 | Duplicate clusters on registry number | `GROUP BY ... HAVING`, string aggregation |
| 5 | Mis-parented accounts | Self-join across two assignment paths |
| 6 | Case funnel and ageing | `LEFT JOIN` from a reference table so empty stages still appear, date arithmetic |
| 7 | Actions by level and type | Conditional aggregation |
| 8 | Stranded coverage | Cross-country mismatch, sized so a recovery has a number attached |
| 9 | Verification coverage by evidence tier | Distribution across the labelling scheme |
| 10 | The reconciliation | Opening + case movement + reforecast movement = closing, or it fails |
| 11 | Reconciliation per territory | The aggregate can tie while a row is wrong; this finds the row |
| 12 | Integrity checks | Eight PASS/FAIL assertions to run before publishing any figure |

---

## Results

```
Named territories, opening        88
Named territories, closing        74
Organizations tracked            415
Cases raised                      96
Actions carried by those cases   138

Case funnel
  Implemented              59     61.5%
  Submitted                11     11.5%
  BA Approved               9      9.4%
  Pending BA Approval       8      8.3%
  Open                      6      6.3%
  Withdrawn                 3      3.1%

Reconciliation
  Opening                   18,450.0K
  Movement from cases          -92.5K
  Movement from reforecast   2,140.3K
  Closing                   20,497.8K
  Variance                       0.0K   BALANCED

Integrity checks             8 of 8 PASS
```

Per-territory reconciliation returns zero rows, meaning no individual territory drifts even though the aggregate ties.

---

## Running it

```bash
python build_dataset.py             # writes data/*.csv and coverage.db
sqlite3 coverage.db < 02_analysis.sql    # runs all twelve queries
```

`build_dataset.py` finds `01_schema.sql` whether it sits at the repository
root or in a `sql/` folder, and regenerates the CSVs on every run.

The generator is seeded, so the dataset is identical on every run and the figures above are reproducible.

---

## Skills demonstrated

- Relational schema design with referential integrity, check constraints and validity dating
- Recursive CTEs for hierarchy resolution, with a cycle guard
- Window functions for deduplication and top-of-chain selection
- Conditional aggregation and funnel analysis over a status lifecycle
- Reconciliation logic that isolates one contributor's effect from background movement
- Automated integrity assertions as a precondition for publishing figures
