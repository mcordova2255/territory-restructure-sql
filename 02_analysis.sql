-- =====================================================================
-- Territory Restructure: analysis queries
--
-- Ordered the way the work is actually done: find out what is wrong,
-- size it, work out what has been raised against it, then prove nothing
-- was lost. Query 10 is the one that matters. If it returns anything
-- other than zero, the restructure is not defensible.
--
-- SQLite dialect. Run: sqlite3 coverage.db < sql/02_analysis.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Book at a glance
-- ---------------------------------------------------------------------
SELECT 'Named territories, opening'  AS measure, COUNT(*) AS value
FROM sales_territories WHERE segment = 'NAMED'
UNION ALL
SELECT 'Named territories, closing', COUNT(*)
FROM sales_territories WHERE segment = 'NAMED' AND status = 'ACTIVE'
UNION ALL
SELECT 'Organizations tracked', COUNT(*) FROM organizations
UNION ALL
SELECT 'Cases raised', COUNT(*) FROM master_data_cases
UNION ALL
SELECT 'Actions carried by those cases', COUNT(*) FROM case_actions;


-- ---------------------------------------------------------------------
-- 2. Group hierarchy, flattened.
--    Recursive walk up the parent chain to the ultimate parent, with the
--    depth of each entity. Guards against a self-referencing loop by
--    stopping at depth 10.
-- ---------------------------------------------------------------------
WITH RECURSIVE chain(org_id, ancestor_id, depth) AS (
    -- anchor: every organization is its own ancestor at depth 0
    SELECT org_id, org_id, 0 FROM organizations
    UNION ALL
    -- step: climb one level, stopping at the top or at depth 10 if the
    -- data contains a cycle
    SELECT c.org_id, o.parent_org_id, c.depth + 1
    FROM chain c
    JOIN organizations o ON o.org_id = c.ancestor_id
    WHERE o.parent_org_id IS NOT NULL
      AND o.parent_org_id <> c.org_id
      AND c.depth < 10
),
top_of_chain AS (
    SELECT org_id, ancestor_id, depth,
           ROW_NUMBER() OVER (PARTITION BY org_id ORDER BY depth DESC) AS rn
    FROM chain
)
SELECT o.org_id,
       o.org_name,
       t.depth        AS levels_to_top,
       p.org_name     AS ultimate_parent,
       st.territory_name     AS assigned_territory
FROM top_of_chain t
JOIN organizations o  ON o.org_id = t.org_id
JOIN organizations p  ON p.org_id = t.ancestor_id
LEFT JOIN org_assignment a  ON a.org_id = o.org_id AND a.valid_to IS NULL
LEFT JOIN sales_territories st ON st.territory_id = a.territory_id
WHERE t.rn = 1
ORDER BY t.depth DESC, o.org_name
LIMIT 20;


-- ---------------------------------------------------------------------
-- 3. Account health. One row per defect class, which is the view that
--    tells you whether you have a data problem or a process problem.
-- ---------------------------------------------------------------------
WITH defects AS (
    SELECT 'Dissolved or in liquidation, still assigned' AS defect, COUNT(*) AS orgs
    FROM organizations o
    JOIN org_assignment a ON a.org_id = o.org_id AND a.valid_to IS NULL
    WHERE o.entity_status <> 'ACTIVE'
    UNION ALL
    SELECT 'Duplicate record', COUNT(*) FROM organizations WHERE is_duplicate_of IS NOT NULL
    UNION ALL
    SELECT 'Orphan: no open territory assignment', COUNT(*)
    FROM organizations o
    WHERE NOT EXISTS (SELECT 1 FROM org_assignment a
                      WHERE a.org_id = o.org_id AND a.valid_to IS NULL)
    UNION ALL
    SELECT 'Recorded name differs from filed legal name', COUNT(*)
    FROM organizations WHERE legal_name <> org_name
    UNION ALL
    SELECT 'Registered country differs from territory country', COUNT(*)
    FROM organizations o
    JOIN org_assignment a  ON a.org_id = o.org_id AND a.valid_to IS NULL
    JOIN sales_territories t ON t.territory_id = a.territory_id
    WHERE o.reg_country <> t.country_code
)
SELECT defect,
       orgs,
       ROUND(100.0 * orgs / (SELECT COUNT(*) FROM organizations), 1) AS pct_of_book
