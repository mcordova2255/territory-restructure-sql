"""
Build the synthetic territory restructure dataset.

Generates a corporate book mid-restructure: organizations under sales
territories, master data cases that change them, and a TAM ledger that
reconciles opening to closing.

Every name, number and figure is invented. The structure and the failure
modes are modelled on how enterprise coverage data actually breaks.

Usage:  python build_dataset.py
Output: data/*.csv and coverage.db
"""

import csv
import os
import random
import sqlite3
from datetime import date, timedelta

random.seed(20260823)  # deterministic: same dataset every run

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "data")
DB = os.path.join(ROOT, "coverage.db")
os.makedirs(DATA, exist_ok=True)


def find_schema():
    """Schema may sit in sql/ or beside this script, depending on how the
    repository was laid out. Look in both rather than assume."""
    for candidate in (os.path.join(ROOT, "sql", "01_schema.sql"),
                      os.path.join(ROOT, "01_schema.sql")):
        if os.path.exists(candidate):
            return candidate
    raise FileNotFoundError("01_schema.sql not found in sql/ or repository root")

# ----------------------------------------------------------------------
# Invented naming. Deliberately generic so nothing resembles a real group.
# ----------------------------------------------------------------------
STEMS = [
    "Ardmore", "Blackwater", "Carrowmore", "Deepwell", "Eastvale", "Fernbank",
    "Glenmara", "Harrowfield", "Inisfree", "Kilbrannan", "Lambourne", "Marlstone",
    "Northgate", "Orrell", "Pentland", "Quarryhill", "Redbourne", "Stonebridge",
    "Tullamore", "Ulverston", "Vantry", "Westmeath", "Yarrowdale", "Ballyvaughan",
    "Cranbourne", "Drumcondra", "Elmswood", "Fairholt", "Garrowby", "Hollybrook",
]
SUFFIX_GB = ["Limited", "PLC", "Holdings Limited", "Group Limited", "(UK) Limited"]
SUFFIX_IE = ["Limited", "DAC", "Unlimited Company", "Group PLC", "Ireland Limited"]
DIVISIONS = ["Capital", "Services", "Technology", "Logistics", "Financial", "Energy",
             "Healthcare", "Industrial", "Retail", "Insurance", "Advisory", "Partners"]

used_names = set()


def make_name(country):
    while True:
        n = f"{random.choice(STEMS)} {random.choice(DIVISIONS)} " \
            f"{random.choice(SUFFIX_GB if country == 'GB' else SUFFIX_IE)}"
        if n not in used_names:
            used_names.add(n)
            return n


def registry_no(country):
    return (f"{random.randint(1000000, 9999999):07d}" if country == "GB"
            else f"{random.randint(100000, 799999):06d}")


# ----------------------------------------------------------------------
# 1. Territories. Opening book of 70 named plus one volume segment.
#    11 named territories close during the cycle, leaving 59.
# ----------------------------------------------------------------------
N_NAMED_OPEN = 70
N_RETIRED = 11
VOLUME_TERRITORY_ID = 900001

territories = []
for i in range(N_NAMED_OPEN):
    country = "IE" if i % 5 < 2 else "GB"
    territories.append({
        "territory_id": 230000 + i * 37,
        "territory_name": f"{make_name(country).rsplit(' ', 1)[0].upper()} - {country}",
        "country_code": country,
        "segment": "NAMED",
        "status": "ACTIVE",
        "opened_cycle": "2H25",
        "retired_cycle": None,
    })
territories.append({
    "territory_id": VOLUME_TERRITORY_ID, "territory_name": "VOLUME SEGMENT GENERIC - UKI",
    "country_code": "GB", "segment": "VOLUME", "status": "ACTIVE",
    "opened_cycle": "2H25", "retired_cycle": None,
})

retired_ids = [t["territory_id"] for t in random.sample(territories[:N_NAMED_OPEN], N_RETIRED)]
for t in territories:
    if t["territory_id"] in retired_ids:
        t["status"] = "RETIRED"
        t["retired_cycle"] = "1H27"

named_active = [t for t in territories if t["segment"] == "NAMED" and t["status"] == "ACTIVE"]

# ----------------------------------------------------------------------
# 2. Organizations. ~320 rows under those territories, with the defects
#    that actually turn up in a book nobody has re-tested:
#    dissolved entities still active, duplicates, orphans, mis-parents,
#    stale names, and country-of-registration errors.
# ----------------------------------------------------------------------
orgs = []
assignments = []
org_id_seq = 700100000
assign_seq = 1

