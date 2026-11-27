-- catalogos base, los defino aqui porque en el csv vienen sucios
SET search_path TO logistica;

INSERT INTO estado (codigo, nombre, es_final) VALUES
    ('EN_TRANSITO', 'EN TRANSITO', FALSE),
    ('ADUANA',      'ADUANA',      FALSE),
    ('RETRASADO',   'RETRASADO',   FALSE),
    ('ENTREGADO',   'ENTREGADO',   TRUE);

INSERT INTO tipo_carga (codigo, nombre, requiere_refrigeracion, es_peligrosa) VALUES
    ('REFRIGERADO',        'Refrigerado',          TRUE,  FALSE),
    ('GENERAL',            'Carga General',        FALSE, FALSE),
    ('PELIGROSO_QUIMICOS', 'Peligroso (Quimicos)', FALSE, TRUE);

INSERT INTO puerto (codigo_locode, nombre) VALUES
    ('NLRTM', 'Rotterdam'),
    ('CNSHA', 'Shanghai'),
    ('USHOU', 'Houston'),
    ('PAMIT', 'Manzanillo'),      -- el de Panama
    ('COBUN', 'Buenaventura'),
    ('COCTG', 'Cartagena'),
    ('COTCO', 'Tumaco');

INSERT INTO naviera (codigo_bic, nombre) VALUES
    ('MRKU', 'Maersk'),
    ('MSCU', 'MSC'),
    ('CMAU', 'CMA CGM'),
    ('HPLU', 'Hapag-Lloyd');

INSERT INTO bodega (nombre, ciudad) VALUES
    ('Bodega Principal Cali',      'Cali'),
    ('Centro Distribucion Bogota', 'Bogota'),
    ('Terminal Maritimo Manga',    'Cartagena');