FROM defects
ORDER BY orgs DESC;


-- ---------------------------------------------------------------------
-- 4. Duplicate clusters on the statutory registry number.
--    The registry number is the join back to the public register, so two
--    live records sharing one is always a defect, whatever the CRM says.
-- ---------------------------------------------------------------------
SELECT o.registry_no,
       o.reg_country,
       COUNT(*)                              AS record_count,
       GROUP_CONCAT(o.org_name, ' | ')       AS records
FROM organizations o
WHERE o.registry_no IS NOT NULL
GROUP BY o.registry_no, o.reg_country
HAVING COUNT(*) > 1
ORDER BY record_count DESC, o.registry_no
LIMIT 15;


-- ---------------------------------------------------------------------
-- 5. Mis-parented accounts: the organization's parent sits under a
--    different territory from the one the organization is assigned to.
--    This is what quietly splits a group across two reps.
-- ---------------------------------------------------------------------
SELECT o.org_id,
       o.org_name,
       t_child.territory_name  AS assigned_territory,
       t_parent.territory_name AS parent_territory
FROM organizations o
JOIN org_assignment a_child  ON a_child.org_id  = o.org_id        AND a_child.valid_to  IS NULL
JOIN sales_territories t_child  ON t_child.territory_id  = a_child.territory_id
JOIN org_assignment a_parent ON a_parent.org_id = o.parent_org_id AND a_parent.valid_to IS NULL
JOIN sales_territories t_parent ON t_parent.territory_id = a_parent.territory_id
WHERE o.parent_org_id IS NOT NULL
  AND t_child.territory_id <> t_parent.territory_id
ORDER BY o.org_name
LIMIT 20;


-- ---------------------------------------------------------------------
-- 6. Case funnel. Implementation rate is the number that tells you
--    whether the bottleneck is your analysis or somebody else's queue.
-- ---------------------------------------------------------------------
SELECT s.status,
       COUNT(c.case_ref)                                                  AS cases,
       ROUND(100.0 * COUNT(c.case_ref) / (SELECT COUNT(*) FROM master_data_cases), 1) AS pct,
       ROUND(AVG(JULIANDAY(COALESCE(c.implemented_date, DATE('now')))
                 - JULIANDAY(c.raised_date)), 1)                          AS avg_days_open
FROM ref_case_status s
LEFT JOIN master_data_cases c ON c.status = s.status
GROUP BY s.status, s.stage_order
ORDER BY s.stage_order DESC;


-- ---------------------------------------------------------------------
-- 7. What was actually changed, split by level.
-- ---------------------------------------------------------------------
SELECT CASE WHEN action_type LIKE '%_ORGANIZATION' THEN 'Organization' ELSE 'Territory' END AS level,
       action_type,
       COUNT(*) AS actions,
       SUM(CASE WHEN c.status = 'Implemented' THEN 1 ELSE 0 END) AS implemented
FROM case_actions ca
JOIN master_data_cases c ON c.case_ref = ca.case_ref
GROUP BY level, action_type
ORDER BY level, actions DESC;


-- ---------------------------------------------------------------------
-- 8. Stranded coverage. An account registered in one country but sitting
--    in the other country's territory is working revenue that nobody is
--    credited for. Sized here so the recovery has a number attached.
-- ---------------------------------------------------------------------
SELECT o.org_name,
       o.reg_country          AS registered_in,
       t.country_code         AS territory_country,
       t.territory_name              AS territory,
       o.employees,
       ROUND(m.tam_before_k, 1) AS territory_tam_k
FROM organizations o
JOIN org_assignment a   ON a.org_id = o.org_id AND a.valid_to IS NULL
JOIN sales_territories t ON t.territory_id = a.territory_id
LEFT JOIN tam_movement m ON m.territory_id = t.territory_id
WHERE o.reg_country <> t.country_code
  AND o.entity_status = 'ACTIVE'
ORDER BY o.employees DESC;


-- ---------------------------------------------------------------------
-- 9. Verification coverage by evidence tier. Mirrors how every claim is
--    labelled: confirmed from a filing, resolved by correction, or
--    flagged as an exception with the reason recorded.
-- ---------------------------------------------------------------------
SELECT verdict,
       evidence_tier,
       COUNT(*) AS orgs,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM verification_log), 1) AS pct