DEFECT_PLAN = {
    "DISSOLVED_STILL_ASSIGNED": 26,
    "DUPLICATE": 22,
    "ORPHAN": 14,
    "STALE_NAME": 24,
    "COUNTRY_MISMATCH": 9,
    "WRONG_PARENT": 18,
}
TOTAL_ORGS = 320

parents_by_st = {}
for t in named_active:
    org_id_seq += random.randint(11, 97)
    country = t["country_code"]
    nm = make_name(country)
    orgs.append({
        "org_id": org_id_seq, "org_name": nm, "legal_name": nm,
        "registry_no": registry_no(country), "reg_country": country,
        "parent_org_id": None, "ultimate_parent_hint": nm,
        "employees": random.randint(250, 9000), "entity_status": "ACTIVE",
        "is_duplicate_of": None, "created_cycle": "2H25",
    })
    parents_by_st[t["territory_id"]] = org_id_seq
    assignments.append({"assignment_id": assign_seq, "org_id": org_id_seq,
                        "territory_id": t["territory_id"], "valid_from": "2025-11-01", "valid_to": None})
    assign_seq += 1

while len(orgs) < TOTAL_ORGS:
    t = random.choice(named_active)
    org_id_seq += random.randint(11, 97)
    country = t["country_code"]
    nm = make_name(country)
    orgs.append({
        "org_id": org_id_seq, "org_name": nm, "legal_name": nm,
        "registry_no": registry_no(country), "reg_country": country,
        "parent_org_id": parents_by_st[t["territory_id"]],
        "ultimate_parent_hint": None,
        "employees": random.randint(5, 2500), "entity_status": "ACTIVE",
        "is_duplicate_of": None, "created_cycle": "2H25",
    })
    assignments.append({"assignment_id": assign_seq, "org_id": org_id_seq,
                        "territory_id": t["territory_id"], "valid_from": "2025-11-01", "valid_to": None})
    assign_seq += 1

children = [o for o in orgs if o["parent_org_id"] is not None]
pool = random.sample(children, sum(DEFECT_PLAN.values()))
cursor = 0


def take(n):
    global cursor
    chunk = pool[cursor:cursor + n]
    cursor += n
    return chunk


for o in take(DEFECT_PLAN["DISSOLVED_STILL_ASSIGNED"]):
    o["entity_status"] = random.choice(["DISSOLVED", "LIQUIDATION"])

for o in take(DEFECT_PLAN["DUPLICATE"]):
    org_id_seq += random.randint(11, 97)
    dupe = dict(o)
    dupe["org_id"] = org_id_seq
    dupe["org_name"] = o["org_name"].replace("Limited", "Ltd").replace("PLC", "Plc")
    dupe["is_duplicate_of"] = o["org_id"]
    dupe["employees"] = None
    orgs.append(dupe)
    tid = next(a["territory_id"] for a in assignments if a["org_id"] == o["org_id"])
    assignments.append({"assignment_id": assign_seq, "org_id": dupe["org_id"],
                        "territory_id": tid, "valid_from": "2025-11-01", "valid_to": None})
    assign_seq += 1

for o in take(DEFECT_PLAN["ORPHAN"]):
    for a in assignments:
        if a["org_id"] == o["org_id"]:
            a["valid_to"] = "2026-02-01"   # closed with no successor row

for o in take(DEFECT_PLAN["STALE_NAME"]):
    o["legal_name"] = o["org_name"].replace(
        o["org_name"].split(" ")[1], random.choice(DIVISIONS))

for o in take(DEFECT_PLAN["COUNTRY_MISMATCH"]):
    tid = next(a["territory_id"] for a in assignments if a["org_id"] == o["org_id"])
    territory_country = next(t["country_code"] for t in territories if t["territory_id"] == tid)
    o["reg_country"] = "GB" if territory_country == "IE" else "IE"

for o in take(DEFECT_PLAN["WRONG_PARENT"]):
    other = random.choice([p for p in parents_by_st.values() if p != o["parent_org_id"]])
    o["parent_org_id"] = other   # parent no longer matches the assigned territory

# ----------------------------------------------------------------------
# 3. Cases. 141 cases carrying 202 actions, mirroring a real cycle where
#    one approval often covers several changes.
# ----------------------------------------------------------------------
STATUSES = [
    ("Implemented",         5, 1, 1),
    ("Submitted",           4, 0, 1),
    ("BA Approved",         3, 0, 1),
    ("Pending BA Approval", 2, 0, 1),
    ("Open",                1, 0, 1),
    ("Withdrawn",           6, 1, 0),
    ("No Change",           0, 1, 0),
]
STATUS_WEIGHTS = [0.52, 0.14, 0.11, 0.08, 0.09, 0.03, 0.03]

