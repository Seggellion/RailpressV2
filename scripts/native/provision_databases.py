from pathlib import Path
import atexit
import os,json,secrets,socket,subprocess
import argparse
import select
import signal
parser=argparse.ArgumentParser(description="Provision fresh dedicated local synthetic engines only")
parser.add_argument("--confirm-synthetic",action="store_true",required=True)
parser.add_argument("--qualification",action="store_true",help="Use separate fixed55636/55604 ports and qualification identities; never replace an existing instance")
args=parser.parse_args()
pgport,myport=(55636,55604) if args.qualification else (55436,55404)
profiles=[("default","ci_a17000000001"),("qualification_probe","ci_a17000000002"),("site_qualification","ci_a17000000003")] if args.qualification else [("default","m01"),("m15_source","ci_15a0ce000001"),("m15_target","ci_15a0ce000002"),("native_probe","ci_000000000001")]
root=Path(__file__).resolve().parents[2];os.chdir(root)
state=root/'.local/state/qualification';out=root/'.local/logs/provision'
registry=root/'.local/state/test-targets.json'
pgbin=Path(os.environ['RAILPRESS_PG_BIN']).resolve()
mysql=Path(os.environ['RAILPRESS_MYSQL_HOME']).resolve()
assert os.getuid()!=0 and not registry.exists() and (pgbin/'initdb').is_file()
assert not (state/'postgres16').exists() and not (state/'mysql84').exists()
if state.resolve()!=state or out.resolve()!=out:
 raise SystemExit('REFUSED: fixture and log paths must stay within the checkout')
assert '16.16' in subprocess.check_output([pgbin/'postgres','--version'],text=True)
assert '8.4.13' in subprocess.check_output([mysql/'bin/mysqld','--version'],text=True)
for volume in (root, Path('/mnt/c')):
 if volume.exists():
  st=os.statvfs(volume)
  if st.f_bavail*st.f_frsize<8*1024**3:raise SystemExit('REFUSED: provision capacity below 8 GiB')
for port in [pgport,myport]:
 with socket.socket() as connection:connection.bind(('127.0.0.1',port))
os.umask(0o077)
out.mkdir(parents=True,exist_ok=False)

pgdata=state/'postgres16/data'
mydata=state/'mysql84/data'
provisioned=False
def rollback_partial_start():
 if provisioned:return
 for data,pidfile,executable,shutdown in [
   (mydata,mydata.parent/'mysqld.pid',mysql/'bin/mysqld',signal.SIGTERM),
   (pgdata,pgdata/'postmaster.pid',pgbin/'postgres',signal.SIGINT)]:
  try:
   if not pidfile.is_file() or pidfile.is_symlink() or pidfile.stat().st_uid!=os.getuid():continue
   pid=int(pidfile.read_text().splitlines()[0])
   if pid<=1:continue
   with_pid=os.pidfd_open(pid)
   try:
    process=Path('/proc')/str(pid)
    if process.stat().st_uid!=os.getuid() or (process/'exe').resolve()!=executable.resolve():continue
    arguments=(process/'cmdline').read_bytes().split(b'\0')
    if os.fsencode(data) not in arguments and b'--datadir='+os.fsencode(data) not in arguments:continue
    signal.pidfd_send_signal(with_pid,shutdown)
    observer=select.poll();observer.register(with_pid,select.POLLIN)
    if not observer.poll(30000):print('Synthetic daemon shutdown pending after provisioning failure')
   finally:os.close(with_pid)
  except (FileNotFoundError,ProcessLookupError):
   continue
  except (OSError,ValueError,IndexError):
   print('Synthetic daemon cleanup could not verify process ownership')
atexit.register(rollback_partial_start)
operator='railpress_fixture_operator'
configs={};pw={};marker={}
for profile,run_id in profiles:
 configs[profile]={}
 for engine,suffix,port in [('postgresql','pg',pgport),('mysql2','mysql',myport)]:
  if profile.endswith('_probe') and engine=='mysql2':continue
  role=f'railpress_{run_id}_{suffix}';password=secrets.token_hex(24);token=secrets.token_hex(24)
  pw[profile,engine]=password;marker[profile,engine]=token
  configs[profile][engine]={'adapter':engine,'host':'127.0.0.1','port':port,'database':role+'_test','username':role,'password':password,'run_id':run_id,'marker_token':token}
