#!/usr/bin/env python3
"""Start/stop only positively identified workspace-local synthetic instances."""
import argparse
import configparser
import json
import os
from pathlib import Path
import re
import socket
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["start", "stop"])
parser.add_argument("--confirm-synthetic", action="store_true", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
registry = root / ".local/state/test-targets.json"
if registry.is_symlink() or registry.stat().st_uid != os.getuid() or registry.stat().st_mode & 0o077:
    raise SystemExit("REFUSED: registry must be private and locally owned")
targets = json.loads(registry.read_text())
env = {key: value for key, value in os.environ.items() if not key.startswith(("PG", "MYSQL"))}
# Inherit caller-installed native library path.
mysqlroot = Path(os.environ["RAILPRESS_MYSQL_HOME"]).resolve()
pgbin = Path(os.environ["RAILPRESS_PG_BIN"]).resolve()
def run(command, **options):
    return subprocess.run([str(part) for part in command], env=env, text=True, check=True, **options)
for engine, target in targets.items():
    suffix, port = {"postgresql": ("pg", 55436), "mysql2": ("mysql", 55404)}[engine]
    run_id = target.get("run_id", "m01")
    if not re.fullmatch(r"m01|ci_[a-f0-9]{12}", run_id):
        raise SystemExit("REFUSED: invalid run ID")
    role = f"railpress_{run_id}_{suffix}"
    data = Path(target["data_directory"]).resolve()
    if (not data.is_relative_to(root / ".local/state") or data.stat().st_uid != os.getuid()
            or target["database"] != role + "_test" or target["username"] != role
            or target["host"] != "127.0.0.1" or target["port"] != port):
        raise SystemExit("REFUSED: unexpected synthetic identity/path")
    if engine == "postgresql":
        output = run([pgbin / "pg_controldata", data], capture_output=True).stdout
        actual_id = re.search(r"Database system identifier:\s+(\d+)", output).group(1)
        if actual_id != target["instance_id"]:
            raise SystemExit("REFUSED: wrong PG data directory")
        status = subprocess.run([pgbin / "pg_ctl", "-D", str(data), "status"], env=env, capture_output=True)
        if args.action == "start":
            if status.returncode:
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", port))
                run([pgbin / "pg_ctl", "-D", data, "-l", data.parent / "server.log", "-w", "start"])
            connection = [pgbin / "psql", "-X", "-h", data.parent / "socket", "-p", port, "-U", target.get("operator_username", "railpress_m01_operator"), "-d", "postgres", "-Atc", "SELECT system_identifier FROM pg_control_system()"]
            if run(connection, capture_output=True).stdout.strip() != target["instance_id"]:
                raise SystemExit("REFUSED: running PG instance mismatch")
        elif status.returncode == 0:
            connection = [pgbin / "psql", "-X", "-h", data.parent / "socket", "-p", port, "-U", target.get("operator_username", "railpress_m01_operator"), "-d", "postgres", "-Atc", "SELECT system_identifier FROM pg_control_system()"]
            if run(connection, capture_output=True).stdout.strip() != target["instance_id"]:
                raise SystemExit("REFUSED: running PG instance mismatch")
            run([pgbin / "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"])
    else:
        auto = configparser.ConfigParser()
        auto.read(data / "auto.cnf")
        if auto["auto"]["server-uuid"] != target["instance_id"]:
            raise SystemExit("REFUSED: wrong MySQL data directory")
        cnf = data.parent / "operator.cnf"
        client = [mysqlroot / "bin/mysql", f"--defaults-file={cnf}", "--no-login-paths", "--batch", "--skip-column-names", "-e", "SELECT @@server_uuid"]
        status = subprocess.run([str(x) for x in client], env=env, capture_output=True, text=True)
        if args.action == "start" and status.returncode:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", port))
            run([mysqlroot / "bin/mysqld", "--no-defaults", f"--basedir={mysqlroot}", f"--datadir={data}", f"--socket={data.parent / 'mysql.sock'}", f"--pid-file={data.parent / 'mysqld.pid'}", f"--log-error={data.parent / 'server.log'}", "--mysqlx=OFF", "--local-infile=OFF", "--secure-file-priv=NULL", "--innodb-buffer-pool-size=128M", "--mysql-native-password=OFF", f"--port={port}", "--bind-address=127.0.0.1", "--skip-name-resolve", "--daemonize"])
            status = subprocess.run([str(x) for x in client], env=env, capture_output=True, text=True)
        if status.returncode == 0:
            if status.stdout.strip() != target["instance_id"]:
                raise SystemExit("REFUSED: running MySQL instance mismatch")
            if args.action == "stop":
                run([mysqlroot / "bin/mysqladmin", f"--defaults-file={cnf}", "--no-login-paths", "shutdown"])
        elif args.action == "start":
            raise SystemExit("MySQL did not start; inspect the local server log")
    print(f"{engine}: {args.action}; verified private instance {target['instance_id']}; credentials redacted")
