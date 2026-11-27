-- optimizacion de consultas sobre el historial logistico
-- tabla de prueba con 3 millones de eventos (~3 anios de historia)
SET search_path TO logistica;

DROP TABLE IF EXISTS hist_demo, hist_demo_part CASCADE;

CREATE TABLE hist_demo (
    id_evento     BIGINT GENERATED ALWAYS AS IDENTITY,
    id_operacion  VARCHAR(20) NOT NULL,
    estado_nuevo  VARCHAR(20) NOT NULL,
    fecha_evento  TIMESTAMPTZ NOT NULL,
    usuario       VARCHAR(60) NOT NULL,
    observacion   TEXT
);

INSERT INTO hist_demo (id_operacion, estado_nuevo, fecha_evento, usuario, observacion)
SELECT 'OP-' || lpad((g % 300000)::text, 6, '0'),
       (ARRAY['EN_TRANSITO', 'ADUANA', 'RETRASADO', 'ENTREGADO'])[1 + g % 4],
       timestamptz '2024-01-01' + g * interval '30 seconds',
       'coordinador_' || (g % 25),
       'evento generado'
FROM generate_series(1, 3000000) g;

ANALYZE hist_demo;


\echo
\echo '=== 1a. historial de una operacion SIN indice ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM hist_demo WHERE id_operacion = 'OP-012345' ORDER BY fecha_evento DESC;

CREATE INDEX ix_hist_demo_operacion ON hist_demo (id_operacion, fecha_evento DESC);

\echo
\echo '=== 1b. la misma consulta CON indice compuesto (operacion, fecha) ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM hist_demo WHERE id_operacion = 'OP-012345' ORDER BY fecha_evento DESC;


CREATE INDEX ix_hist_demo_fecha_brin ON hist_demo USING brin (fecha_evento);

\echo
\echo '=== 2a. eventos de agosto 2026 con funcion sobre la columna (no usa el indice) ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT estado_nuevo, count(*) FROM hist_demo
WHERE date_trunc('month', fecha_evento) = '2026-08-01'
GROUP BY estado_nuevo;

\echo
\echo '=== 2b. la misma consulta escrita como rango (usa el indice BRIN) ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT estado_nuevo, count(*) FROM hist_demo
WHERE fecha_evento >= '2026-08-01' AND fecha_evento < '2026-09-01'
GROUP BY estado_nuevo;

\echo
\echo '=== tamano de la tabla y de los indices ==='
SELECT relname AS objeto, pg_size_pretty(pg_relation_size(oid)) AS tamano
FROM pg_class
WHERE relname IN ('hist_demo', 'ix_hist_demo_operacion', 'ix_hist_demo_fecha_brin')
ORDER BY pg_relation_size(oid) DESC;


-- particion por mes: cada mes es una tabla fisica distinta
CREATE TABLE hist_demo_part (LIKE hist_demo) PARTITION BY RANGE (fecha_evento);

DO $$
DECLARE m DATE;
BEGIN
    FOR m IN SELECT generate_series(DATE '2024-01-01', DATE '2026-12-01', INTERVAL '1 month')::DATE LOOP
        EXECUTE format(
            'CREATE TABLE hist_demo_p%s PARTITION OF hist_demo_part FOR VALUES FROM (%L) TO (%L)',
            to_char(m, 'YYYYMM'), m, m + INTERVAL '1 month');
    END LOOP;
END $$;

INSERT INTO hist_demo_part SELECT * FROM hist_demo;
ANALYZE hist_demo_part;

\echo
\echo '=== 3. agosto 2026 sobre la tabla particionada (solo lee la particion de ese mes) ==='
EXPLAIN (ANALYZE, COSTS OFF)
SELECT estado_nuevo, count(*) FROM hist_demo_part
WHERE fecha_evento >= '2026-08-01' AND fecha_evento < '2026-09-01'
GROUP BY estado_nuevo;
