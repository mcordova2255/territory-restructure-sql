-- =====================================================================
-- Territory Restructure & Master Data Governance
-- Schema definition. SQLite dialect; notes inline for PostgreSQL.
--
-- Models a corporate book being restructured inside a planning cycle:
-- organizations sitting under sales territories, master data cases that
-- change them, and a TAM ledger that must reconcile before and after.
--
-- All data generated. No client or employer data.
-- =====================================================================

DROP TABLE IF EXISTS case_actions;
DROP TABLE IF EXISTS mdm_cases;
DROP TABLE IF EXISTS verification_log;
DROP TABLE IF EXISTS tam_movement;
DROP TABLE IF EXISTS org_assignment;
DROP TABLE IF EXISTS organizations;
DROP TABLE IF EXISTS sales_territories;
DROP TABLE IF EXISTS ref_case_status;

-- ---------------------------------------------------------------------
-- Reference: case lifecycle. Ordered so funnel queries can sort by stage.
-- ---------------------------------------------------------------------
CREATE TABLE ref_case_status (
    status          TEXT PRIMARY KEY,
    stage_order     INTEGER NOT NULL,
    is_terminal     INTEGER NOT NULL CHECK (is_terminal IN (0,1)),
    counts_as_raised INTEGER NOT NULL CHECK (counts_as_raised IN (0,1))
);

-- ---------------------------------------------------------------------
-- Sales territories. The named book plus the volume segment that
-- absorbs merged-out accounts.
-- ---------------------------------------------------------------------
CREATE TABLE sales_territories (
    st_id           INTEGER PRIMARY KEY,
    st_name         TEXT    NOT NULL,
    country_code    TEXT    NOT NULL CHECK (country_code IN ('GB','IE')),
    segment         TEXT    NOT NULL CHECK (segment IN ('NAMED','VOLUME')),
    status          TEXT    NOT NULL CHECK (status IN ('ACTIVE','RETIRED')),
    opened_cycle    TEXT,
    retired_cycle   TEXT
);

-- ---------------------------------------------------------------------
-- Organizations. Self-referencing parent for the group hierarchy.
-- registry_no is the statutory company number; it is the join key back
-- to the public register, and duplicates on it are a data defect.
-- ---------------------------------------------------------------------
CREATE TABLE organizations (
    org_id          INTEGER PRIMARY KEY,
    org_name        TEXT    NOT NULL,
    legal_name      TEXT,                      -- name as filed; may differ from CRM
    registry_no     TEXT,
    reg_country     TEXT    NOT NULL CHECK (reg_country IN ('GB','IE')),
    parent_org_id   INTEGER REFERENCES organizations(org_id),
    ultimate_parent_hint TEXT,
    employees       INTEGER,
    entity_status   TEXT    NOT NULL CHECK (entity_status IN ('ACTIVE','DISSOLVED','LIQUIDATION')),
    is_duplicate_of INTEGER REFERENCES organizations(org_id),
    created_cycle   TEXT
);

-- ---------------------------------------------------------------------
-- Which territory an organization sits under, with validity dates so a
-- move is a new row rather than an overwrite. Open assignment = NULL end.
-- ---------------------------------------------------------------------
CREATE TABLE org_assignment (
    assignment_id   INTEGER PRIMARY KEY,
    org_id          INTEGER NOT NULL REFERENCES organizations(org_id),
    st_id           INTEGER NOT NULL REFERENCES sales_territories(st_id),
    valid_from      TEXT    NOT NULL,
    valid_to        TEXT
);

-- ---------------------------------------------------------------------
-- Master data cases. One case can carry several actions, so the actions
-- live in a child table. Cases are the unit of approval; actions are the
-- unit of change.
-- ---------------------------------------------------------------------
CREATE TABLE mdm_cases (
    case_ref        TEXT PRIMARY KEY,
    case_level      TEXT NOT NULL CHECK (case_level IN ('ORG','ST')),
    status          TEXT NOT NULL REFERENCES ref_case_status(status),
    raised_date     TEXT NOT NULL,
    approved_date   TEXT,
    implemented_date TEXT,
    target_cycle    TEXT NOT NULL,
    CHECK (approved_date    IS NULL OR approved_date    >= raised_date),
    CHECK (implemented_date IS NULL OR implemented_date >= raised_date)
);

CREATE TABLE case_actions (
    action_id       INTEGER PRIMARY KEY,
    case_ref        TEXT NOT NULL REFERENCES mdm_cases(case_ref),
    action_type     TEXT NOT NULL CHECK (action_type IN
                        ('MOVE_ORG','MERGE_ORG','DEACTIVATE_ORG','CREATE_ORG','RENAME_ORG',
                         'RENAME_ST','MERGE_ST','CREATE_ST','RECLASSIFY_ST')),
    org_id          INTEGER REFERENCES organizations(org_id),
    st_id           INTEGER REFERENCES sales_territories(st_id),
    tam_delta_k     REAL NOT NULL DEFAULT 0,
    -- an action must point at whatever level its type implies
    CHECK ( (action_type LIKE '%_ORG' AND org_id IS NOT NULL)
         OR (action_type LIKE '%_ST'  AND st_id  IS NOT NULL) )
);

-- ---------------------------------------------------------------------
-- TAM ledger. The reconciliation lives here: every territory's closing
-- position must equal its opening position plus the movement I caused
-- plus the movement the forecast refresh caused. Those two deltas are
-- kept apart on purpose, so my work can be isolated from the reforecast.
-- ---------------------------------------------------------------------
CREATE TABLE tam_movement (
    st_id                INTEGER PRIMARY KEY REFERENCES sales_territories(st_id),
    tam_before_k         REAL NOT NULL,
    tam_after_k          REAL NOT NULL,
    delta_from_cases_k   REAL NOT NULL DEFAULT 0,
    delta_reforecast_k   REAL NOT NULL DEFAULT 0,
    action_summary       TEXT
);

-- ---------------------------------------------------------------------
-- Verification audit trail. Every organization checked against the
-- current-year filing, with the verdict recorded so the position is
-- defensible after the cycle closes.
-- ---------------------------------------------------------------------
CREATE TABLE verification_log (
    verification_id INTEGER PRIMARY KEY,
    org_id          INTEGER NOT NULL REFERENCES organizations(org_id),
    checked_date    TEXT NOT NULL,
    verdict         TEXT NOT NULL CHECK (verdict IN ('CONFIRMED','RESOLVED','EXCEPTION','NOT_CHECKED')),
    evidence_tier   TEXT NOT NULL CHECK (evidence_tier IN ('FACT','DERIVED','ESTIMATE')),
    finding         TEXT
);

CREATE INDEX idx_org_parent      ON organizations(parent_org_id);
CREATE INDEX idx_org_registry    ON organizations(registry_no);
CREATE INDEX idx_assign_org      ON org_assignment(org_id);
CREATE INDEX idx_assign_st       ON org_assignment(st_id);
CREATE INDEX idx_action_case     ON case_actions(case_ref);
CREATE INDEX idx_verif_org       ON verification_log(org_id);

-- PostgreSQL notes:
--   INTEGER PRIMARY KEY  -> GENERATED ALWAYS AS IDENTITY
--   TEXT dates           -> DATE
--   REAL                 -> NUMERIC(12,2), which is what money should use
