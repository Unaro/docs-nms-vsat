#!/usr/bin/env python3
import asyncio
import ipaddress
import json
import logging
import os
import signal
import socket
import sys
import asyncpg

from nms_core.icmp import IcmpCollector
from nms_core.snmp import SnmpClient

# Добавьте вспомогательную функцию в начало файла (после импортов):

def safe_load_json(val: any) -> dict[str, any]:
    """
    Безопасное разворачивание JSON: обрабатывает dict, str, double-encoded str, None.
    Гарантированно возвращает Python dict.
    """
    if val is None:
        return {}
    while isinstance(val, str):
        try:
            val = json.loads(val)
        except (json.JSONDecodeError, TypeError):
            break
    return val if isinstance(val, dict) else {}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s]: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("nms-worker")

WORKER_ID = os.getenv("WORKER_ID", f"{socket.gethostname()}-{os.getpid()}")
DB_HOST = os.getenv("DB_HOST", "127.0.0.1")
DB_PORT = int(os.getenv("HAPROXY_DB_BIND_PORT", os.getenv("DB_PORT", "5000")))
DB_USER = os.getenv("APP_DB_USER", "app_user")
DB_PASS = os.getenv("APP_DB_PASS", "AppSecretPass!")
DB_NAME = os.getenv("APP_DB_NAME", "postgres")

