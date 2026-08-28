# Territory Restructure & Master Data Governance — SQL

**Author:** Maria Cordova<br>
**Tools:** SQL (SQLite, PostgreSQL-compatible notes) · Python · pandas<br>
**Companion project:** [territory-coverage-capstone](https://github.com/mcordova2255/territory-coverage-capstone) — the same domain in Python and pandas

All data in this repository is generated. It models the structure and the failure modes of an enterprise coverage dataset. No client or employer data is used anywhere in this project.

---

## The problem this models

A corporate book is being restructured inside a planning cycle. Organizations sit under sales territories; master data cases move, merge, rename, retire and create them; and the addressable market attached to each territory shifts as a result.

Two things make this harder than a cleanup exercise:

1. **Changes can only be raised inside a deployment window.** Sequence matters more than speed, because a correction raised against the wrong window lands in the wrong half and is measured against the wrong quota period.
2. **The book has to reconcile.** Closing value must equal opening value plus the movement the cases caused plus the movement the forecast refresh caused. If it does not tie, value went missing in the restructure and the whole exercise is indefensible.

Query 10 is the one that matters. Everything before it is diagnosis.

---

## Schema

Eight tables. The design decisions worth noting:

| Table | Why it looks like this |
| ----- | ---------------------- |
| `organizations` | Self-referencing `parent_org_id` for the group hierarchy. `registry_no` is the statutory company number, which is the join key back to the public register, so two live records sharing one is always a defect. `legal_name` is held separately from `org_name` because the CRM name and the filed name drift apart. |
| `org_assignment` | Validity dated. A territory move writes a new row and closes the old one rather than overwriting, so the history survives the restructure. |
| `mdm_cases` / `case_actions` | Split one-to-many. A case is the unit of **approval**; an action is the unit of **change**. One approval routinely covers several changes, and collapsing them loses the distinction between what was asked for and what was done. |
| `tam_movement` | Holds two separate delta columns. Movement caused by my cases is kept apart from movement caused by the forecast refresh, so my work can be isolated and I am not claiming credit for the reforecast. |
| `verification_log` | Every organization checked against the current filing, with the verdict and an evidence tier recorded, so the position stays defensible after the cycle closes. |

Evidence tiers follow the same rule used throughout my work: **FACT** taken verbatim from a statutory filing, **DERIVED** calculated from verified figures with the method stated, **ESTIMATE** where no statutory source exists. Anything unverifiable is logged as a gap rather than inferred.

---

## Dataset shape

| Table | Rows | Contents |
| ----- | ---- | -------- |
| `sales_territories` | 71 | 70 named territories opening, 11 retired during the cycle, plus the volume segment |
| `organizations` | 342 | Group parents and their subsidiaries, including deliberate defects |
| `org_assignment` | 342 | Validity-dated territory assignments |
| `mdm_cases` | 141 | Cases across the full lifecycle |
| `case_actions` | 205 | Actions carried by those cases |
| `tam_movement` | 59 | Closing named book with the reconciliation ledger |
| `verification_log` | 342 | One verification verdict per organization |

Defects are seeded on purpose, at rates drawn from what a book that has not been re-tested actually looks like:

| Defect | Records | Share of book |
| ------ | ------- | ------------- |
| Recorded name differs from filed legal name | 39 | 11.4% |
| Dissolved or in liquidation, still assigned | 26 | 7.6% |
| Duplicate record | 22 | 6.4% |
| Orphan, no open territory assignment | 14 | 4.1% |
| Registered country differs from territory country | 9 | 2.6% |
| Mis-parented, parent sits under a different territory | 18 | 5.3% |

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
| **10** | **The reconciliation** | **Opening + case movement + reforecast movement = closing, or it fails** |
| 11 | Reconciliation per territory | The aggregate can tie while a row is wrong; this finds the row |
| 12 | Integrity checks | Eight PASS/FAIL assertions to run before publishing any figure |

---

## Results

```
Named territories, opening        70
Named territories, closing        59
Organizations tracked            342
Cases raised                     141
Actions carried by those cases   205

Case funnel
  Implemented              86    61.0%
  Submitted                16    11.3%
  BA Approved              13     9.2%
  Pending BA Approval      12     8.5%
  Open                      8     5.7%
  Withdrawn / No Change     6     4.3%

Reconciliation
  Opening                   31,862.9K
  Movement from cases         -141.7K
  Movement from reforecast   3,684.1K
  Closing                   35,405.3K
  Variance                       0.0K   BALANCED

Integrity checks             8 of 8 PASS
```

Per-territory reconciliation returns zero rows, meaning no individual territory drifts even though the aggregate ties.

---

## Running it

```bash
python build_dataset.py             # writes data/*.csv and mdm.db
sqlite3 mdm.db < 02_analysis.sql    # runs all twelve queries
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
