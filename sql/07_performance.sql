-- 07_performance.sql
-- Rendimiento: ¿qué acelera de verdad las consultas sobre la tabla de
-- transacciones? Se mide, no se supone.
--
-- Cuatro consultas representativas, cada una en cuatro escenarios:
--   1. base       solo la llave primaria (trans_id)
--   2. btree      + índice B-tree en (account_id, trans_date)
--   3. brin       + índice BRIN en (trans_date)
--   4. partition  tabla particionada por año, con el mismo índice B-tree
--
-- Cada consulta se ejecuta una vez para calentar la caché y luego 5 veces; se
-- reporta la mediana. Además del tiempo se guardan las páginas leídas, que no
-- dependen de qué tan ocupada esté la máquina, y el tipo de acceso que eligió
-- el planificador.
--
-- La tabla particionada es una COPIA para el experimento (clean.trans_by_year);
-- los demás scripts siguen usando clean.trans.
--
-- Requisito: haber corrido 02_clean.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/07_performance.sql
-- Tarda alrededor de un minuto.
--
-- Para ver el plan de una consulta en un escenario:
--   SELECT plan_text FROM perf.plan WHERE scenario = '2. btree' AND query_id = 1;

\set ON_ERROR_STOP on
\pset pager off

DROP SCHEMA IF EXISTS perf CASCADE;
CREATE SCHEMA perf;

-- Punto de partida limpio: se quitan los índices de corridas anteriores
DROP INDEX IF EXISTS clean.trans_account_date_idx;
DROP INDEX IF EXISTS clean.trans_date_brin;
DROP TABLE IF EXISTS clean.trans_by_year;

------------------------------------------------------------------------------
-- Consultas de prueba. %s se reemplaza por la tabla de cada escenario.
------------------------------------------------------------------------------
CREATE TABLE perf.query (
    query_id     int  PRIMARY KEY,
    name         text NOT NULL,
    description  text NOT NULL,
    sql_template text NOT NULL
);

INSERT INTO perf.query VALUES
(1, 'una cuenta',
 'Todos los movimientos de una cuenta, en orden de fecha',
 format('SELECT trans_date, direction, amount, balance FROM %%s WHERE account_id = %s ORDER BY trans_date',
        (SELECT account_id FROM clean.trans GROUP BY account_id ORDER BY count(*) DESC, account_id LIMIT 1))),
