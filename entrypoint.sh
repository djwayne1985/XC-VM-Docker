#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/xc_vm"
VERSION_FILE="${STATE_DIR}/installed_version"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
START_COMMAND="${START_COMMAND:-sleep infinity}"
MYSQL_REMOTE_USER="${MYSQL_REMOTE_USER:-xcvm_admin}"
MYSQL_REMOTE_PASSWORD="${MYSQL_REMOTE_PASSWORD:-ChangeMeNow123!}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-admin@Fladnag2018}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-AdminPass123!}"
PANEL_RESET_ON_START="${PANEL_RESET_ON_START:-true}"

# Keep package operations non-interactive inside Docker.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
export APT_LISTCHANGES_FRONTEND=none

mkdir -p "${STATE_DIR}"

install_systemctl_stub() {
  cat > /usr/local/bin/systemctl << 'EOF'
#!/usr/bin/env bash
echo "[docker] systemctl call skipped: $*"
exit 0
EOF
  chmod +x /usr/local/bin/systemctl
}

configure_mysql_network() {
  local cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"

  if [ -f "${cnf}" ]; then
    if grep -q "^bind-address" "${cnf}"; then
      sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "${cnf}"
    else
      printf "\n[mysqld]\nbind-address = 0.0.0.0\n" >> "${cnf}"
    fi
  fi
}

start_mariadb() {
  if mariadb-admin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
    echo "MariaDB already running"
    return
  fi

  mkdir -p /run/mysqld /var/lib/mysql
  chown -R mysql:mysql /run/mysqld /var/lib/mysql

  if [ ! -d /var/lib/mysql/mysql ]; then
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
  fi

  configure_mysql_network

  # Prefer service startup so XC_VM root cron checks detect MariaDB correctly.
  if command -v service >/dev/null 2>&1; then
    service mariadb start >/dev/null 2>&1 || true
  fi

  if ! mariadb-admin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
    mysqld_safe --skip-networking=0 --socket=/run/mysqld/mysqld.sock >/var/log/mysqld.log 2>&1 &
  fi

  for _ in $(seq 1 60); do
    if mariadb-admin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
      echo "MariaDB is ready"
      return
    fi
    sleep 1
  done

  echo "MariaDB did not become ready in time"
  exit 1
}

setup_remote_mysql_access() {
  local root_password=""
  local safe_user safe_pass
  local -a auth_args

  if [ -f /opt/xc_vm/credentials.txt ]; then
    root_password="$(grep -m1 '^MariaDB Root Password:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  fi

  if [ -n "${root_password}" ]; then
    auth_args=(-uroot -p"${root_password}")
    if ! mariadb --protocol=socket "${auth_args[@]}" -e "SELECT 1" >/dev/null 2>&1; then
      auth_args=(-uroot)
    fi
  else
    auth_args=(-uroot)
  fi

  safe_user="${MYSQL_REMOTE_USER//\'/\'\'}"
  safe_pass="${MYSQL_REMOTE_PASSWORD//\'/\'\'}"

  mariadb --protocol=socket "${auth_args[@]}" <<SQL
CREATE USER IF NOT EXISTS '${safe_user}'@'%' IDENTIFIED BY '${safe_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${safe_user}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  echo "MariaDB remote user '${MYSQL_REMOTE_USER}' is ready"
}

start_cron() {
  if pgrep -x cron >/dev/null 2>&1; then
    echo "cron already running"
    return
  fi

  # Debian/Ubuntu cron daemon. Fallback keeps startup resilient.
  cron || service cron start || true

  if pgrep -x cron >/dev/null 2>&1; then
    echo "cron is running"
  else
    echo "warning: cron did not start"
  fi
}

run_xcvm_status() {
  if [ -x /home/xc_vm/bin/php/bin/php ] && [ -f /home/xc_vm/console.php ]; then
    /home/xc_vm/bin/php/bin/php /home/xc_vm/console.php status || true
  fi
}

