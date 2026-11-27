-- carga del csv al modelo
-- correr desde la raiz del repo: psql -d <bd> -f fase1_modelo/03_carga_desde_csv.sql
SET search_path TO logistica;

BEGIN;

CREATE TEMP TABLE stg_operaciones (
    id_operacion TEXT, contenedor_num TEXT, tipo_carga TEXT, peso_kg TEXT,
    puerto_origen TEXT, puerto_destino TEXT, id_transportista TEXT,
    nombre_transportista TEXT, contacto_transportista TEXT, fecha_arribo TEXT,
    estado_actual TEXT, coordinador_asignado TEXT, bodega_destino TEXT, costo_usd TEXT
) ON COMMIT DROP;

\copy stg_operaciones FROM 'data/raw/operaciones_logisticas.csv' WITH (FORMAT csv, HEADER true, NULL 'NULL')

-- validacion contra catalogos
CREATE TEMP TABLE stg_validada ON COMMIT DROP AS
SELECT s.*,
       tc.codigo                                     AS cod_tipo,
       po.codigo_locode                              AS cod_origen,
       pd.codigo_locode                              AS cod_destino,
       e.codigo                                      AS cod_estado,
       b.id_bodega,
       ARRAY_REMOVE(ARRAY[
           CASE WHEN s.peso_kg::NUMERIC <= 0              THEN 'peso_kg debe ser mayor que 0' END,
           CASE WHEN s.costo_usd::NUMERIC <= 0            THEN 'costo_usd debe ser mayor que 0' END,
           CASE WHEN e.codigo IS NULL                     THEN 'estado no reconocido: ' || s.estado_actual END,
           CASE WHEN s.contacto_transportista IS NULL     THEN 'transportista sin contacto' END,
           CASE WHEN tc.codigo IS NULL                    THEN 'tipo de carga no reconocido' END,
           CASE WHEN po.codigo_locode IS NULL
                  OR pd.codigo_locode IS NULL             THEN 'puerto no reconocido' END,
           CASE WHEN b.id_bodega IS NULL                  THEN 'bodega no reconocida' END,
           CASE WHEN s.contenedor_num !~ '^[A-Z]{3}[UJZ][0-9]{7}$'
                  OR n.codigo_bic IS NULL                 THEN 'contenedor con formato o naviera inválida' END
       ], NULL)                                      AS motivos
FROM stg_operaciones s
LEFT JOIN tipo_carga tc ON UPPER(tc.nombre) = UPPER(TRIM(s.tipo_carga))
LEFT JOIN puerto po     ON UPPER(po.nombre) = UPPER(TRIM(s.puerto_origen))
LEFT JOIN puerto pd     ON UPPER(pd.nombre) = UPPER(TRIM(s.puerto_destino))
LEFT JOIN estado e      ON e.codigo = REPLACE(UPPER(TRIM(s.estado_actual)), ' ', '_')
LEFT JOIN bodega b      ON UPPER(b.nombre) = UPPER(TRIM(s.bodega_destino))
LEFT JOIN naviera n     ON n.codigo_bic = LEFT(s.contenedor_num, 4);

-- rechazados
INSERT INTO operacion_rechazada (id_operacion, registro, motivos)
SELECT id_operacion,
       to_jsonb(v) - 'cod_tipo' - 'cod_origen' - 'cod_destino' - 'cod_estado' - 'id_bodega' - 'motivos',
       motivos
FROM stg_validada v
WHERE cardinality(motivos) > 0;

-- maestros que si vienen en el archivo
INSERT INTO transportista (id_transportista, razon_social, email_contacto)
SELECT DISTINCT TRIM(id_transportista), TRIM(nombre_transportista), LOWER(TRIM(contacto_transportista))
FROM stg_validada WHERE cardinality(motivos) = 0
ON CONFLICT (id_transportista) DO NOTHING;

INSERT INTO coordinador (nombre_completo)
SELECT DISTINCT TRIM(v.coordinador_asignado)
FROM stg_validada v
WHERE cardinality(v.motivos) = 0
  AND NOT EXISTS (SELECT 1 FROM coordinador c WHERE c.nombre_completo = TRIM(v.coordinador_asignado));

INSERT INTO contenedor (numero)
SELECT DISTINCT TRIM(contenedor_num)
FROM stg_validada WHERE cardinality(motivos) = 0
ON CONFLICT (numero) DO NOTHING;

-- operaciones
INSERT INTO operacion (id_operacion, numero_contenedor, codigo_tipo_carga, peso_kg,
                       puerto_origen, puerto_destino, id_transportista, id_coordinador,
                       id_bodega_destino, fecha_arribo, estado_actual, costo_usd)
SELECT TRIM(v.id_operacion), TRIM(v.contenedor_num), v.cod_tipo, v.peso_kg::NUMERIC,
       v.cod_origen, v.cod_destino, TRIM(v.id_transportista), c.id_coordinador,
       v.id_bodega, v.fecha_arribo::DATE, v.cod_estado, v.costo_usd::NUMERIC
FROM stg_validada v
JOIN coordinador c ON c.nombre_completo = TRIM(v.coordinador_asignado)
WHERE cardinality(v.motivos) = 0;

-- primer evento del historial
INSERT INTO historial_estado (id_operacion, estado_anterior, estado_nuevo, observacion)
SELECT TRIM(v.id_operacion), NULL, v.cod_estado, 'Carga inicial desde CSV'
FROM stg_validada v
WHERE cardinality(v.motivos) = 0;

COMMIT;