environment={k:v for k,v in os.environ.items() if not k.startswith(('PG','MYSQL'))};# Inherit caller-installed native library search path; never copy runtimes.
def run(args,**kwargs):return subprocess.run([str(a) for a in args],env=environment,check=True,text=True,**kwargs)
pgsocket=state/'postgres16/socket';pgsocket.mkdir(parents=True,mode=0o700);pgsocket.chmod(0o700)
with (out/'postgresql-init.log').open('x') as log:run([pgbin/'initdb','-D',pgdata,'-U',operator,'--auth-local=trust','--auth-host=scram-sha-256','--encoding=UTF8','--locale=C.UTF-8','--data-checksums'],stdout=log,stderr=subprocess.STDOUT)
with (pgdata/'postgresql.conf').open('a') as f:f.write(f"\nlisten_addresses='127.0.0.1'\nport={pgport}\nunix_socket_directories='{pgsocket}'\nunix_socket_permissions=0700\nshared_buffers=128MB\n")
run([pgbin/'pg_ctl','-D',pgdata,'-l',state/'postgres16/server.log','-w','start'],stdout=subprocess.DEVNULL)
psql=[pgbin/'psql','-X','-h',pgsocket,'-p',str(pgport),'-U',operator,'-v','ON_ERROR_STOP=1']
for profile in configs:
 target=configs[profile]['postgresql'];role=target['username'];db=target['database']
 run(psql+['-d','postgres'],input=f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '{target['password']}';\nCREATE DATABASE {db} OWNER {role};\n",stdout=subprocess.DEVNULL)
 run(psql+['-d',db],input=f"REVOKE CREATE ON SCHEMA public FROM PUBLIC;\nCREATE SCHEMA railpress_test_guard AUTHORIZATION {operator};\nCREATE TABLE railpress_test_guard.identity(token text NOT NULL);\nINSERT INTO railpress_test_guard.identity VALUES ('{target['marker_token']}');\nGRANT USAGE ON SCHEMA railpress_test_guard TO {role};\nGRANT SELECT ON railpress_test_guard.identity TO {role};\nGRANT EXECUTE ON FUNCTION pg_control_system() TO {role};\n",stdout=subprocess.DEVNULL)
 target['instance_id']=run(psql+['-d',db,'-Atc','SELECT system_identifier FROM pg_control_system()'],capture_output=True).stdout.strip();target['data_directory']=str(pgdata);target['operator_username']=operator
mysocket=state/'mysql84/mysql.sock';mydata.mkdir(parents=True,mode=0o700)
with (out/'mysql-initialize.log').open('x') as log:run([mysql/'bin/mysqld','--no-defaults','--initialize-insecure',f'--basedir={mysql}',f'--datadir={mydata}',f'--log-error={state/"mysql84/initialize.log"}'],stdout=log,stderr=subprocess.STDOUT)
base=[mysql/'bin/mysqld','--no-defaults',f'--basedir={mysql}',f'--datadir={mydata}',f'--socket={mysocket}',f'--pid-file={state/"mysql84/mysqld.pid"}',f'--log-error={state/"mysql84/server.log"}','--mysqlx=OFF','--local-infile=OFF','--secure-file-priv=NULL','--innodb-buffer-pool-size=128M','--mysql-native-password=OFF']
run(base+['--skip-networking','--daemonize'],stdout=subprocess.DEVNULL)
client=[mysql/'bin/mysql','--no-defaults','--no-login-paths','--protocol=SOCKET',f'--socket={mysocket}','--user=root','--batch','--skip-column-names']
root_password=secrets.token_hex(24);mysql_marker=secrets.token_hex(24)
statements=[f"ALTER USER 'root'@'localhost' IDENTIFIED BY '{root_password}';",'CREATE DATABASE railpress_m01_guard;','CREATE TABLE railpress_m01_guard.identity(token varchar(48) NOT NULL);',f"INSERT INTO railpress_m01_guard.identity VALUES ('{mysql_marker}');"]
for profile in configs:
 if 'mysql2' not in configs[profile]:continue
 target=configs[profile]['mysql2'];role=target['username'];db=target['database'];target['marker_token']=mysql_marker;target['data_directory']=str(mydata)
 statements += [f'CREATE DATABASE {db} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin;',f"CREATE USER '{role}'@'127.0.0.1' IDENTIFIED BY '{target['password']}';",f"GRANT ALL PRIVILEGES ON {db}.* TO '{role}'@'127.0.0.1';",f"GRANT SELECT ON railpress_m01_guard.identity TO '{role}'@'127.0.0.1';"]
run(client,input='\n'.join(statements)+'\n',stdout=subprocess.DEVNULL)
cnf=state/'mysql84/operator.cnf'
with os.fdopen(os.open(cnf,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:f.write(f'[client]\nuser=root\npassword={root_password}\nsocket={mysocket}\nprotocol=SOCKET\n')
admin=[mysql/'bin/mysql',f'--defaults-file={cnf}','--no-login-paths','--batch','--skip-column-names']
instance=run(admin+['-e','SELECT @@server_uuid'],capture_output=True).stdout.strip()
for profile in configs:
 if 'mysql2' in configs[profile]:configs[profile]['mysql2']['instance_id']=instance
run([mysql/'bin/mysqladmin',f'--defaults-file={cnf}','--no-login-paths','shutdown'],stdout=subprocess.DEVNULL)
run(base+[f'--port={myport}','--bind-address=127.0.0.1','--skip-name-resolve','--daemonize'],stdout=subprocess.DEVNULL)
with os.fdopen(os.open(registry,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:json.dump(configs['default'],f,indent=2);f.write('\n')
with os.fdopen(os.open(root/'.local/state/m15-test-targets.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:json.dump({k:v for k,v in configs.items() if k.startswith('m15_')},f,indent=2);f.write('\n')
public={profile:{engine:{k:v for k,v in target.items() if k not in ['password','marker_token']} for engine,target in targets.items()} for profile,targets in configs.items()}
with (out/'IDENTITIES.json').open('x') as f:json.dump({'profiles':public,'old_instances_replaced':False,'system_service_changes':False},f,indent=2);f.write('\n')
with os.fdopen(os.open(root/'.local/state/probe-test-targets.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:json.dump({k:v for k,v in configs.items() if k.endswith('_probe')},f,indent=2)
if args.qualification:
 with os.fdopen(os.open(root/'.local/state/site-test-targets.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:json.dump({k:v for k,v in configs.items() if k=='site_qualification'},f,indent=2)
provisioned=True
print(json.dumps(public,indent=2))