sync_access_code_in_db() {
  local db_user db_pass db_name code table_exists code_exists

  if [ ! -f /opt/xc_vm/credentials.txt ]; then
    return
  fi

  db_user="$(grep -m1 '^MariaDB Username:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_pass="$(grep -m1 '^MariaDB Password:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_name="$(grep -m1 '^Database:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  code="$(grep -m1 '^Admin Access Code:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"

  if [ -z "${db_name}" ]; then
    db_name="xc_vm"
  fi

  if [ -z "${db_user}" ] || [ -z "${db_pass}" ] || [ -z "${code}" ]; then
    return
  fi

  table_exists="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" -e "
SELECT COUNT(*)
FROM information_schema.tables
WHERE table_schema='${db_name}'
  AND table_name='access_codes';" 2>/dev/null || echo 0)"

  if [ "${table_exists}" = "0" ]; then
    echo "warning: access_codes table not found; skipping access-code sync"
    return
  fi

  code_exists="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
SELECT COUNT(*)
FROM access_codes
WHERE code='${code}';" 2>/dev/null || echo 0)"

  if [ "${code_exists}" = "0" ]; then
    mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
INSERT INTO access_codes(code, type, enabled, \`groups\`)
VALUES('${code}', 0, 1, '[1]');" || true
    echo "Access code synced to DB: ${code}"
  else
    echo "Access code already present in DB: ${code}"
  fi
}

reset_panel_admin_password() {
  local db_user db_pass db_name target_table has_status has_id has_member_group hash
  local admin_user_esc

  if [ "${PANEL_RESET_ON_START}" != "true" ]; then
    return
  fi

  if [ ! -f /opt/xc_vm/credentials.txt ]; then
    return
  fi

  db_user="$(grep -m1 '^MariaDB Username:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_pass="$(grep -m1 '^MariaDB Password:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_name="$(grep -m1 '^Database:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"

  if [ -z "${db_name}" ]; then
    db_name="xc_vm"
  fi

  if [ -z "${db_user}" ] || [ -z "${db_pass}" ]; then
    return
  fi

  target_table="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" -e "
SELECT c1.table_name
FROM information_schema.columns c1
JOIN information_schema.columns c2
  ON c1.table_schema=c2.table_schema AND c1.table_name=c2.table_name
WHERE c1.table_schema='${db_name}'
  AND c1.column_name='username'
  AND c2.column_name='password'
ORDER BY (c1.table_name='users') DESC, c1.table_name
LIMIT 1;" 2>/dev/null || true)"

  if [ -z "${target_table}" ]; then
    echo "warning: no login table found for panel password reset"
    return
  fi

  hash="$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512, rounds=20000)))" "${PANEL_ADMIN_PASSWORD}")"
  admin_user_esc="${PANEL_ADMIN_USERNAME//\'/\'\'}"
  has_status="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" -e "
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema='${db_name}'
  AND table_name='${target_table}'
  AND column_name='status';" 2>/dev/null || echo 0)"

  has_id="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" -e "
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema='${db_name}'
  AND table_name='${target_table}'
  AND column_name='id';" 2>/dev/null || echo 0)"

  has_member_group="$(mariadb -N -s -u"${db_user}" -p"${db_pass}" -e "
SELECT COUNT(*)
FROM information_schema.columns
WHERE table_schema='${db_name}'
  AND table_name='${target_table}'
  AND column_name='member_group_id';" 2>/dev/null || echo 0)"

  if [ "${has_id}" -gt 0 ] 2>/dev/null; then
    if [ "${has_status}" -gt 0 ] 2>/dev/null && [ "${has_member_group}" -gt 0 ] 2>/dev/null; then
      mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
UPDATE ${target_table}
SET username='${admin_user_esc}', password='${hash}', status=1, member_group_id=1
WHERE id=1
LIMIT 1;" || true
    elif [ "${has_status}" -gt 0 ] 2>/dev/null; then
      mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
UPDATE ${target_table}
SET username='${admin_user_esc}', password='${hash}', status=1
WHERE id=1
LIMIT 1;" || true
    else
      mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
UPDATE ${target_table}
SET username='${admin_user_esc}', password='${hash}'
WHERE id=1
LIMIT 1;" || true
    fi
  elif [ "${has_status}" -gt 0 ] 2>/dev/null; then
    mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
UPDATE ${target_table}
SET password='${hash}', status=1
WHERE username='${admin_user_esc}'
LIMIT 1;" || true
  else
    mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" -e "
UPDATE ${target_table}
SET password='${hash}'
WHERE username='${admin_user_esc}'
LIMIT 1;" || true
  fi

  echo "Panel admin credentials applied from env (user=${PANEL_ADMIN_USERNAME}, table=${target_table})"
}

sync_xcvm_db_user() {
  local root_password db_user db_pass db_name
  local db_user_esc db_pass_esc db_name_esc
  local -a auth_args

  if [ ! -f /opt/xc_vm/credentials.txt ]; then
    return
  fi

  root_password="$(grep -m1 '^MariaDB Root Password:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_user="$(grep -m1 '^MariaDB Username:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_pass="$(grep -m1 '^MariaDB Password:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  db_name="$(grep -m1 '^Database:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"

  if [ -z "${db_user}" ] || [ -z "${db_pass}" ]; then
    return
  fi

  if [ -z "${db_name}" ]; then
    db_name="xc_vm"
  fi

  if [ -n "${root_password}" ]; then
    auth_args=(-uroot -p"${root_password}")
    if ! mariadb --protocol=socket --skip-ssl "${auth_args[@]}" -e "SELECT 1" >/dev/null 2>&1; then
      auth_args=(-uroot)
    fi
  else
    auth_args=(-uroot)
  fi

  db_user_esc="${db_user//\'/\'\'}"
  db_pass_esc="${db_pass//\'/\'\'}"
  db_name_esc="${db_name//\`/}"

  mariadb --protocol=socket --skip-ssl "${auth_args[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name_esc}\`;
CREATE USER IF NOT EXISTS '${db_user_esc}'@'localhost' IDENTIFIED BY '${db_pass_esc}';
CREATE USER IF NOT EXISTS '${db_user_esc}'@'127.0.0.1' IDENTIFIED BY '${db_pass_esc}';
CREATE USER IF NOT EXISTS '${db_user_esc}'@'%' IDENTIFIED BY '${db_pass_esc}';
ALTER USER '${db_user_esc}'@'localhost' IDENTIFIED BY '${db_pass_esc}' REQUIRE NONE;
ALTER USER '${db_user_esc}'@'127.0.0.1' IDENTIFIED BY '${db_pass_esc}' REQUIRE NONE;
ALTER USER '${db_user_esc}'@'%' IDENTIFIED BY '${db_pass_esc}' REQUIRE NONE;
GRANT ALL PRIVILEGES ON \`${db_name_esc}\`.* TO '${db_user_esc}'@'localhost';
GRANT ALL PRIVILEGES ON \`${db_name_esc}\`.* TO '${db_user_esc}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${db_name_esc}\`.* TO '${db_user_esc}'@'%';
FLUSH PRIVILEGES;
SQL

  echo "XC_VM database user grants synchronized"
}

start_xcvm_services() {
  if [ ! -f /home/xc_vm/console.php ] || [ ! -x /home/xc_vm/bin/php/bin/php ]; then
    return
  fi

  mkdir -p /home/xc_vm/bin/php/sockets /home/xc_vm/bin/nginx/logs
  chown -R xc_vm:xc_vm /home/xc_vm/bin/php/sockets /home/xc_vm/bin/nginx/logs >/dev/null 2>&1 || true

  if [ -x /home/xc_vm/bin/nginx/sbin/nginx ] && ! pgrep -u xc_vm nginx >/dev/null 2>&1; then
    sudo -u xc_vm /home/xc_vm/bin/nginx/sbin/nginx >/dev/null 2>&1 || true
  fi

  if [ -x /home/xc_vm/bin/nginx_rtmp/sbin/nginx_rtmp ] && ! pgrep -u xc_vm nginx_rtmp >/dev/null 2>&1; then
    sudo -u xc_vm /home/xc_vm/bin/nginx_rtmp/sbin/nginx_rtmp >/dev/null 2>&1 || true
  fi

  if [ -x /home/xc_vm/bin/daemons.sh ]; then
    sudo -u xc_vm /home/xc_vm/bin/daemons.sh >/dev/null 2>&1 || true
  fi

  /home/xc_vm/bin/php/bin/php /home/xc_vm/console.php startup >/dev/null 2>&1 || true
}

print_access_url() {
  local code=""

  if [ -f /opt/xc_vm/credentials.txt ]; then
    code="$(grep -m1 '^Admin Access Code:' /opt/xc_vm/credentials.txt | cut -d ':' -f 2- | xargs || true)"
  fi

  echo "============================================================"
  if [ -n "${code}" ]; then
    echo "XC_VM Panel URL: http://localhost/${code}"
    echo "XC_VM Panel URL (HTTPS): https://localhost/${code}"
  else
    echo "XC_VM panel access code is not available yet."
  fi
  echo "============================================================"
}

current_version=""
if [ -f "${VERSION_FILE}" ]; then
  current_version="$(cat "${VERSION_FILE}" || true)"
fi

latest_version="$(curl -fsSL https://api.github.com/repos/Vateron-Media/XC_VM/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)"

install_systemctl_stub

should_install="false"
if [ ! -f "${VERSION_FILE}" ]; then
  should_install="true"
elif [ "${UPDATE_ON_START}" = "true" ] && [ "${latest_version}" != "${current_version}" ]; then
  should_install="true"
elif [ ! -f /opt/xc_vm/install ]; then
  echo "Install marker exists but XC_VM files are missing; forcing reinstall"
  should_install="true"
fi

if [ "${should_install}" = "true" ]; then
  echo "Installing XC_VM version ${latest_version}"
  cd /opt/xc_vm
  rm -rf /opt/xc_vm/*
  wget -O XC_VM.zip "https://github.com/Vateron-Media/XC_VM/releases/download/${latest_version}/XC_VM.zip"
  unzip -o XC_VM.zip

  # Ensure MySQL is up before running installer steps that call console.php.
  start_mariadb

  # XC_VM installer assumes systemd; disable those calls in Docker.
  sed -i 's/run_command("systemctl daemon-reload")/printc("Skipping systemctl daemon-reload in Docker", col.WARNING)/' install
  sed -i 's/run_command("systemctl start xc_vm")/printc("Skipping systemctl start xc_vm in Docker", col.WARNING)/' install

  # Harden apt commands against interactive dpkg conffile prompts.
  sed -i "s/apt-get -yq install/apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -yq install/g" install
  sed -i "s/apt -yq install/apt -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -yq install/g" install

  # Upstream installer is interactive; answer prompts automatically for container use.
  cat > /tmp/xc_vm_install.exp << 'EOF'
#!/usr/bin/expect -f
set timeout -1
spawn python3 install

expect {
  -re {Continue anyway\? \(Y/N\):} {
    send "Y\r"
    exp_continue
  }
  -re {MariaDB root password \(or press Enter to generate\):} {
    send "\r"
    exp_continue
  }
  -re {Continue with provided password\? \(Y/N\):} {
    send "Y\r"
    exp_continue
  }
  -re {Continue and overwrite\? \(Y / N\) :} {
    send "Y\r"
    exp_continue
  }
  -re {HTTP port \(default 80\):} {
    send "\r"
    exp_continue
  }
  -re {HTTPS port \(default 443\):} {
    send "\r"
    exp_continue
  }
  -re {Overwrite sysctl configuration\? Recommended! \(Y / N\):} {
    send "Y\r"
    exp_continue
  }
  -re {\(Y/I/N/O/D/Z\)} {
    send "\r"
    exp_continue
  }
  -re {Z: start a shell} {
    send "\r"
    exp_continue
  }
  -re {\[Y/n\]} {
    send "Y\r"
    exp_continue
  }
  -re {\[y/N\]} {
    send "N\r"
    exp_continue
  }
  eof
}

catch wait result
set exit_status [lindex $result 3]
exit $exit_status
EOF

  chmod +x /tmp/xc_vm_install.exp
  /tmp/xc_vm_install.exp

  echo "${latest_version}" > "${VERSION_FILE}"
else
  echo "XC_VM already installed at ${current_version}; skipping install"
fi

start_mariadb
setup_remote_mysql_access
sync_xcvm_db_user
reset_panel_admin_password
start_cron
start_xcvm_services
sync_access_code_in_db
run_xcvm_status
sync_access_code_in_db
print_access_url

# Keep container alive (or replace with actual runtime command)
exec bash -lc "${START_COMMAND}"
