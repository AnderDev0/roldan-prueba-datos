-- cambio de estado + historial en una sola transaccion
SET search_path TO logistica;

CREATE OR REPLACE FUNCTION cambiar_estado(
    p_operacion    VARCHAR,
    p_estado_nuevo VARCHAR,
    p_observacion  TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_estado_anterior VARCHAR(20);
    v_es_final        BOOLEAN;
BEGIN
    -- bloquea la fila para que nadie la cambie al mismo tiempo
    SELECT o.estado_actual, e.es_final INTO v_estado_anterior, v_es_final
    FROM operacion o
    JOIN estado e ON e.codigo = o.estado_actual
    WHERE o.id_operacion = p_operacion
    FOR UPDATE OF o;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'la operacion % no existe', p_operacion;
    END IF;

    IF v_es_final THEN
        RAISE EXCEPTION 'la operacion % ya esta en % y no se puede cambiar', p_operacion, v_estado_anterior;
    END IF;

    UPDATE operacion
    SET estado_actual = p_estado_nuevo, actualizado_en = now()
    WHERE id_operacion = p_operacion;

    INSERT INTO historial_estado (id_operacion, estado_anterior, estado_nuevo, observacion)
    VALUES (p_operacion, v_estado_anterior, p_estado_nuevo, p_observacion);
END;
$$;


\echo
\echo '=== caso 1: todo sale bien ==='
BEGIN;
SELECT cambiar_estado('OP-2026-002', 'ADUANA', 'llego a Buenaventura');
COMMIT;

SELECT id_operacion, estado_anterior, estado_nuevo, observacion
FROM historial_estado WHERE id_operacion = 'OP-2026-002' ORDER BY id_evento;


\echo
\echo '=== caso 2: el paso 1 funciona pero el paso 2 falla ==='
BEGIN;
UPDATE operacion SET estado_actual = 'ENTREGADO' WHERE id_operacion = 'OP-2026-004';
INSERT INTO historial_estado (id_operacion, estado_anterior, estado_nuevo)
VALUES ('OP-2026-004', 'RETRASAD', 'ENTREGADO');   -- estado mal escrito, la FK lo rechaza
ROLLBACK;

SELECT id_operacion, estado_actual FROM operacion WHERE id_operacion = 'OP-2026-004';


\echo
\echo '=== caso 3: intentar reabrir una operacion ya entregada ==='
BEGIN;
SELECT cambiar_estado('OP-2026-001', 'EN_TRANSITO', 'reapertura');
ROLLBACK;

SELECT o.id_operacion, o.estado_actual, COUNT(h.id_evento) AS eventos_historial
FROM operacion o
JOIN historial_estado h USING (id_operacion)
WHERE o.id_operacion = 'OP-2026-001'
GROUP BY o.id_operacion, o.estado_actual;
