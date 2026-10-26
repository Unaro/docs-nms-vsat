#!/usr/bin/env bash
# =============================================================================
# РАЗВЕРТЫВАНИЕ ТЕСТОВОЙ НАГРУЗКИ (APP + DAEMON)
# =============================================================================
set -euo pipefail

# 0. Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
  echo "[ОШИБКА] Запустите скрипт с правами root: sudo bash $0"
  exit 1
fi

ENV_FILE="/etc/default/ha-cluster"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ОШИБКА] Файл $ENV_FILE не найден. Сначала выполните generate-ha-config.sh."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

MY_HOSTNAME=$(hostname -s)
APP_SERVICE="${APP_SERVICE:-my-app}"
APP_SERVICE="${APP_SERVICE%.service}"
DAEMON_SERVICE="${DAEMON_SERVICE:-my-daemon}"
DAEMON_SERVICE="${DAEMON_SERVICE%.service}"

PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DB_PORT="${DB_PORT:-5432}"
HAPROXY_DB_BIND_PORT="${HAPROXY_DB_BIND_PORT:-5000}"
NODEJS_PORT="8080"

APP_DB_USER="${APP_DB_USER:-app_user}"
APP_DB_PASS="${APP_DB_PASS:-AppSecretPass!}"
PGPASS_DEMO="/var/lib/postgresql/.pgpass.demo"

echo "====================================================================="
echo " Развертывание тестовой нагрузки на узле: $MY_HOSTNAME"
echo "====================================================================="

echo "[1/6] Установка системных зависимостей (Node.js, Python3)..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs python3 python3-psycopg2 curl

echo "[2/6] Настройка прав sudoers для пользователя postgres..."
cat << 'EOF' > /etc/sudoers.d/ha-cluster-postgres
postgres ALL=(ALL) NOPASSWD: /usr/sbin/corosync-cfgtool, /usr/sbin/crm_mon, /usr/sbin/pcs
EOF
chmod 0440 /etc/sudoers.d/ha-cluster-postgres

echo "[3/6] Настройка pg_hba.conf и .pgpass для ${APP_DB_USER}..."
# 1. Разрешаем сокет, localhost и кластерные подсети колец для HAProxy
if [[ -f "${PGDATA}/pg_hba.conf" ]]; then
  if ! grep -q "APP_USER ACCESS" "${PGDATA}/pg_hba.conf"; then
    echo "[INFO] Добавляем правила trust для ${APP_DB_USER} в начало pg_hba.conf..."
    sed -i "1i # --- APP_USER ACCESS ---" "${PGDATA}/pg_hba.conf"
    sed -i "2i local   all             ${APP_DB_USER}                                trust" "${PGDATA}/pg_hba.conf"
    sed -i "3i host    all             ${APP_DB_USER}        127.0.0.1/32            trust" "${PGDATA}/pg_hba.conf"
    sed -i "4i host    all             ${APP_DB_USER}        ${NODE1_RING0_IP%.*}.0/24       trust" "${PGDATA}/pg_hba.conf"
    sed -i "5i host    all             ${APP_DB_USER}        ${NODE1_RING1_IP%.*}.0/24       trust" "${PGDATA}/pg_hba.conf"
    sed -i "6i # -----------------------" "${PGDATA}/pg_hba.conf"
    sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" reload >/dev/null 2>&1 || true
    echo "[УСПЕХ] Правила trust применены в pg_hba.conf."
  fi
fi

# 2. Файл .pgpass с маской портов (*)
cat > "$PGPASS_DEMO" <<EOF
127.0.0.1:*:*:${APP_DB_USER}:${APP_DB_PASS}
localhost:*:*:${APP_DB_USER}:${APP_DB_PASS}
*:*:*:${APP_DB_USER}:${APP_DB_PASS}
EOF

chown postgres:postgres "$PGPASS_DEMO"
chmod 0600 "$PGPASS_DEMO"

echo "[4/6] Инициализация тестовой схемы БД (только если узел Master)..."
IS_LOCAL_MASTER="no"
if sudo -u postgres "$PGBIN/psql" \
     -h /var/run/postgresql \
     -p "$DB_PORT" \
     -d postgres \
     -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx "f"; then
  IS_LOCAL_MASTER="yes"
fi

if [[ "$IS_LOCAL_MASTER" == "yes" ]]; then
  echo "[INFO] Локальный PostgreSQL является Master. Применяем схему..."
  sudo -u postgres "$PGBIN/psql" -h /var/run/postgresql -p "$DB_PORT" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${APP_DB_USER}') THEN
    CREATE ROLE ${APP_DB_USER} LOGIN PASSWORD '${APP_DB_PASS}' SUPERUSER;
  ELSE
    ALTER ROLE ${APP_DB_USER} LOGIN PASSWORD '${APP_DB_PASS}' SUPERUSER;
  END IF;
END
\$\$;