ORG_ACTIONS = ["MOVE_ORGANIZATION", "MERGE_ORGANIZATION", "DEACTIVATE_ORGANIZATION",
               "CREATE_ORGANIZATION", "RENAME_ORGANIZATION"]
ORG_WEIGHTS = [0.24, 0.25, 0.17, 0.19, 0.15]
ST_ACTIONS = ["RENAME_TERRITORY", "MERGE_TERRITORY", "CREATE_TERRITORY", "RECLASSIFY_TERRITORY"]
ST_WEIGHTS = [0.44, 0.44, 0.06, 0.06]

N_CASES = 141
cases, actions = [], []
action_seq = 1
start = date(2026, 2, 2)

for i in range(N_CASES):
    level = "ORGANIZATION" if i < 106 else "TERRITORY"
    status = random.choices([s[0] for s in STATUSES], STATUS_WEIGHTS)[0]
    raised = start + timedelta(days=random.randint(0, 180))
    approved = raised + timedelta(days=random.randint(2, 25)) \
        if status in ("BA Approved", "Submitted", "Implemented") else None
    implemented = (approved + timedelta(days=random.randint(1, 30))
                   if status == "Implemented" and approved else None)
    ref = f"CAS-{random.randint(10500000, 11199999)}-{random.choice('ABCDEFGHJKLMNPQRSTUVWXYZ')}{random.randint(0,9)}{random.choice('ABCDEFGHJKLMNPQRSTUVWXYZ')}{random.randint(0,9)}"
    cases.append({
        "case_ref": ref, "case_level": level, "status": status,
        "raised_date": raised.isoformat(),
        "approved_date": approved.isoformat() if approved else None,
        "implemented_date": implemented.isoformat() if implemented else None,
        "target_cycle": "1H27",
    })
    for _ in range(random.choices([1, 2, 3], [0.66, 0.26, 0.08])[0]):
        if level == "ORGANIZATION":
            at = random.choices(ORG_ACTIONS, ORG_WEIGHTS)[0]
            actions.append({"action_id": action_seq, "case_ref": ref, "action_type": at,
                            "org_id": random.choice(orgs)["org_id"], "territory_id": None,
                            "tam_delta_k": 0.0})
        else:
            at = random.choices(ST_ACTIONS, ST_WEIGHTS)[0]
            actions.append({"action_id": action_seq, "case_ref": ref, "action_type": at,
                            "org_id": None, "territory_id": random.choice(named_active)["territory_id"],
                            "tam_delta_k": 0.0})
        action_seq += 1

# ----------------------------------------------------------------------
# 4. TAM ledger. Opening book set to an invented control total. Case-driven
#    movement is assigned to the territories that were merged out, and the
#    remainder is scaled to a fixed reforecast figure so the cycle ties.
# ----------------------------------------------------------------------
OPENING_TOTAL = 18450.0
MERGED_OUT_TOTAL = -92.5

weights = [random.random() ** 1.7 + 0.02 for _ in named_active]
scale = OPENING_TOTAL / sum(weights)
tam = []
for t, w in zip(named_active, weights):
    tam.append({"territory_id": t["territory_id"], "tam_before_k": round(w * scale, 1),
                "tam_after_k": 0.0, "delta_from_cases_k": 0.0,
                "delta_reforecast_k": 0.0, "action_summary": "KEEP"})

# per-row rounding leaves a few hundred pounds of drift against the control
# total; absorb it into the largest territory so the opening balance ties exactly
drift = round(OPENING_TOTAL - sum(r["tam_before_k"] for r in tam), 1)
max(tam, key=lambda r: r["tam_before_k"])["tam_before_k"] += drift

# distribute the merged-out movement across four territories
merge_targets = random.sample(tam, 4)
remaining = MERGED_OUT_TOTAL
for idx, row in enumerate(merge_targets):
    share = round(remaining if idx == len(merge_targets) - 1
                  else remaining * random.uniform(0.15, 0.45), 1)
    row["delta_from_cases_k"] = share
    row["action_summary"] = "MERGE-VOLUME"
    remaining = round(remaining - share, 1)