FROM verification_log
GROUP BY verdict, evidence_tier
ORDER BY orgs DESC;


-- ---------------------------------------------------------------------
-- 10. THE RECONCILIATION.
--     Closing must equal opening plus the movement I caused plus the
--     movement the forecast refresh caused. Any non-zero variance means
--     value went missing in the restructure.
--
--     Keeping the two deltas apart is the point: it isolates the effect
--     of my cases from the reforecast, so the book can be defended
--     without claiming credit for the refresh.
-- ---------------------------------------------------------------------
SELECT ROUND(SUM(tam_before_k), 1)                                        AS opening_k,
       ROUND(SUM(delta_from_cases_k), 1)                                  AS movement_from_cases_k,
       ROUND(SUM(delta_reforecast_k), 1)                                  AS movement_from_reforecast_k,
       ROUND(SUM(tam_after_k), 1)                                         AS closing_k,
       ROUND(SUM(tam_before_k) + SUM(delta_from_cases_k)
             + SUM(delta_reforecast_k) - SUM(tam_after_k), 2)             AS variance_k,
       CASE WHEN ABS(SUM(tam_before_k) + SUM(delta_from_cases_k)
                     + SUM(delta_reforecast_k) - SUM(tam_after_k)) < 0.05
            THEN 'BALANCED' ELSE 'DOES NOT TIE' END                       AS result
FROM tam_movement;


-- ---------------------------------------------------------------------
-- 11. Same reconciliation, per territory. Any row that fails is the row
--     to investigate; the aggregate can tie while a row is wrong.
-- ---------------------------------------------------------------------
SELECT t.territory_name,
       m.tam_before_k,
       m.delta_from_cases_k,
       m.delta_reforecast_k,
       m.tam_after_k,
       ROUND(m.tam_before_k + m.delta_from_cases_k
             + m.delta_reforecast_k - m.tam_after_k, 2) AS variance_k
FROM tam_movement m
JOIN sales_territories t ON t.territory_id = m.territory_id
WHERE ABS(m.tam_before_k + m.delta_from_cases_k
          + m.delta_reforecast_k - m.tam_after_k) > 0.05
ORDER BY ABS(m.tam_before_k + m.delta_from_cases_k
             + m.delta_reforecast_k - m.tam_after_k) DESC;


-- ---------------------------------------------------------------------
-- 12. Integrity checks. Each returns PASS or FAIL; run before publishing
--     any figure from this dataset.
-- ---------------------------------------------------------------------
SELECT 'Every assignment points at a real territory' AS check_name,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS result, COUNT(*) AS offending_rows
FROM org_assignment a LEFT JOIN sales_territories t ON t.territory_id = a.territory_id WHERE t.territory_id IS NULL
UNION ALL
SELECT 'Every action belongs to a real case',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM case_actions ca LEFT JOIN master_data_cases c ON c.case_ref = ca.case_ref WHERE c.case_ref IS NULL
UNION ALL
SELECT 'No organization is its own parent',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM organizations WHERE parent_org_id = org_id
UNION ALL
SELECT 'No account holds two open assignments',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM (SELECT org_id FROM org_assignment WHERE valid_to IS NULL
      GROUP BY org_id HAVING COUNT(*) > 1)
UNION ALL
SELECT 'Implemented cases carry an implementation date',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM master_data_cases WHERE status = 'Implemented' AND implemented_date IS NULL
UNION ALL
SELECT 'No case is approved before it was raised',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM master_data_cases WHERE approved_date IS NOT NULL AND approved_date < raised_date
UNION ALL
SELECT 'Every organization has been verified',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END, COUNT(*)
FROM organizations o
LEFT JOIN verification_log v ON v.org_id = o.org_id WHERE v.org_id IS NULL
UNION ALL
SELECT 'TAM ledger ties opening to closing',
       CASE WHEN ABS(SUM(tam_before_k) + SUM(delta_from_cases_k)
                     + SUM(delta_reforecast_k) - SUM(tam_after_k)) < 0.05
            THEN 'PASS' ELSE 'FAIL' END, 0
FROM tam_movement;