CREATE TABLE IF NOT EXISTS public.cluster_heartbeats (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    node_name VARCHAR(64) NOT NULL,
    cpu_usage REAL DEFAULT 0,
    mem_usage REAL DEFAULT 0,
    disk_free_pct REAL DEFAULT 0,
    rings_ok BOOLEAN DEFAULT TRUE,
    is_master BOOLEAN DEFAULT FALSE,
    payload JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_heartbeats_node_created 
ON public.cluster_heartbeats (node_name, created_at DESC);

GRANT ALL ON SCHEMA public TO ${APP_DB_USER};
GRANT ALL ON TABLE public.cluster_heartbeats TO ${APP_DB_USER};
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${APP_DB_USER};
SQL
  echo "[УСПЕХ] Таблица cluster_heartbeats готова к работе."
else
  echo "[INFO] Локальный PostgreSQL в режиме STANDBY. Схема синхронизируется через репликацию."
fi

echo "[5/6] Создание исполняемых файлов приложений..."

# -----------------------------------------------------------------------------
# 1. WEB HUB (Node.js)
# -----------------------------------------------------------------------------
cat << 'EOF' > /usr/local/bin/my-app.js
#!/usr/bin/env node
const http = require('http');
const url = require('url');
const { exec, execFile } = require('child_process');

const PORT = parseInt(process.env.NODEJS_PORT || '8080', 10);
const HAPROXY_PORT = process.env.HAPROXY_DB_BIND_PORT || '5000';
const APP_DB_USER = process.env.APP_DB_USER || 'app_user';

const sseClients = new Set();
let cachedState = null;

function runCmd(cmd) {
  return new Promise((resolve) => {
    exec(cmd, { timeout: 4000 }, (err, stdout) => {
      resolve(err ? '' : stdout.trim());
    });
  });
}

function runPsql(sql) {
  return new Promise((resolve) => {
    execFile('psql', [
      '-h', '127.0.0.1',
      '-p', HAPROXY_PORT,
      '-U', APP_DB_USER,
      '-d', 'postgres',
      '-tAc', sql
    ], {
      timeout: 4000,
      env: { ...process.env, PGPASSFILE: process.env.PGPASSFILE || '/var/lib/postgresql/.pgpass.demo' }
    }, (err, stdout) => {
      if (err) return resolve(null);
      resolve(stdout.trim());
    });
  });
}

async function collectClusterState() {
  // 1. Кольца Corosync
  const rawCfg = await runCmd('sudo /usr/sbin/corosync-cfgtool -s 2>/dev/null || /usr/sbin/corosync-cfgtool -s 2>/dev/null');
  const rings = [];
  if (rawCfg) {
    const blocks = rawCfg.split(/(?=(?:RING|LINK)\s+ID\s+\d+)/i);
    for (const block of blocks) {
      const idMatch = block.match(/(?:RING|LINK)\s+ID\s+(\d+)/i);
      if (!idMatch) continue;
      const ringId = idMatch[1];
      const isFaulty = /fault|fail|not connected|disconnected/i.test(block);
      const isConnected = /no error|no fault|connected|active/i.test(block);
      const healthy = !isFaulty && isConnected;
      const addrMatch = block.match(/(?:addr|id)\s*=\s*([^\s\n]+)/i);

      rings.push({
        ring_id: ringId,
        addr: addrMatch ? addrMatch[1] : '',
        status: healthy ? 'Active' : 'Faulty',
        healthy: healthy
      });
    }
  }

  // 2. Узлы Pacemaker
  const rawCrm = await runCmd('sudo /usr/sbin/crm_mon -1 2>/dev/null || /usr/sbin/crm_mon -1 2>/dev/null');
  const nodes = [];
  const onlineMatch = rawCrm.match(/Online:\s*\[(.*?)\]/);
  const offlineMatch = rawCrm.match(/OFFLINE:\s*\[(.*?)\]/);
  if (onlineMatch) {
    onlineMatch[1].trim().split(/\s+/).filter(Boolean).forEach(n => nodes.push({ name: n, status: 'Online' }));
  }
  if (offlineMatch) {
    offlineMatch[1].trim().split(/\s+/).filter(Boolean).forEach(n => nodes.push({ name: n, status: 'Offline' }));
  }

  // 3. Репликация через HAProxy
  const replSql = `
    SELECT json_build_object(
      'current_wal', pg_current_wal_lsn(),
      'in_recovery', pg_is_in_recovery(),
      'streams', COALESCE(json_agg(json_build_object(
        'client_addr', client_addr,
        'app_name', application_name,
        'state', state,
        'sync_state', sync_state,
        'sync_priority', sync_priority,
        'lag_bytes', pg_wal_lsn_diff(sent_lsn, replay_lsn)
      )), '[]'::json)
    )
    FROM pg_stat_replication;
  `;
  const rawRepl = await runPsql(replSql);
  let replication = null;
  try {
    replication = rawRepl ? JSON.parse(rawRepl) : null;
  } catch (e) { replication = null; }

  // 4. Последняя телеметрия узлов
  const telemetrySql = `
    SELECT json_agg(t) FROM (
      SELECT DISTINCT ON (node_name)
        node_name, created_at, cpu_usage, mem_usage, disk_free_pct, rings_ok, is_master, payload
      FROM public.cluster_heartbeats
      ORDER BY node_name, created_at DESC
    ) t;
  `;
  const rawTelemetry = await runPsql(telemetrySql);
  let telemetry = [];
  try {
    telemetry = rawTelemetry ? JSON.parse(rawTelemetry) : [];
  } catch (e) { telemetry = []; }

  // 5. Метрики СУБД
  const dbMetricsSql = `
    SELECT json_build_object(
      'databases', (
        SELECT COALESCE(json_agg(json_build_object(
          'datname', datname,
          'size', pg_size_pretty(pg_database_size(datname)),
          'numbackends', numbackends,
          'xact_commit', xact_commit,
          'xact_rollback', xact_rollback,
          'cache_hit_pct', CASE WHEN (blks_hit + blks_read) > 0 THEN round((blks_hit::numeric / (blks_hit + blks_read) * 100), 2) ELSE 100 END
        )), '[]'::json)
        FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1')
      ),
      'connections', (
        SELECT COALESCE(json_agg(json_build_object('state', COALESCE(state, 'idle'), 'count', c)), '[]'::json)
        FROM (SELECT state, count(*) as c FROM pg_stat_activity GROUP BY state) s
      ),
      'tables', (
        SELECT COALESCE(json_agg(json_build_object(
          'relname', relname,
          'live_tup', n_live_tup,
          'dead_tup', n_dead_tup,
          'size', pg_size_pretty(pg_total_relation_size(relid))
        )), '[]'::json)
        FROM (
          SELECT relname, n_live_tup, n_dead_tup, relid 
          FROM pg_stat_user_tables 
          ORDER BY pg_total_relation_size(relid) DESC LIMIT 10
        ) t
      )
    );
  `;
  const rawDbMetrics = await runPsql(dbMetricsSql);
  let db_metrics = null;
  try {
    db_metrics = rawDbMetrics ? JSON.parse(rawDbMetrics) : null;
  } catch (e) { db_metrics = null; }

  return {
    timestamp: new Date().toISOString(),
    rings,
    nodes,
    raw_crm: rawCrm,
    replication,
    telemetry,
    db_metrics
  };
}

async function getMetricsHistory(node, limit = 120) {
  const filter = node && node !== 'all' ? `WHERE node_name = '${node.replace(/[^a-zA-Z0-9_-]/g, '')}'` : '';
  const sql = `
    SELECT json_agg(h) FROM (
      SELECT id, created_at, node_name, cpu_usage, mem_usage, disk_free_pct, rings_ok, is_master
      FROM public.cluster_heartbeats
      ${filter}
      ORDER BY created_at DESC
      LIMIT ${parseInt(limit, 10) || 120}
    ) h;
  `;
  const raw = await runPsql(sql);
  try {
    return raw ? JSON.parse(raw) : [];
  } catch (e) {
    return [];
  }
}

async function broadcastUpdate() {
  if (sseClients.size === 0) return;
  cachedState = await collectClusterState();
  const payload = `retry: 2000\ndata: ${JSON.stringify(cachedState)}\n\n`;
  for (const client of sseClients) {
    client.write(payload);
  }
}

setInterval(broadcastUpdate, 3000);

const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url, true);

  if (parsedUrl.pathname === '/api/stream') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*'
    });
    res.write('retry: 2000\n\n');
    sseClients.add(res);

    if (cachedState) {
      res.write(`data: ${JSON.stringify(cachedState)}\n\n`);
    } else {
      collectClusterState().then(s => {
        cachedState = s;
        res.write(`data: ${JSON.stringify(cachedState)}\n\n`);
      });
    }

    req.on('close', () => sseClients.delete(res));
    return;
  }

  if (parsedUrl.pathname === '/api/heartbeat' && req.method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    broadcastUpdate();
    return;
  }

  if (parsedUrl.pathname === '/api/history') {
    const node = parsedUrl.query.node || 'all';
    const history = await getMetricsHistory(node, 120);
    res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    return res.end(JSON.stringify(history));
  }

  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>HA Cluster Control Dashboard</title>
  <style>
    :root {
      --bg: #0b1120; --panel: #1e293b; --card: #162032; --text: #f8fafc;
      --muted: #94a3b8; --border: #334155; --accent: #38bdf8;
      --ok: #22c55e; --fail: #ef4444; --warn: #f59e0b;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: var(--bg); color: var(--text); padding: 24px; line-height: 1.5; }
    
    .nav-tabs { display: flex; gap: 8px; border-bottom: 2px solid var(--border); margin-bottom: 24px; padding-bottom: 12px; }
    .tab-btn { background: transparent; border: none; color: var(--muted); padding: 10px 18px; font-size: 0.95rem; font-weight: 600; cursor: pointer; border-radius: 8px; transition: all 0.2s; }
    .tab-btn:hover { background: rgba(255,255,255,0.05); color: var(--text); }
    .tab-btn.active { background: var(--panel); color: var(--accent); border-bottom: 3px solid var(--accent); }

    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 20px; }
    .card { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 20px; min-width: 0; }
    h2 { font-size: 1.05rem; color: var(--muted); margin-bottom: 14px; text-transform: uppercase; letter-spacing: 0.5px; }

    .badge { display: inline-block; padding: 4px 10px; border-radius: 9999px; font-size: 0.75rem; font-weight: bold; }
    .badge-ok { background: rgba(34,197,94,0.15); color: var(--ok); border: 1px solid var(--ok); }
    .badge-fail { background: rgba(239,68,68,0.15); color: var(--fail); border: 1px solid var(--fail); }
    .badge-warn { background: rgba(245,158,11,0.15); color: var(--warn); border: 1px solid var(--warn); }
    
    .table-wrap { width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }
    table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 0.88rem; white-space: nowrap; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); font-weight: 600; }
    .row-stale { opacity: 0.75; background: rgba(245, 158, 11, 0.08); }
    .row-offline { opacity: 0.55; background: rgba(239, 68, 68, 0.12); }

    .node-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    pre { background: #070d18; padding: 12px; border-radius: 6px; font-size: 0.75rem; overflow-x: auto; color: #cbd5e1; max-height: 200px; }

    .charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 20px; margin-bottom: 20px; }
    .chart-container { background: #070d18; border-radius: 8px; padding: 16px; margin-top: 10px; border: 1px solid rgba(255,255,255,0.05); }
    svg { width: 100%; height: 160px; overflow: visible; }
    .chart-line-cpu { fill: none; stroke: var(--accent); stroke-width: 2.2; stroke-linejoin: round; }
    .chart-line-mem { fill: none; stroke: var(--warn); stroke-width: 2.2; stroke-linejoin: round; }
  </style>
</head>
<body>

  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:20px;">
    <div>
      <h1 style="font-size:1.5rem;">Кластер высокой доступности</h1>
      <span id="conn-status" class="badge badge-warn">Подключение к SSE...</span>
    </div>
    <span id="last-update" style="color:var(--muted); font-size:0.85rem;">Ожидание потока...</span>
  </div>

  <div class="nav-tabs">
    <button class="tab-btn active" onclick="switchTab('tab-overview', this)">1. Главный обзор</button>
    <button class="tab-btn" onclick="switchTab('tab-db', this)">2. Метрики СУБД</button>
    <button class="tab-btn" onclick="switchTab('tab-nodes', this)">3. Информация об узлах</button>
    <button class="tab-btn" onclick="switchTab('tab-history', this)">4. История телеметрии</button>
  </div>

  <!-- 1. ОБЗОР -->
  <div id="tab-overview" class="tab-content">
    <div class="grid">
      <div class="card">
        <h2>Сетевые кольца Corosync</h2>
        <div id="rings-box">Загрузка...</div>
      </div>

      <div class="card">
        <h2>Состояние узлов (Pacemaker)</h2>
        <div id="nodes-box">Загрузка...</div>
      </div>

      <div class="card" style="grid-column: 1 / -1;">
        <h2>Поток репликации PostgreSQL (через HAProxy :${HAPROXY_PORT})</h2>
        <div class="table-wrap" id="repl-box">Загрузка...</div>
      </div>

      <div class="card" style="grid-column: 1 / -1;">
        <h2>Сводная телеметрия узлов (интервал 30 сек, контроль актуальности)</h2>
        <div class="table-wrap" id="telemetry-box">Загрузка...</div>
      </div>

      <div class="card" style="grid-column: 1 / -1;">
        <h2>Сводка Pacemaker (crm_mon)</h2>
        <pre id="crm-raw">Загрузка...</pre>
      </div>
    </div>
  </div>

  <!-- 2. МЕТРИКИ СУБД -->
  <div id="tab-db" class="tab-content" style="display:none;">
    <div class="grid">
      <div class="card" style="grid-column: 1 / -1;">
        <h2>Базы данных и Cache Hit Ratio</h2>
        <div class="table-wrap" id="db-databases-box">Загрузка...</div>
      </div>

      <div class="card">
        <h2>Активность соединений</h2>
        <div class="table-wrap" id="db-conn-box">Загрузка...</div>
      </div>

      <div class="card">
        <h2>Топ таблиц по объему и Dead Tuples</h2>
        <div class="table-wrap" id="db-tables-box">Загрузка...</div>
      </div>
    </div>
  </div>

  <!-- 3. ИНФОРМАЦИЯ ОБ УЗЛАХ -->
  <div id="tab-nodes" class="tab-content" style="display:none;">
    <div id="nodes-details-box" class="grid">Загрузка информации...</div>
  </div>

  <!-- 4. ИСТОРИЯ И ГРАФИКИ -->
  <div id="tab-history" class="tab-content" style="display:none;">
    <div id="charts-grid-container" class="charts-grid">
      <div class="card"><span style="color:var(--muted)">Загрузка графиков...</span></div>
    </div>

    <div class="card">
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
        <h2>Журнал последних снапшотов</h2>
        <div>
          <label style="color:var(--muted); font-size:0.85rem; margin-right:8px;">Фильтр:</label>
          <select id="history-node-filter" onchange="loadHistory()" style="background:var(--card); color:var(--text); border:1px solid var(--border); padding:6px 12px; border-radius:6px;">
            <option value="all">Все узлы</option>
          </select>
        </div>
      </div>
      <div class="table-wrap" id="history-table-box">Загрузка истории...</div>
    </div>
  </div>

  <script>
    let globalData = null;
    const connBadge = document.getElementById('conn-status');

    function switchTab(tabId, btn) {
      document.querySelectorAll('.tab-content').forEach(el => el.style.display = 'none');
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.getElementById(tabId).style.display = 'block';
      if (btn) btn.classList.add('active');

      if (tabId === 'tab-history') {
        loadHistory();
      }
    }

    function connectSSE() {
      const evtSource = new EventSource('/api/stream');

      evtSource.onopen = () => {
        connBadge.className = 'badge badge-ok';
        connBadge.innerText = 'SSE: Онлайн (Live)';
      };

      evtSource.onmessage = (e) => {
        globalData = JSON.parse(e.data);
        renderOverview(globalData);
        renderDbMetrics(globalData.db_metrics);
        renderNodesInfo(globalData.telemetry);

        if (document.getElementById('tab-history').style.display === 'block') {
          loadHistory();
        }
      };

      evtSource.onerror = () => {
        connBadge.className = 'badge badge-fail';
        connBadge.innerText = 'SSE: Переподключение...';
      };
    }

    function renderOverview(data) {
      document.getElementById('last-update').innerText = 'Обновлено: ' + new Date(data.timestamp).toLocaleTimeString();

      // Кольца Corosync
      document.getElementById('rings-box').innerHTML = data.rings.length === 0 
        ? "<span class='badge badge-fail'>Нет данных</span>"
        : data.rings.map(r => \`
          <div class="node-bar">
            <span><b>Ring/Link \${r.ring_id}</b> \${r.addr ? '(' + r.addr + ')' : ''}</span>
            <span class="badge \${r.healthy ? 'badge-ok' : 'badge-fail'}">\${r.status}</span>
          </div>
        \`).join('');

      // Узлы Pacemaker
      document.getElementById('nodes-box').innerHTML = data.nodes.length === 0
        ? "<span class='badge badge-fail'>Узлы не определены</span>"
        : data.nodes.map(n => \`
          <div class="node-bar">
            <span>\${n.name}</span>
            <span class="badge \${n.status === 'Online' ? 'badge-ok' : 'badge-fail'}">\${n.status}</span>
          </div>
        \`).join('');

      // Репликация
      if (!data.replication) {
        document.getElementById('repl-box').innerHTML = "<span class='badge badge-fail'>СУБД недоступна через HAProxy</span>";
      } else {
        const r = data.replication;
        let html = \`<div style="margin-bottom:8px;">Текущий Master LSN: <b>\${r.current_wal || 'N/A'}</b></div>\`;
        if (!r.streams || r.streams.length === 0) {
          html += "<div style='color:var(--warn);'>Потоки репликации отсутствуют (Standby отключен)</div>";
        } else {
          html += '<table><thead><tr><th>Клиент</th><th>Приложение</th><th>Состояние</th><th>Синхронизация</th><th>Отставание</th></tr></thead><tbody>';
          r.streams.forEach(s => {
            const lag = s.lag_bytes !== null ? (s.lag_bytes / 1024).toFixed(2) + ' KB' : '0 B';
            html += \`<tr><td>\${s.client_addr}</td><td>\${s.app_name}</td><td>\${s.state}</td><td><span class="badge \${s.sync_state === 'sync' ? 'badge-ok' : 'badge-fail'}">\${s.sync_state}</span></td><td>\${lag}</td></tr>\`;
          });
          html += '</tbody></table>';
        }
        document.getElementById('repl-box').innerHTML = html;
      }

      // Телеметрия
      if (!data.telemetry || data.telemetry.length === 0) {
        document.getElementById('telemetry-box').innerHTML = "<span style='color:var(--muted)'>Нет телеметрии</span>";
      } else {
        let tHtml = '<table><thead><tr><th>Узел</th><th>Возраст метрики</th><th>Статус актуальности</th><th>CPU</th><th>RAM</th><th>Диск</th><th>Кольца</th><th>Роль</th></tr></thead><tbody>';
        data.telemetry.forEach(t => {
          const ageSec = Math.round((new Date() - new Date(t.created_at)) / 1000);
          let freshnessBadge = "<span class='badge badge-ok'>Свежая</span>";
          let rowClass = '';

          if (ageSec > 90) {
            freshnessBadge = "<span class='badge badge-fail'>ОФЛАЙН (>90с)</span>";
            rowClass = 'row-offline';
          } else if (ageSec > 45) {
            freshnessBadge = "<span class='badge badge-warn'>УСТАРЕЛА (>45с)</span>";
            rowClass = 'row-stale';
          }

          tHtml += \`<tr class="\${rowClass}">
            <td><b>\${t.node_name}</b></td>
            <td>\${ageSec}с назад</td>
            <td>\${freshnessBadge}</td>
            <td>\${t.cpu_usage}%</td>
            <td>\${t.mem_usage}%</td>
            <td>\${t.disk_free_pct}% своб.</td>
            <td><span class="badge \${t.rings_ok ? 'badge-ok' : 'badge-fail'}">\${t.rings_ok ? 'OK' : 'ERR'}</span></td>
            <td><span class="badge \${t.is_master ? 'badge-ok' : 'badge-warn'}">\${t.is_master ? 'MASTER' : 'STANDBY'}</span></td>
          </tr>\`;
        });
        tHtml += '</tbody></table>';
        document.getElementById('telemetry-box').innerHTML = tHtml;
      }

      document.getElementById('crm-raw').innerText = data.raw_crm || 'crm_mon недоступен';
    }

    function renderDbMetrics(db) {
      if (!db) {
        document.getElementById('db-databases-box').innerHTML = "<span class='badge badge-fail'>Нет данных</span>";
        return;
      }

      let dbHtml = '<table><thead><tr><th>Имя БД</th><th>Размер</th><th>Активных соединений</th><th>Cache Hit Ratio</th><th>Успешных транзакций</th><th>Откатов (Rollback)</th></tr></thead><tbody>';
      db.databases.forEach(d => {
        dbHtml += \`<tr>
          <td><b>\${d.datname}</b></td>
          <td>\${d.size}</td>
          <td>\${d.numbackends}</td>
          <td><span class="badge \${d.cache_hit_pct >= 95 ? 'badge-ok' : 'badge-warn'}">\${d.cache_hit_pct}%</span></td>
          <td>\${d.xact_commit}</td>
          <td style="\${d.xact_rollback > 0 ? 'color:var(--fail)' : ''}">\${d.xact_rollback}</td>
        </tr>\`;
      });
      dbHtml += '</tbody></table>';
      document.getElementById('db-databases-box').innerHTML = dbHtml;

      let connHtml = '<table><thead><tr><th>Состояние</th><th>Количество</th></tr></thead><tbody>';
      db.connections.forEach(c => {
        connHtml += \`<tr><td>\${c.state}</td><td><b>\${c.count}</b></td></tr>\`;
      });
      connHtml += '</tbody></table>';
      document.getElementById('db-conn-box').innerHTML = connHtml;

      let tblHtml = '<table><thead><tr><th>Таблица</th><th>Размер</th><th>Живых записей</th><th>Dead Tuples</th></tr></thead><tbody>';
      db.tables.forEach(t => {
        const deadRatio = t.live_tup > 0 ? (t.dead_tup / t.live_tup * 100).toFixed(1) : 0;
        tblHtml += \`<tr>
          <td><b>\${t.relname}</b></td>
          <td>\${t.size}</td>
          <td>\${t.live_tup}</td>
          <td>\${t.dead_tup} (\${deadRatio}%)</td>
        </tr>\`;
      });
      tblHtml += '</tbody></table>';
      document.getElementById('db-tables-box').innerHTML = tblHtml;
    }

    function renderNodesInfo(telemetry) {
      if (!telemetry || telemetry.length === 0) return;

      const select = document.getElementById('history-node-filter');
      const currentVal = select.value;
      const nodesList = telemetry.map(t => t.node_name);
      
      select.innerHTML = "<option value='all'>Все узлы</option>";
      nodesList.forEach(name => {
        const opt = document.createElement('option');
        opt.value = name;
        opt.innerText = name;
        select.appendChild(opt);
      });
      select.value = currentVal;

      let html = '';
      telemetry.forEach(t => {
        const hw = (t.payload && t.payload.hardware) ? t.payload.hardware : {};
        const mem = (t.payload && t.payload.memory_details) ? t.payload.memory_details : {};
        const ageSec = Math.round((new Date() - new Date(t.created_at)) / 1000);
        const statusBadge = ageSec <= 45 
          ? "<span class='badge badge-ok'>В сети</span>" 
          : "<span class='badge badge-warn'>Устарел</span>";

        html += \`
        <div class="card">
          <div style="display:flex; justify-content:space-between; margin-bottom:12px;">
            <h2>Узел: \${t.node_name}</h2>
            <span class="badge \${t.is_master ? 'badge-ok' : 'badge-warn'}">\${t.is_master ? 'MASTER' : 'STANDBY'}</span>
          </div>
          <div class="table-wrap">
            <table>
              <tr><th>Статус отклика</th><td>\${statusBadge} (\${ageSec}с назад)</td></tr>
              <tr><th>Процессор</th><td>\${hw.cpu_model || 'Unknown'} (\${hw.cpu_cores || 1} ядра)</td></tr>
              <tr><th>Load Average</th><td>\${(hw.load_avg || []).join(', ')}</td></tr>
              <tr><th>Ядро ОС / Arch</th><td>\${hw.kernel || 'N/A'} (\${hw.arch || 'x86_64'})</td></tr>
              <tr><th>Аптайм системы</th><td>\${hw.uptime || 'N/A'}</td></tr>
              <tr><th>Оперативная память</th><td>\${mem.used_mb || 0} MB / \${mem.total_mb || 0} MB (\${t.mem_usage}%)</td></tr>
              <tr><th>Свободно на диске</th><td>\${t.disk_free_pct}%</td></tr>
            </table>
          </div>
        </div>\`;
      });
      document.getElementById('nodes-details-box').innerHTML = html;
    }

    async function loadHistory() {
      const node = document.getElementById('history-node-filter').value;
      const res = await fetch('/api/history?node=' + encodeURIComponent(node) + '&limit=120');
      const list = await res.json();

      if (!list || list.length === 0) {
        document.getElementById('history-table-box').innerHTML = "<span style='color:var(--muted)'>История пуста</span>";
        document.getElementById('charts-grid-container').innerHTML = '';
        return;
      }

      let html = '<table><thead><tr><th>Узел</th><th>Время записи</th><th>CPU</th><th>RAM</th><th>Диск</th><th>Кольца</th><th>Роль</th></tr></thead><tbody>';
      list.forEach(row => {
        html += \`<tr>
          <td><b>\${row.node_name}</b></td>
          <td>\${new Date(row.created_at).toLocaleTimeString()}</td>
          <td>\${row.cpu_usage}%</td>
          <td>\${row.mem_usage}%</td>
          <td>\${row.disk_free_pct}%</td>
          <td><span class="badge \${row.rings_ok ? 'badge-ok' : 'badge-fail'}">\${row.rings_ok ? 'OK' : 'ERR'}</span></td>
          <td><span class="badge \${row.is_master ? 'badge-ok' : 'badge-warn'}">\${row.is_master ? 'MASTER' : 'STANDBY'}</span></td>
        </tr>\`;
      });
      html += '</tbody></table>';
      document.getElementById('history-table-box').innerHTML = html;

      const byNode = {};
      list.forEach(r => {
        if (!byNode[r.node_name]) byNode[r.node_name] = [];
        byNode[r.node_name].push(r);
      });

      renderPerNodeCharts(byNode);
    }

    function renderPerNodeCharts(byNode) {
      const container = document.getElementById('charts-grid-container');
      container.innerHTML = '';

      const nodeNames = Object.keys(byNode).sort();
      if (nodeNames.length === 0) return;

      nodeNames.forEach(nodeName => {
        const data = byNode[nodeName].slice(0, 40).reverse();
        const latest = data[data.length - 1] || { cpu_usage: 0, mem_usage: 0 };

        const card = document.createElement('div');
        card.className = 'card';
        card.innerHTML = \`
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <h2>График нагрузки: \${nodeName}</h2>
            <div style="font-size:0.8rem; display:flex; gap:12px;">
              <span style="color:var(--accent);">CPU: <b>\${latest.cpu_usage}%</b></span>
              <span style="color:var(--warn);">RAM: <b>\${latest.mem_usage}%</b></span>
            </div>
          </div>
          <div class="chart-container">
            <svg id="svg-\${nodeName}" viewBox="0 0 600 160"></svg>
          </div>
        \`;
        container.appendChild(card);

        drawNodeSvg('svg-' + nodeName, data);
      });
    }

    function drawNodeSvg(svgId, data) {
      const svg = document.getElementById(svgId);
      if (!svg || data.length < 2) return;

      const width = 600;
      const height = 160;
      const padLeft = 35;
      const padRight = 15;
      const padTop = 15;
      const padBottom = 25;

      const chartW = width - padLeft - padRight;
      const chartH = height - padTop - padBottom;
      const step = chartW / (data.length - 1);

      let cpuPoints = [];
      let memPoints = [];

      data.forEach((d, i) => {
        const x = padLeft + i * step;
        const yCpu = padTop + chartH - (d.cpu_usage / 100 * chartH);
        const yMem = padTop + chartH - (d.mem_usage / 100 * chartH);
        cpuPoints.push(\`\${x.toFixed(1)},\${yCpu.toFixed(1)}\`);
        memPoints.push(\`\${x.toFixed(1)},\${yMem.toFixed(1)}\`);
      });

      svg.innerHTML = \`
        <line x1="\${padLeft}" y1="\${padTop}" x2="\${width - padRight}" y2="\${padTop}" stroke="#334155" stroke-dasharray="3" stroke-width="1" />
        <line x1="\${padLeft}" y1="\${padTop + chartH / 2}" x2="\${width - padRight}" y2="\${padTop + chartH / 2}" stroke="#334155" stroke-dasharray="3" stroke-width="1" />
        <line x1="\${padLeft}" y1="\${padTop + chartH}" x2="\${width - padRight}" y2="\${padTop + chartH}" stroke="#475569" stroke-width="1.5" />

        <text x="\${padLeft - 8}" y="\${padTop + 4}" fill="#64748b" font-size="10" text-anchor="end">100%</text>
        <text x="\${padLeft - 8}" y="\${padTop + chartH / 2 + 3}" fill="#64748b" font-size="10" text-anchor="end">50%</text>
        <text x="\${padLeft - 8}" y="\${padTop + chartH + 3}" fill="#64748b" font-size="10" text-anchor="end">0%</text>

        <text x="\${padLeft}" y="\${height - 6}" fill="#64748b" font-size="9">\${new Date(data[0].created_at).toLocaleTimeString()}</text>
        <text x="\${width - padRight}" y="\${height - 6}" fill="#64748b" font-size="9" text-anchor="end">\${new Date(data[data.length - 1].created_at).toLocaleTimeString()}</text>

        <polyline class="chart-line-cpu" points="\${cpuPoints.join(' ')}" />
        <polyline class="chart-line-mem" points="\${memPoints.join(' ')}" />
      \`;
    }

    connectSSE();
  </script>
</body>
</html>`);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Cluster Control Hub запущен на порту ${PORT}`);
});
EOF
sudo chmod +x /usr/local/bin/my-app.js

# -----------------------------------------------------------------------------
# 2. ДЕМОН ТЕЛЕМЕТРИИ (Python 3)
# -----------------------------------------------------------------------------
cat << 'EOF' > /usr/local/bin/my-daemon.py
#!/usr/bin/env python3
import os
import sys
import time
import json
import socket
import shutil
import platform
import subprocess
import urllib.request
import psycopg2

INTERVAL_SEC = 30
MY_HOSTNAME = socket.gethostname().split('.')[0]
HAPROXY_PORT = int(os.environ.get("HAPROXY_DB_BIND_PORT", "5000"))
NODEJS_PORT = int(os.environ.get("NODEJS_PORT", "8080"))
CLUSTER_VIP = os.environ.get("CLUSTER_VIP", "127.0.0.1")
DB_USER = os.environ.get("APP_DB_USER", "app_user")
DB_PASS = os.environ.get("APP_DB_PASS", "AppSecretPass!")

def get_cpu_usage():
    try:
        def read_stat():
            with open('/proc/stat', 'r') as f:
                return [int(x) for x in f.readline().split()[1:]]
        s1 = read_stat()
        time.sleep(0.5)
        s2 = read_stat()
        delta = [b - a for a, b in zip(s1, s2)]
        total = sum(delta)
        idle = delta[3]
        return round(((total - idle) / total) * 100.0, 1) if total > 0 else 0.0
    except Exception:
        return 0.0

def get_memory_info():
    try:
        meminfo = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    meminfo[parts[0].strip()] = int(parts[1].split()[0])
        total_kb = meminfo.get('MemTotal', 1)
        available_kb = meminfo.get('MemAvailable', meminfo.get('MemFree', 0))
        used_kb = total_kb - available_kb
        pct = round((used_kb / total_kb) * 100.0, 1)
        return {
            "percent": pct,
            "total_mb": round(total_kb / 1024),
            "used_mb": round(used_kb / 1024),
            "free_mb": round(available_kb / 1024)
        }
    except Exception:
        return {"percent": 0.0, "total_mb": 0, "used_mb": 0, "free_mb": 0}

def get_disk_free_pct(path="/var/lib/postgresql"):
    try:
        target = path if os.path.exists(path) else "/"
        stat = shutil.disk_usage(target)
        return round((stat.free / stat.total) * 100.0, 1)
    except Exception:
        return 0.0

def get_system_hardware():
    cpu_model = "Unknown"
    try:
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if 'model name' in line:
                    cpu_model = line.split(':', 1)[1].strip()
                    break
    except Exception:
        pass

    uptime_str = "Unknown"
    try:
        with open('/proc/uptime', 'r') as f:
            sec = float(f.readline().split()[0])
            days = int(sec // 86400)
            hours = int((sec % 86400) // 3600)
            mins = int((sec % 3600) // 60)
            uptime_str = f"{days}д {hours}ч {mins}м"
    except Exception:
        pass

    load_avg = [round(x, 2) for x in os.getloadavg()] if hasattr(os, "getloadavg") else [0, 0, 0]

    return {
        "kernel": platform.release(),
        "arch": platform.machine(),
        "cpu_model": cpu_model,
        "cpu_cores": os.cpu_count() or 1,
        "uptime": uptime_str,
        "load_avg": load_avg
    }

def check_corosync_rings():
    try:
        res = subprocess.run(
            ["sudo", "/usr/sbin/corosync-cfgtool", "-s"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3
        )
        if res.returncode != 0:
            return False, res.stderr.strip()
        out = res.stdout.lower()
        is_ok = not any(w in out for w in ["fault", "fail", "not connected", "disconnected"])
        return is_ok, res.stdout.strip()
    except Exception as e:
        return False, str(e)

def is_local_master():
    try:
        res = subprocess.run(
            ["psql", "-h", "/var/run/postgresql", "-d", "postgres", "-tAc", "SELECT pg_is_in_recovery();"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=2
        )
        return res.stdout.strip() == "f"
    except Exception:
        return False

def notify_app_via_vip():
    url = f"http://{CLUSTER_VIP}:{NODEJS_PORT}/api/heartbeat"
    try:
        req = urllib.request.Request(url, data=b'{"event":"ping"}', headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            pass
    except Exception:
        pass

def push_telemetry():
    cpu = get_cpu_usage()
    mem_info = get_memory_info()
    disk_free = get_disk_free_pct()
    rings_ok, rings_details = check_corosync_rings()
    local_master = is_local_master()
    hw_info = get_system_hardware()

    payload = {
        "rings_raw": rings_details,
        "hardware": hw_info,
        "memory_details": mem_info,
        "collected_at": time.strftime("%Y-%m-%d %H:%M:%S")
    }

    insert_sql = """
    INSERT INTO public.cluster_heartbeats (
        node_name, cpu_usage, mem_usage, disk_free_pct, rings_ok, is_master, payload
    ) VALUES (%s, %s, %s, %s, %s, %s, %s);
    """

    conn = None
    try:
        conn = psycopg2.connect(
            host="127.0.0.1",
            port=HAPROXY_PORT,
            user=DB_USER,
            password=DB_PASS,
            dbname="postgres",
            connect_timeout=3
        )
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(insert_sql, (
                MY_HOSTNAME, cpu, mem_info["percent"], disk_free, rings_ok, local_master, json.dumps(payload)
            ))
            # Ротация метрик (храним 7 дней)
            cur.execute("DELETE FROM public.cluster_heartbeats WHERE created_at < NOW() - INTERVAL '7 days';")
    except Exception as err:
        sys.stderr.write(f"[WARN] Ошибка отправки метрик в СУБД: {err}\n")
    finally:
        if conn:
            conn.close()

    # Оповещаем веб-сервер через VIP о новом тике
    notify_app_via_vip()

def main():
    sys.stdout.write(f"[INFO] Демон телеметрии запущен на хосте {MY_HOSTNAME}\n")
    sys.stdout.flush()
    while True:
        try:
            push_telemetry()
        except Exception as e:
            sys.stderr.write(f"[ERROR] Ошибка цикла телеметрии: {e}\n")
        time.sleep(INTERVAL_SEC)

if __name__ == "__main__":
    main()
EOF
chmod +x /usr/local/bin/my-daemon.py

echo "[6/6] Создание и запуск systemd-юнитов..."

# Юнит my-app
cat << EOF > /etc/systemd/system/${APP_SERVICE}.service
[Unit]
Description=Cluster Node.js Web Hub
After=network.target

[Service]
Type=simple
User=postgres
EnvironmentFile=-/etc/default/ha-cluster
Environment=PGPASSFILE=${PGPASS_DEMO}
Environment=APP_DB_USER=${APP_DB_USER}
Environment=APP_DB_PASS=${APP_DB_PASS}
Environment=HAPROXY_DB_BIND_PORT=${HAPROXY_DB_BIND_PORT}
Environment=NODEJS_PORT=${NODEJS_PORT}
Environment=CLUSTER_VIP=${CLUSTER_VIP}
ExecStart=/usr/bin/node /usr/local/bin/my-app.js
Restart=no

MemoryMax=${APP_MEMORY_MAX:-75%}
CPUQuota=${APP_CPU_QUOTA:-80%}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Юнит my-daemon
cat << EOF > /etc/systemd/system/${DAEMON_SERVICE}.service
[Unit]
Description=Cluster Telemetry Daemon
After=network.target ${APP_SERVICE}.service

[Service]
Type=simple
User=postgres
EnvironmentFile=-/etc/default/ha-cluster
Environment=PGPASSFILE=${PGPASS_DEMO}
Environment=APP_DB_USER=${APP_DB_USER}
Environment=APP_DB_PASS=${APP_DB_PASS}
Environment=HAPROXY_DB_BIND_PORT=${HAPROXY_DB_BIND_PORT}
Environment=NODEJS_PORT=${NODEJS_PORT}
Environment=CLUSTER_VIP=${CLUSTER_VIP}
ExecStart=/usr/local/bin/my-daemon.py
Restart=no

MemoryMax=25%
CPUQuota=30%
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable "${APP_SERVICE}.service" "${DAEMON_SERVICE}.service" 2>/dev/null || true

# Безопасный перезапуск: находим имя ресурса в Pacemaker (например, app-my-app)
restart_cluster_resource() {
  local service_name="$1"
  if command -v pcs >/dev/null 2>&1; then
    local rsc_id
    rsc_id=$(pcs status resources 2>/dev/null | grep -o "[^ ]*${service_name}[^ ]*" | head -n1 || true)
    if [[ -n "$rsc_id" ]]; then
      echo "[INFO] Ресурс $rsc_id управляется Pacemaker. Перезапуск через pcs..."
      pcs resource restart "$rsc_id" 2>/dev/null || true
      return
    fi
  fi
  systemctl restart "${service_name}.service" 2>/dev/null || true
}

restart_cluster_resource "${APP_SERVICE}"
restart_cluster_resource "${DAEMON_SERVICE}"

echo "====================================================================="
echo "[УСПЕХ] Развертывание завершено."
echo "Дашборд доступен по адресу: http://${MY_HOSTNAME}:${NODEJS_PORT}/"
echo "====================================================================="