(2, 'un mes',
 'Totales de un mes para todo el banco',
 'SELECT direction, count(*), sum(amount) FROM %s
  WHERE trans_date >= DATE ''1997-06-01'' AND trans_date < DATE ''1997-07-01''
  GROUP BY direction'),
(3, 'un año',
 'Saldo promedio mensual por cuenta durante un año',
 'SELECT account_id, date_trunc(''month'', trans_date) AS month, avg(balance)
  FROM %s
  WHERE trans_date >= DATE ''1998-01-01'' AND trans_date < DATE ''1999-01-01''
  GROUP BY 1, 2'),
(4, 'historial de préstamos',
 'Movimientos previos a cada préstamo (la unión que usa 04_loan_risk.sql)',
 'SELECT l.loan_id, count(*), min(t.balance)
  FROM clean.loan l
  JOIN %s t ON t.account_id = l.account_id AND t.trans_date < l.granted_date
  GROUP BY l.loan_id');

CREATE TABLE perf.result (
    scenario    text    NOT NULL,
    query_id    int     NOT NULL REFERENCES perf.query,
    run         int     NOT NULL,
    exec_ms     numeric NOT NULL,   -- tiempo de ejecución
    pages       bigint  NOT NULL,   -- páginas de 8 kB leídas
    access_path text,               -- cómo se leyó la tabla de transacciones
    relations   int,                -- cuántas tablas o particiones se tocaron
    PRIMARY KEY (scenario, query_id, run)
);

CREATE TABLE perf.plan (
    scenario  text NOT NULL,
    query_id  int  NOT NULL REFERENCES perf.query,
    plan_text text NOT NULL,
    PRIMARY KEY (scenario, query_id)
);

------------------------------------------------------------------------------
-- Ejecuta todas las consultas contra una tabla y guarda tiempos y planes.
-- Usa EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) y extrae las métricas del JSON.
------------------------------------------------------------------------------
CREATE PROCEDURE perf.benchmark(p_scenario text, p_table text, p_runs int DEFAULT 5)
LANGUAGE plpgsql AS $$
DECLARE
    q      record;
    r      record;
    v_sql  text;
    v_plan text;
    j      jsonb;
BEGIN
    DELETE FROM perf.result WHERE scenario = p_scenario;
    DELETE FROM perf.plan   WHERE scenario = p_scenario;

    FOR q IN SELECT * FROM perf.query ORDER BY query_id LOOP
        v_sql := format(q.sql_template, p_table);

        -- plan en texto, para leerlo después
        v_plan := '';
        FOR r IN EXECUTE 'EXPLAIN ' || v_sql LOOP
            v_plan := v_plan || r."QUERY PLAN" || E'\n';
        END LOOP;
        INSERT INTO perf.plan VALUES (p_scenario, q.query_id, v_plan);

        -- una ejecución para calentar la caché (no se guarda)
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || v_sql INTO j;

        FOR i IN 1..p_runs LOOP
            EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || v_sql INTO j;
            INSERT INTO perf.result
            SELECT p_scenario, q.query_id, i,
                   (j->0->>'Execution Time')::numeric,
                   coalesce((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0)
                 + coalesce((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0),
                   string_agg(DISTINCT n->>'Node Type', ' + ' ORDER BY n->>'Node Type'),
                   count(DISTINCT n->>'Relation Name')
            FROM jsonb_path_query(j, '$.** ? (exists(@."Relation Name"))') AS n
            WHERE n->>'Relation Name' LIKE 'trans%';
        END LOOP;
    END LOOP;
END;
$$;

CREATE VIEW perf.summary AS
SELECT r.scenario, q.query_id, q.name,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY r.exec_ms))::numeric, 2) AS median_ms,
       min(r.pages)       AS pages,
       min(r.access_path) AS access_path,
       min(r.relations)   AS relations
FROM perf.result r
JOIN perf.query q USING (query_id)
GROUP BY r.scenario, q.query_id, q.name;

------------------------------------------------------------------------------
-- Escenario 1: base
------------------------------------------------------------------------------
\echo
\echo 'Midiendo escenario 1 de 4: base...'
ANALYZE clean.trans;
CALL perf.benchmark('1. base', 'clean.trans');

------------------------------------------------------------------------------
-- Escenario 2: índice B-tree por cuenta y fecha
------------------------------------------------------------------------------
\echo 'Midiendo escenario 2 de 4: índice B-tree...'
CREATE INDEX trans_account_date_idx ON clean.trans (account_id, trans_date);
ANALYZE clean.trans;
CALL perf.benchmark('2. btree', 'clean.trans');

------------------------------------------------------------------------------
-- Escenario 3: índice BRIN por fecha
-- BRIN guarda solo el mínimo y máximo de cada bloque de páginas: ocupa muy
-- poco, pero solo sirve si las filas están físicamente ordenadas por fecha.
------------------------------------------------------------------------------
\echo 'Midiendo escenario 3 de 4: índice BRIN...'
CREATE INDEX trans_date_brin ON clean.trans USING brin (trans_date);
ANALYZE clean.trans;
CALL perf.benchmark('3. brin', 'clean.trans');

------------------------------------------------------------------------------
-- Escenario 4: tabla particionada por año
------------------------------------------------------------------------------
\echo 'Midiendo escenario 4 de 4: tabla particionada por año...'
CREATE TABLE clean.trans_by_year (
    LIKE clean.trans INCLUDING DEFAULTS INCLUDING CONSTRAINTS
) PARTITION BY RANGE (trans_date);

-- una partición por cada año presente en los datos
DO $$
DECLARE
    y int;
BEGIN
    FOR y IN SELECT generate_series(extract(year FROM min(trans_date))::int,
                                    extract(year FROM max(trans_date))::int)
             FROM clean.trans
    LOOP
        EXECUTE format(
            'CREATE TABLE clean.trans_y%s PARTITION OF clean.trans_by_year
             FOR VALUES FROM (%L) TO (%L)',
            y, make_date(y, 1, 1), make_date(y + 1, 1, 1));
    END LOOP;
END;
$$;

INSERT INTO clean.trans_by_year SELECT * FROM clean.trans;

-- en una tabla particionada la llave primaria debe incluir la columna de partición
ALTER TABLE clean.trans_by_year ADD PRIMARY KEY (trans_id, trans_date);
CREATE INDEX ON clean.trans_by_year (account_id, trans_date);
ANALYZE clean.trans_by_year;

CALL perf.benchmark('4. partition', 'clean.trans_by_year');

------------------------------------------------------------------------------
-- Resultados
------------------------------------------------------------------------------
\echo
\echo '=== 1. Tiempo de ejecución, mediana en milisegundos ==='
SELECT query_id, name,
       max(median_ms) FILTER (WHERE scenario = '1. base')      AS base,
       max(median_ms) FILTER (WHERE scenario = '2. btree')     AS btree,
       max(median_ms) FILTER (WHERE scenario = '3. brin')      AS brin,
       max(median_ms) FILTER (WHERE scenario = '4. partition') AS partition,
       round(max(median_ms) FILTER (WHERE scenario = '1. base')
             / nullif(min(median_ms), 0), 1)                   AS best_speedup
FROM perf.summary
GROUP BY query_id, name
ORDER BY query_id;

\echo
\echo '=== 2. Páginas leídas (8 kB cada una) ==='
SELECT query_id, name,
       max(pages) FILTER (WHERE scenario = '1. base')      AS base,
       max(pages) FILTER (WHERE scenario = '2. btree')     AS btree,
       max(pages) FILTER (WHERE scenario = '3. brin')      AS brin,
       max(pages) FILTER (WHERE scenario = '4. partition') AS partition
FROM perf.summary
GROUP BY query_id, name
ORDER BY query_id;

\echo
\echo '=== 3. Cómo leyó el planificador la tabla de transacciones ==='
SELECT query_id, name, scenario, access_path, relations AS tables_touched
FROM perf.summary
ORDER BY query_id, scenario;

\echo
\echo '=== 4. Lo que cuesta: espacio en disco ==='
SELECT v.object, pg_size_pretty(v.bytes) AS size
FROM (VALUES
    ('1. clean.trans (tabla)',
        pg_relation_size('clean.trans')),
    ('2. llave primaria (trans_id)',
        pg_relation_size('clean.trans_pkey')),
    ('3. índice B-tree (account_id, trans_date)',
        pg_relation_size('clean.trans_account_date_idx')),
    ('4. índice BRIN (trans_date)',
        pg_relation_size('clean.trans_date_brin')),
    ('5. copia particionada, con sus índices',
        (SELECT sum(pg_total_relation_size(relid))::bigint
         FROM pg_partition_tree('clean.trans_by_year')))
) AS v(object, bytes)
ORDER BY v.object;

\echo
\echo '=== 5. ¿Las filas están ordenadas por fecha en el disco? (1 = orden perfecto) ==='
SELECT attname AS column_name, round(correlation::numeric, 3) AS physical_correlation
FROM pg_stats
WHERE schemaname = 'clean' AND tablename = 'trans'
  AND attname IN ('trans_date', 'account_id', 'trans_id')
ORDER BY attname;