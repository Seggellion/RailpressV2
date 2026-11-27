#!/usr/bin/env python3
"""Add disposable W03 names on the positively identified local test servers."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--confirm-synthetic", action="store_true", required=True)
parser.add_argument("--restore-retry", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
state = root / ".local/state"
registry = state / "test-targets.json"
output = state / "w03-test-targets.json"
profiles = {"w03_bridge": "ci_030000000001", "w03_restore": "ci_030000000002", "w03_reference": "ci_030000000003"}
retry = {"w03_restore_retry": "ci_030000000004"}
environment = {key: value for key, value in os.environ.items() if not key.startswith(("PG", "MYSQL"))}
os.umask(0o077)

def refuse(reason):
    raise SystemExit("REFUSED: " + reason)

def run(command, sql=None):
    result = subprocess.run([str(part) for part in command], env=environment, input=sql, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
    if result.returncode:
        refuse("native fixture command failed; SQL and credentials redacted")
    return result.stdout.strip()

def owned(path):
    return not path.is_symlink() and path.stat().st_uid == os.getuid() and path.stat().st_mode & 0o077 == 0

if os.getuid() == 0 or output.is_symlink() or not owned(registry):
    refuse("expected a private W03 registry")
prior = {}
if args.restore_retry:
    if not output.exists() or not owned(output):
        refuse("original W03 registry required")
    prior = json.loads(output.read_text())
    if set(prior) != set(profiles):
        refuse("unexpected W03 registry profiles")
    for profile, run_id in profiles.items():
        if set(prior[profile]) != {"postgresql", "mysql2"} or any(
                row["run_id"] != run_id for row in prior[profile].values()):
            refuse("unexpected original W03 identities")
    profiles = retry
elif output.exists():
    refuse("expected a new private W03 registry")
base = json.loads(registry.read_text())
if set(base) != {"postgresql", "mysql2"}:
    refuse("fixture registry engines differ")
pg = base["postgresql"]
mysql = base["mysql2"]
pg_data = (state / "qualification/postgres16/data").resolve()
my_data = (state / "qualification/mysql84/data").resolve()
for database, data, port, suffix in ((pg, pg_data, 55436, "pg"), (mysql, my_data, 55404, "mysql")):
    if Path(database["data_directory"]).resolve() != data or not owned(data) or database["port"] != port or \
            database["host"] != "127.0.0.1" or database["username"] != f"railpress_m01_{suffix}" or \
            database["database"] != f"railpress_m01_{suffix}_test":
        refuse("unexpected fixture identity")
    for volume in (data, Path("/mnt/c")):
        stats = os.statvfs(volume)
        if stats.f_bavail * stats.f_frsize < 8 * 1024**3 or (volume == data and stats.f_favail < 4096):
            refuse("fixture reserve")

pg_binary = Path(environment["RAILPRESS_PG_BIN"]).resolve()
my_binary = Path(environment["RAILPRESS_MYSQL_HOME"]).resolve() / "bin/mysql"
pg_user = pg.get("operator_username", "railpress_m01_operator")
if not re.fullmatch(r"railpress_[a-z0-9_]+", pg_user):
    refuse("unexpected PostgreSQL local operator")
cnf = my_data.parent / "operator.cnf"
if not owned(cnf):
    refuse("unsafe MySQL local operator file")
pg_admin = [pg_binary / "psql", "-X", "-At", "-h", pg_data.parent / "socket", "-p", "55436",
            "-U", pg_user, "-v", "ON_ERROR_STOP=1"]
my_admin = [my_binary, f"--defaults-file={cnf}", "--no-login-paths", "--batch", "--skip-column-names"]
if run(pg_admin + ["-d", "postgres"], "SELECT system_identifier FROM pg_control_system();") != pg["instance_id"]:
    refuse("PostgreSQL instance mismatch")
if run(my_admin, "SELECT @@server_uuid;") != mysql["instance_id"] or \
        run(my_admin, "SELECT token FROM railpress_m01_guard.identity;") != mysql["marker_token"]:
    refuse("MySQL instance mismatch")

document = {}
for profile, run_id in profiles.items():
    entry = {}
    for engine, previous, suffix in (("postgresql", pg, "pg"), ("mysql2", mysql, "mysql")):
        role = f"railpress_{run_id}_{suffix}"
        database = f"{role}_test"
        if engine == "postgresql":
            found = run(pg_admin + ["-d", "postgres"], f"SELECT 1 FROM pg_roles WHERE rolname='{role}' UNION ALL SELECT 1 FROM pg_database WHERE datname='{database}';")
        else:
            found = run(my_admin, f"SELECT 1 FROM mysql.user WHERE User='{role}' UNION ALL SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='{database}';")
        if found:
            refuse(f"{profile} {engine} already exists")
        entry[engine] = previous | dict(run_id=run_id, username=role, database=database, password=secrets.token_hex(24))
    document[profile] = entry

for profile, entry in document.items():
    target = entry["postgresql"]
    target["marker_token"] = secrets.token_hex(24)
    role, database, password, marker = (target[key] for key in ("username", "database", "password", "marker_token"))
    run(pg_admin + ["-d", "postgres"],
        f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '{password}';\nCREATE DATABASE {database} OWNER {role};\n")
    run(pg_admin + ["-d", database],
        f"REVOKE CREATE ON SCHEMA public FROM PUBLIC;\nCREATE SCHEMA railpress_test_guard AUTHORIZATION {pg_user};\n"
        f"CREATE TABLE railpress_test_guard.identity(token text NOT NULL);\nINSERT INTO railpress_test_guard.identity VALUES ('{marker}');\n"
        f"GRANT USAGE ON SCHEMA railpress_test_guard TO {role};\nGRANT SELECT ON railpress_test_guard.identity TO {role};\n"
        f"GRANT EXECUTE ON FUNCTION pg_control_system() TO {role};\n")
    role, database, password = (entry["mysql2"][key] for key in ("username", "database", "password"))
    run(my_admin, f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin;\n"
        f"CREATE USER '{role}'@'127.0.0.1' IDENTIFIED BY '{password}';\nGRANT ALL PRIVILEGES ON {database}.* TO '{role}'@'127.0.0.1';\n"
        f"GRANT SELECT ON railpress_m01_guard.identity TO '{role}'@'127.0.0.1';\n")
    print(f"{profile}: separate synthetic PostgreSQL and MySQL roles and databases created")
temporary = output.with_suffix(".retry-pending.json") if args.restore_retry else output
with temporary.open("x") as file:
    json.dump(prior | document, file)
    file.flush()
    os.fsync(file.fileno())
if args.restore_retry:
    temporary.replace(output)
