from datetime import date
from pathlib import Path

import boto3
import polars as pl
import pytest
from moto import mock_aws

import etl_operaciones as etl

CSV = Path(__file__).parents[1] / "data/raw/operaciones_logisticas.csv"
FECHA = date(2026, 11, 26)


@pytest.fixture
def df():
    return etl.validar(etl.limpiar(etl.leer_csv(CSV)), FECHA)


def test_op006_queda_rechazada_con_sus_motivos(df):
    fila = df.filter(pl.col("id_operacion") == "OP-2026-006").row(0, named=True)
    assert len(fila["errores"]) == 4
    assert fila["puntaje_calidad"] == 0


def test_cinco_operaciones_validas(df):
    assert df.filter(pl.col("errores").list.len() == 0).height == 5


def test_texto_en_mayusculas_y_email_en_minusculas(df):
    fila = df.filter(pl.col("id_operacion") == "OP-2026-002").row(0, named=True)
    assert fila["estado_actual"] == "EN TRANSITO"
    assert fila["contacto_transportista"] == "contacto@roldanexp.com"


def test_puntaje_siempre_entre_0_y_100(df):
    assert df["puntaje_calidad"].is_between(0, 100).all()


def test_digito_control_iso6346():
    assert etl.digito_control_iso6346("CSQU3054383")
    assert not etl.digito_control_iso6346("MRKU9876543")


def test_carga_a_s3(tmp_path, monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    with mock_aws():
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket="bucket-prueba")
        etl.ejecutar(CSV, tmp_path / "salida", bucket="bucket-prueba", fecha_proceso=FECHA)
        llaves = {o["Key"] for o in s3.list_objects_v2(Bucket="bucket-prueba")["Contents"]}
    assert "clean/operaciones/anio=2026/mes=08/operaciones_logisticas.parquet" in llaves
    assert "rechazados/operaciones/fecha_proceso=2026-11-26/operaciones_logisticas.parquet" in llaves
