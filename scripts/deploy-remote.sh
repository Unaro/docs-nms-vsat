#!/usr/bin/env bash
# Run from the operator host. Never source the supplied cluster environment locally.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() {
  cat <<'EOF'
Использование:
  ./deploy-remote.sh copy --node1 user@host1 --node2 user@host2 --env ./ha-cluster
  ./deploy-remote.sh ACTION --node1 user@host1 --node2 user@host2

ACTION:
  copy          Скопировать scripts/ и конфигурацию на оба узла
  master        setup-node.sh --master на node1
  standby       setup-node.sh --standby на node2
  stop-master   setup-node.sh --stop-master на node1
  configure     configure-ha.sh без инициализации на обоих узлах
  init          configure-ha.sh --init-pcs на node1 (требует --confirm-init)

Параметры:
  --env FILE        Готовый /etc/default/ha-cluster (обязателен для copy)
  --identity FILE   SSH-ключ (необязательно)
  --port NUMBER     SSH-порт (по умолчанию 22)
  --confirm-init    Явное разрешение первоначальной инициализации кластера

Назначение файлов: /opt/ha-cluster/scripts; конфигурация: /etc/default/ha-cluster.
Требуются SSH-ключ/ssh-agent и root либо sudo -n без пароля.
Проверка SSH host key не отключается. Зависимости ОС не устанавливаются.
EOF
}
die() { echo "Ошибка: $*" >&2; exit 1; }
ACTION=${1:-}
[[ $ACTION != --help && $ACTION != -h && -n $ACTION ]] || { usage; exit 0; }
shift
NODE1='' NODE2='' ENV='' IDENTITY='' PORT=22 CONFIRM=false
while (($#)); do
  case $1 in
    --node1|--node2|--env|--identity|--port)
      (($# >= 2)) || die "Нет значения для $1"
      case $1 in
        --node1) NODE1=$2;; --node2) NODE2=$2;; --env) ENV=$2;;
        --identity) IDENTITY=$2;; --port) PORT=$2;;
      esac
      shift 2;;
    --confirm-init) CONFIRM=true; shift;;
    *) die "Неизвестный параметр: $1";;
  esac
done
case $ACTION in copy|master|standby|stop-master|configure|init) ;; *) die "Неизвестное действие: $ACTION";; esac
for host in "$NODE1" "$NODE2"; do
  [[ $host =~ ^([a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'Укажите --node1 и --node2 как user@IPv4/hostname (IPv6: через SSH alias)'
done
[[ $NODE1 != "$NODE2" ]] || die 'Адреса узлов должны отличаться'
[[ $PORT =~ ^[0-9]+$ && ${#PORT} -le 5 ]] || die 'Некорректный SSH-порт'
((10#$PORT > 0 && 10#$PORT <= 65535)) || die 'Некорректный SSH-порт'
[[ $ACTION != init || $CONFIRM == true ]] || die 'Для init требуется --confirm-init'
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$PORT")
[[ -z $IDENTITY ]] || SSH+=(-i "$IDENTITY")
command -v ssh >/dev/null || die 'Не найден ssh'
# Quote every argument: SSH passes its remote command through a shell.
remote() {
  local host=$1 command
  shift
  printf -v command '%q ' "$@"
  "${SSH[@]}" "$host" "$command"
}
# Fail before making changes if either endpoint is unavailable or lacks sudo.
for host in "$NODE1" "$NODE2"; do
  remote "$host" bash -c 'set -e; if [ "$(id -u)" != 0 ]; then sudo -n true; fi; command -v bash >/dev/null; command -v tar >/dev/null'
done
if [[ $ACTION == copy ]]; then
  [[ -f $ENV && -r $ENV ]] || die 'Для copy укажите читаемый файл --env'
  umask 077
  WORK=$(mktemp -d)
  trap 'rm -rf -- "$WORK"' EXIT
  mkdir "$WORK/scripts"
  # Explicit allowlist: do not upload local secrets, backups or unrelated files.
  for file in setup-node.sh configure-ha.sh bootstrap-ha.sh generate-ha-config.sh pgsqlms-ha validate-pgsqlms-ha.sh clean-ha-node.sh deploy-test-workload.sh; do
    cp -- "$SCRIPT_DIR/$file" "$WORK/scripts/"
  done
  cp -R -- "$SCRIPT_DIR/artifacts" "$SCRIPT_DIR/lib" "$WORK/scripts/"
  cp -- "$ENV" "$WORK/ha-cluster"
  tar -C "$WORK" -czf "$WORK/bundle.tar.gz" scripts ha-cluster
  for host in "$NODE1" "$NODE2"; do
    echo "[$host] Копирование комплекта..."
    # The receiving process owns a private temporary directory and cleans it on exit.
    remote "$host" bash -c '
set -euo pipefail
umask 077
stage=$(mktemp -d)
trap '\''rm -rf -- "$stage"'\'' EXIT
tar -xzf - -C "$stage"
SUDO=(); [[ $(id -u) == 0 ]] || SUDO=(sudo -n)
"${SUDO[@]}" bash -c '\''
set -euo pipefail
stage=$1
# Refuse symlink destinations rather than follow them as root.
for path in /opt/ha-cluster /opt/ha-cluster/scripts /etc/default/ha-cluster; do
  [[ ! -L $path ]] || { echo "Symlink destination: $path" >&2; exit 1; }
done
install -d -m 0755 /opt/ha-cluster /opt/ha-cluster/scripts /etc/default
cp -R -- "$stage/scripts/." /opt/ha-cluster/scripts/
chown -R root:root /opt/ha-cluster/scripts
chmod -R go-w /opt/ha-cluster/scripts
if [[ -e /etc/default/ha-cluster ]]; then
  backup=$(mktemp /etc/default/ha-cluster.backup.XXXXXX)
  cp -- /etc/default/ha-cluster "$backup"
fi
install -o root -g root -m 0600 "$stage/ha-cluster" /etc/default/ha-cluster
'\'' bash "$stage"
' < "$WORK/bundle.tar.gz"
  done
else
  run_action() {
    local host=$1 script=$2 flag=${3:-}
    echo "[$host] $script $flag"
    remote "$host" bash -c '
set -euo pipefail
SUDO=(); [[ $(id -u) == 0 ]] || SUDO=(sudo -n)
cd /opt/ha-cluster/scripts
if [[ -n $2 ]]; then
  "${SUDO[@]}" bash "./$1" "$2"
else
  "${SUDO[@]}" bash "./$1"
fi
' bash "$script" "$flag"
  }
  case $ACTION in
    master) run_action "$NODE1" setup-node.sh --master;;
    standby) run_action "$NODE2" setup-node.sh --standby;;
    stop-master) run_action "$NODE1" setup-node.sh --stop-master;;
    configure)
      run_action "$NODE1" configure-ha.sh
      run_action "$NODE2" configure-ha.sh;;
    init) run_action "$NODE1" configure-ha.sh --init-pcs;;
  esac
fi
echo "Готово: $ACTION"
