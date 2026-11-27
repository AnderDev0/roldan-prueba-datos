-- modelo logistica (postgres 16)

CREATE SCHEMA IF NOT EXISTS logistica;
SET search_path TO logistica;

-- catalogos
CREATE TABLE estado (
    codigo          VARCHAR(20)  PRIMARY KEY,
    nombre          VARCHAR(50)  NOT NULL UNIQUE,      -- el que sale en reportes
    es_final        BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE tipo_carga (
    codigo                  VARCHAR(30)  PRIMARY KEY,
    nombre                  VARCHAR(60)  NOT NULL UNIQUE,
    requiere_refrigeracion  BOOLEAN      NOT NULL DEFAULT FALSE,
    es_peligrosa            BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE puerto (
    codigo_locode   CHAR(5)      PRIMARY KEY,          -- UN/LOCODE
    nombre          VARCHAR(80)  NOT NULL,
    pais_iso        CHAR(2)      GENERATED ALWAYS AS (LEFT(codigo_locode, 2)) STORED
);

CREATE TABLE naviera (
    codigo_bic      CHAR(4)      PRIMARY KEY,          -- MRKU, MSCU...
    nombre          VARCHAR(80)  NOT NULL
);

CREATE TABLE transportista (
    id_transportista  VARCHAR(10)   PRIMARY KEY,
    razon_social      VARCHAR(120)  NOT NULL,
    email_contacto    VARCHAR(120)  NOT NULL
        CHECK (email_contacto ~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$')
);

CREATE TABLE coordinador (
    id_coordinador  SMALLINT     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_completo VARCHAR(100) NOT NULL
);

CREATE TABLE bodega (
    id_bodega       SMALLINT     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          VARCHAR(100) NOT NULL UNIQUE,
    ciudad          VARCHAR(60)  NOT NULL
);

CREATE TABLE contenedor (
    numero          CHAR(11)     PRIMARY KEY
        CHECK (numero ~ '^[A-Z]{3}[UJZ][0-9]{7}$'),
    codigo_bic      CHAR(4)      GENERATED ALWAYS AS (LEFT(numero, 4)) STORED
        REFERENCES naviera (codigo_bic)
);

-- operaciones
CREATE TABLE operacion (
    id_operacion        VARCHAR(20)    PRIMARY KEY
        CHECK (id_operacion ~ '^OP-[0-9]{4}-[0-9]{3,}$'),
    numero_contenedor   CHAR(11)       NOT NULL REFERENCES contenedor (numero),
    codigo_tipo_carga   VARCHAR(30)    NOT NULL REFERENCES tipo_carga (codigo),
    peso_kg             NUMERIC(12,2)  NOT NULL CHECK (peso_kg > 0),
    puerto_origen       CHAR(5)        NOT NULL REFERENCES puerto (codigo_locode),
    puerto_destino      CHAR(5)        NOT NULL REFERENCES puerto (codigo_locode),
    id_transportista    VARCHAR(10)    NOT NULL REFERENCES transportista (id_transportista),
    id_coordinador      SMALLINT       NOT NULL REFERENCES coordinador (id_coordinador),
    id_bodega_destino   SMALLINT       NOT NULL REFERENCES bodega (id_bodega),
    fecha_arribo        DATE           NOT NULL,
    estado_actual       VARCHAR(20)    NOT NULL REFERENCES estado (codigo),
    costo_usd           NUMERIC(12,2)  NOT NULL CHECK (costo_usd > 0),
    creado_en           TIMESTAMPTZ    NOT NULL DEFAULT now(),
    actualizado_en      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT ck_origen_distinto_destino CHECK (puerto_origen <> puerto_destino)
);

-- historial de estados
CREATE TABLE historial_estado (
    id_evento        BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_operacion     VARCHAR(20)   NOT NULL REFERENCES operacion (id_operacion),
    estado_anterior  VARCHAR(20)   REFERENCES estado (codigo),   -- null en el primer evento
    estado_nuevo     VARCHAR(20)   NOT NULL REFERENCES estado (codigo),
    fecha_evento     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    usuario          VARCHAR(60)   NOT NULL DEFAULT current_user,
    observacion      TEXT
);

-- registros que no pasan validacion
CREATE TABLE operacion_rechazada (
    id_rechazo      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_operacion    VARCHAR(20),
    registro        JSONB        NOT NULL,
    motivos         TEXT[]       NOT NULL,
    rechazado_en    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- indices de las FK, postgres no los crea solo
CREATE INDEX ix_operacion_estado        ON operacion (estado_actual);
CREATE INDEX ix_operacion_origen        ON operacion (puerto_origen);
CREATE INDEX ix_operacion_destino       ON operacion (puerto_destino);
CREATE INDEX ix_operacion_transportista ON operacion (id_transportista);
CREATE INDEX ix_operacion_fecha_arribo  ON operacion (fecha_arribo);
CREATE INDEX ix_historial_operacion     ON historial_estado (id_operacion, fecha_evento);
