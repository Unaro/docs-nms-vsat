import postgres from "postgres";

const sql = postgres("postgresql://nms_user:nms_test_pass@localhost:5433/nms_monitoring");

async function run() {
  console.log("=== Проверка подключения к тестовой БД ===");
  const [version] = await sql`SELECT version()`;
  console.log("PostgreSQL Version:", version.version.split(" on ")[0]);

  const tables = await sql`
    SELECT table_name FROM information_schema.tables 
    WHERE table_schema = 'public' 
    ORDER BY table_name;
  `;
  console.log("Таблицы в схеме:", tables.map(t => t.table_name).join(", "));

  const nodes = await sql`
    SELECT n.id, n.name, host(n.ip_address) as ip, s.status 
    FROM monitored_nodes n 
    LEFT JOIN node_current_state s ON n.id = s.node_id;
  `;
  console.log("\nТестовые узлы:", nodes);

  const jobs = await sql`
    SELECT job_name, collector, is_vital, poll_interval_sec 
    FROM poll_jobs;
  `;
  console.log("\nТестовые задачи poll_jobs:", jobs);

  await sql.end();
  console.log("\nВсе подключения и схемы валидны!");
}

run().catch(err => {
  console.error("Ошибка теста:", err);
  process.exit(1);
});