class NmsEngine:
    def __init__(self):
        self.pool: asyncpg.Pool = None
        self.running = False
        self.adhoc_event = asyncio.Event()

    async def init_pool(self):
        self.pool = await asyncpg.create_pool(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=DB_PASS,
            database=DB_NAME,
            min_size=3,
            max_size=10,
        )

    # ------------------------------------------------------------------------
    # 1. ОБРАБОТКА РАЗОВЫХ ЗАДАЧ (ADHOC TASKS)
    # ------------------------------------------------------------------------

    def on_adhoc_notify(self, conn, pid, channel, payload):
        self.adhoc_event.set()

    async def listen_adhoc_notifications(self):
        """Слушатель канала уведомлений о появлении adhoc-задач."""
        while self.running:
            try:
                conn = await self.pool.acquire()
                await conn.add_listener("adhoc_task_created", self.on_adhoc_notify)
                logger.info("Listening for adhoc_task_created notifications...")
                while self.running:
                    await asyncio.sleep(60)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.warning(f"Adhoc listener reconnecting due to: {e}")
                await asyncio.sleep(2)
            finally:
                if conn:
                    await self.pool.release(conn)

    async def process_adhoc_tasks_loop(self):
        """Воркер выполнения adhoc-задач через FOR UPDATE SKIP LOCKED."""
        while self.running:
            try:
                task = await self.fetch_adhoc_task()
                if not task:
                    try:
                        await asyncio.wait_for(self.adhoc_event.wait(), timeout=1.0)
                        self.adhoc_event.clear()
                    except asyncio.TimeoutError:
                        pass
                    continue

                asyncio.create_task(self.execute_adhoc_task(task))
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Error in adhoc task loop: {e}", exc_info=True)
                await asyncio.sleep(1.0)

    async def fetch_adhoc_task(self):
        query = """
            WITH target_task AS (
                SELECT id FROM adhoc_tasks
                WHERE status = 'pending'
                ORDER BY created_at ASC
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE adhoc_tasks t
            SET status = 'running', locked_by = $1, updated_at = now()
            FROM target_task
            WHERE t.id = target_task.id
            RETURNING t.id, t.task_type, t.target_host, t.payload;
        """
        async with self.pool.acquire() as conn:
            return await conn.fetchrow(query, WORKER_ID)

    async def execute_adhoc_task(self, task):
        t_id = task["id"]
        t_type = task["task_type"]
        host = task["target_host"]
        payload = safe_load_json(task["payload"])
        
        
        logger.info(f"Processing adhoc task [{t_type}] #{t_id} for {host}")
        result = {}
        error = None

        try:
            if t_type == "probe":
                port = payload.get("port", 161)
                comm = payload.get("community", "public")
                icmp_res = await IcmpCollector.ping(host)
                snmp_res = await SnmpClient.get_scalars(
                    host, port, comm,
                    {"sys_descr": "1.3.6.1.2.1.1.1.0", "sys_name": "1.3.6.1.2.1.1.5.0"}
                )
                result = {
                    "success": icmp_res["ok"] or snmp_res["ok"],
                    "icmp": icmp_res,
                    "snmp": snmp_res
                }

            elif t_type == "inspect":
                node_id = payload.get("node_id")
                port = payload.get("port", 161)
                comm = payload.get("community", "public")

                icmp_task = asyncio.create_task(IcmpCollector.ping(host))
                snmp_task = asyncio.create_task(SnmpClient.deep_inspect(host, port, comm))
                icmp_res, snmp_res = await asyncio.gather(icmp_task, snmp_task)

                result = {
                    "success": icmp_res["ok"] or snmp_res["ok"],
                    "icmp": icmp_res,
                    "snmp": snmp_res
                }

                # Обновляем оперативное состояние узла
                if node_id:
                    async with self.pool.acquire() as conn:
                        status = "healthy" if snmp_res["ok"] else ("degraded" if icmp_res["ok"] else "down")
                        await conn.execute("""
                            INSERT INTO node_current_state (
                                node_id, status, latency_ms, metrics, error_message, last_polled_by, updated_at
                            )
                            VALUES ($1, $2, $3, $4::jsonb, $5, $6, now())
                            ON CONFLICT (node_id) DO UPDATE SET
                                status = EXCLUDED.status,
                                latency_ms = EXCLUDED.latency_ms,
                                metrics = node_current_state.metrics || EXCLUDED.metrics,
                                last_polled_by = EXCLUDED.last_polled_by,
                                updated_at = EXCLUDED.updated_at
                        """, node_id, status, icmp_res.get("rtt_ms"), json.dumps(snmp_res), snmp_res.get("error"), WORKER_ID)

            elif t_type == "discovery":
                cidr = payload.get("cidr", "192.168.122.0/24")
                net = ipaddress.ip_network(cidr, strict=False)
                hosts = [str(ip) for ip in net.hosts()]

                async with self.pool.acquire() as conn:
                    creds = [dict(r) for r in await conn.fetch("SELECT id, params FROM credential_profiles")]
                    templates = [dict(r) for r in await conn.fetch("SELECT id, sys_object_id_pattern FROM metric_templates")]

                sem = asyncio.Semaphore(50)
                async def ping_sweep(ip):
                    async with sem:
                        return ip, (await IcmpCollector.ping(ip, packets=1, timeout_ms=800))["ok"]

                alive_hosts = [ip for ip, ok in await asyncio.gather(*(ping_sweep(ip) for ip in hosts)) if ok]

                for ip in alive_hosts:
                    for c in creds:
                        p = json.loads(c["params"]) if isinstance(c["params"], str) else c["params"]
                        snmp_info = await SnmpClient.get_scalars(
                            ip, 161, p.get("community", "public"),
                            {"descr": "1.3.6.1.2.1.1.1.0", "obj_id": "1.3.6.1.2.1.1.2.0", "name": "1.3.6.1.2.1.1.5.0"}
                        )
                        if snmp_info["ok"]:
                            descr = snmp_info["data"].get("descr", "")
                            vendor = "Generic"
                            if "cisco" in descr.lower(): vendor = "Cisco Systems"
                            elif "linux" in descr.lower(): vendor = "Linux Host"
                            elif "mikrotik" in descr.lower(): vendor = "MikroTik"

                            obj_id = snmp_info["data"].get("obj_id", "")
                            sugg_tpl = next((t["id"] for t in templates if t["sys_object_id_pattern"] and t["sys_object_id_pattern"].rstrip("*") in obj_id), None)

                            async with self.pool.acquire() as conn:
                                await conn.execute("""
                                    INSERT INTO discovered_nodes (
                                        ip_address, hostname, vendor, snmp_sys_object_id, 
                                        suggested_template_id, matched_credential_id, status, discovered_at
                                    ) VALUES ($1, $2, $3, $4, $5, $6, 'new', now())
                                    ON CONFLICT (ip_address) DO UPDATE SET
                                        hostname = EXCLUDED.hostname, vendor = EXCLUDED.vendor,
                                        snmp_sys_object_id = EXCLUDED.snmp_sys_object_id,
                                        suggested_template_id = EXCLUDED.suggested_template_id,
                                        matched_credential_id = EXCLUDED.matched_credential_id,
                                        discovered_at = now()
                                """, ip, snmp_info["data"].get("name"), vendor, obj_id, sugg_tpl, c["id"])
                            break

                result = {"alive_count": len(alive_hosts)}

        except Exception as exc:
            error = str(exc)
            logger.error(f"Adhoc task #{t_id} failed: {exc}", exc_info=True)

        async with self.pool.acquire() as conn:
            await conn.execute("""
                UPDATE adhoc_tasks
                SET status = $2, result = $3::jsonb, error_message = $4, updated_at = now()
                WHERE id = $1
            """, t_id, "failed" if error else "completed", json.dumps(result), error)

            await conn.execute("SELECT pg_notify('adhoc_task_event', $1)", json.dumps({"task_id": str(t_id)}))
            if t_type == "discovery":
                await conn.execute("SELECT pg_notify('discovery_update', '{}')")

    # ------------------------------------------------------------------------
    # 2. РЕГУЛЯРНЫЙ ОПРОС (POLL JOBS)
    # ------------------------------------------------------------------------

    async def poll_jobs_loop(self):
        while self.running:
            try:
                jobs = await self.fetch_poll_jobs()
                if not jobs:
                    await asyncio.sleep(1.0)
                    continue

                await asyncio.gather(*(self.execute_poll_job(job) for job in jobs))
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Error in poll loop: {e}", exc_info=True)
                await asyncio.sleep(2.0)

    async def fetch_poll_jobs(self):
        query = """
        WITH available_tasks AS (
            SELECT j.id, j.credential_id, n.capabilities AS node_capabilities
            FROM poll_jobs j
            JOIN monitored_nodes n ON j.node_id = n.id
            WHERE j.next_poll_at <= now() 
              AND (j.locked_until IS NULL OR j.locked_until < now())
              AND (n.status = 'online' OR j.is_vital = true)
            ORDER BY j.is_vital DESC, j.next_poll_at ASC
            LIMIT 10
            FOR UPDATE OF j SKIP LOCKED
        )
        UPDATE poll_jobs j
        SET locked_by = $1, locked_until = now() + interval '15 seconds'
        FROM available_tasks a
        LEFT JOIN credential_profiles c ON a.credential_id = c.id
        WHERE j.id = a.id
        RETURNING 
            j.id, j.node_id, j.job_name, j.collector, j.is_vital,
            j.host, j.port, j.job_payload, j.poll_interval_sec,
            c.params AS cred_params;
        """
        async with self.pool.acquire() as conn:
            return await conn.fetch(query, WORKER_ID)

    async def execute_poll_job(self, job):
        j_id = job["id"]
        node_id = job["node_id"]
        collector = job["collector"]
        is_vital = job["is_vital"]
        host = job["host"]
        port = job["port"]
        interval = job["poll_interval_sec"]

        payload = safe_load_json(job["job_payload"]) if isinstance(job["job_payload"], str) else job["job_payload"]
        cred_params = safe_load_json(job["cred_params"]) if isinstance(job["cred_params"], str) else (job["cred_params"] or {})

        if collector == "icmp":
            res = await IcmpCollector.ping(host, payload.get("packets", 2), payload.get("timeout_ms", 1000))
            is_ok = res["ok"]
            latency = res["rtt_ms"]
            metrics = {"ping_rtt": latency} if latency else {}
            err = res["error"]
        elif collector == "snmp":
            oids = {item["key"]: item["oid"] for item in payload.get("oids", [])}
            comm = cred_params.get("community", "public")
            res = await SnmpClient.get_scalars(host, port, comm, oids, float(payload.get("timeout_ms", 2000)/1000))
            is_ok = res["ok"]
            latency = None
            metrics = res["data"]
            err = res["error"]
        else:
            is_ok, latency, metrics, err = False, None, {}, f"Unknown collector: {collector}"

        if is_vital:
            node_status = "online" if is_ok else "offline"
            current_status = "healthy" if is_ok else "down"
        else:
            node_status = None
            current_status = "healthy" if is_ok else "degraded"

        async with self.pool.acquire() as conn:
            async with conn.transaction():
                if is_vital:
                    await conn.execute("UPDATE monitored_nodes SET status = $1 WHERE id = $2", node_status, node_id)

                await conn.execute("""
                    INSERT INTO node_current_state (
                        node_id, status, latency_ms, metrics, error_message, last_polled_by, updated_at
                    )
                    VALUES ($1, $2, $3, $4::jsonb, $5, $6, now())
                    ON CONFLICT (node_id) DO UPDATE SET
                        status = CASE 
                            WHEN $7 = true THEN EXCLUDED.status
                            WHEN EXCLUDED.status = 'degraded' THEN 'degraded'
                            ELSE node_current_state.status
                        END,
                        latency_ms = COALESCE(EXCLUDED.latency_ms, node_current_state.latency_ms),
                        metrics = node_current_state.metrics || EXCLUDED.metrics,
                        error_message = EXCLUDED.error_message,
                        last_polled_by = EXCLUDED.last_polled_by,
                        updated_at = EXCLUDED.updated_at
                """, node_id, current_status, latency, json.dumps(metrics), err, WORKER_ID, is_vital)

                await conn.execute("""
                    UPDATE poll_jobs
                    SET locked_by = NULL, locked_until = NULL, next_poll_at = now() + make_interval(secs => $2)
                    WHERE id = $1
                """, j_id, interval)

    async def run(self):
        self.running = True
        await self.init_pool()
        logger.info(f"Worker {WORKER_ID} running both Poll and Adhoc engines.")

        await asyncio.gather(
            self.listen_adhoc_notifications(),
            self.process_adhoc_tasks_loop(),
            self.poll_jobs_loop(),
        )

    def stop(self):
        self.running = False

def main():
    daemon = NmsEngine()
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, daemon.stop)
    try:
        loop.run_until_complete(daemon.run())
    finally:
        loop.close()

if __name__ == "__main__":
    main()