# reforecast movement: the refresh moves value in both directions
for row in tam:
    if row["action_summary"] == "KEEP" and random.random() < 0.55:
        row["delta_reforecast_k"] = round(
            row["tam_before_k"] * random.uniform(-0.35, 0.9), 1)
        if abs(row["delta_reforecast_k"]) > 0.05:
            row["action_summary"] = "REFORECAST"

# scale the reforecast movement so the cycle nets to the control figure,
# absorbing the rounding remainder in the largest contributing row
REFORECAST_TOTAL = 2140.3
current = sum(r["delta_reforecast_k"] for r in tam)
if abs(current) > 0.01:
    factor = REFORECAST_TOTAL / current
    for row in tam:
        row["delta_reforecast_k"] = round(row["delta_reforecast_k"] * factor, 1)
drift = round(REFORECAST_TOTAL - sum(r["delta_reforecast_k"] for r in tam), 1)
if abs(drift) > 0.001:
    max(tam, key=lambda r: abs(r["delta_reforecast_k"]))["delta_reforecast_k"] += drift

for row in tam:
    row["tam_after_k"] = round(
        row["tam_before_k"] + row["delta_from_cases_k"] + row["delta_reforecast_k"], 1)

# ----------------------------------------------------------------------
# 5. Verification log. Every organization checked against the filing.
# ----------------------------------------------------------------------
verif = []
for i, o in enumerate(orgs, start=1):
    if o["entity_status"] != "ACTIVE":
        verdict, tier, finding = "EXCEPTION", "FACT", "Entity dissolved or in liquidation at the register"
    elif o["is_duplicate_of"]:
        verdict, tier, finding = "EXCEPTION", "FACT", "Duplicate of an existing record on the same registry number"
    elif o["legal_name"] != o["org_name"]:
        verdict, tier, finding = "RESOLVED", "FACT", "Recorded name did not match the filed legal name"
    elif o["employees"] is None:
        verdict, tier, finding = "CONFIRMED", "ESTIMATE", "No headcount filed; group-level estimate applied"
    elif random.random() < 0.06:
        verdict, tier, finding = "NOT_CHECKED", "ESTIMATE", "Outside current verification scope"
    else:
        verdict, tier, finding = "CONFIRMED", "FACT", "Active, correctly named and aligned per current filing"
    verif.append({"verification_id": i, "org_id": o["org_id"],
                  "checked_date": "2026-08-10", "verdict": verdict,
                  "evidence_tier": tier, "finding": finding})

# ----------------------------------------------------------------------
# Write CSVs and load SQLite
# ----------------------------------------------------------------------
def write(name, rows):
    path = os.path.join(DATA, name)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return len(rows)


status_rows = [{"status": s, "stage_order": o, "is_terminal": t, "counts_as_raised": r}
               for s, o, t, r in STATUSES]

counts = {
    "ref_case_status.csv": write("ref_case_status.csv", status_rows),
    "sales_territories.csv": write("sales_territories.csv", territories),
    "organizations.csv": write("organizations.csv", orgs),
    "org_assignment.csv": write("org_assignment.csv", assignments),
    "master_data_cases.csv": write("master_data_cases.csv", cases),
    "case_actions.csv": write("case_actions.csv", actions),
    "tam_movement.csv": write("tam_movement.csv", tam),
    "verification_log.csv": write("verification_log.csv", verif),
}

if os.path.exists(DB):
    os.remove(DB)
con = sqlite3.connect(DB)
con.executescript(open(find_schema()).read())

TABLES = ["ref_case_status", "sales_territories", "organizations", "org_assignment",
          "master_data_cases", "case_actions", "tam_movement", "verification_log"]
for tbl in TABLES:
    with open(os.path.join(DATA, tbl + ".csv"), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    cols = list(rows[0].keys())
    con.executemany(
        f"INSERT INTO {tbl} ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
        [[(None if r[c] == "" else r[c]) for c in cols] for r in rows])
con.commit()

print("Dataset built.")
for k, v in counts.items():
    print(f"  {k:26} {v:5d} rows")
o = con.execute("SELECT SUM(tam_before_k), SUM(tam_after_k), "
                "SUM(delta_from_cases_k), SUM(delta_reforecast_k) FROM tam_movement").fetchone()
print(f"\n  Opening TAM   {o[0]:>12,.1f}K")
print(f"  Closing TAM   {o[1]:>12,.1f}K")
print(f"  From cases    {o[2]:>12,.1f}K")
print(f"  Reforecast    {o[3]:>12,.1f}K")
print(f"  Variance      {o[0] + o[2] + o[3] - o[1]:>12,.1f}K")
con.close()
