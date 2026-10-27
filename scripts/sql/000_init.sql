-- Инициализация схемы в правильном порядке
\i /docker-entrypoint-initdb.d/schema.sql
\i /docker-entrypoint-initdb.d/raw.sql
\i /docker-entrypoint-initdb.d/templates.sql
\i /docker-entrypoint-initdb.d/seed_test.sql
