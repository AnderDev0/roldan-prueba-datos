import json
from datetime import date
from decimal import Decimal
from pathlib import Path

import polars as pl
import pytest

import etl_operaciones as etl

CSV = Path(__file__).parents[1] / "data/raw/operaciones_logisticas.csv"
CONFIG = Path(__file__).parents[1] / "fase2_etl/config/contingencias.json"


@pytest.fixture
def df():
    return etl.validar(etl.limpiar(etl.leer_csv(CSV)), date(2026, 11, 26))


def fila(df, id_operacion):
    return df.filter(pl.col("id_operacion") == id_operacion).row(0, named=True)


def test_redirige_a_tumaco_las_no_entregadas(df):
    res = etl.aplicar_contingencias(df, CONFIG)
    assert fila(res, "OP-2026-002")["puerto_destino"] == "TUMACO"
    assert fila(res, "OP-2026-004")["puerto_destino"] == "TUMACO"


def test_no_toca_las_entregadas(df):
    res = etl.aplicar_contingencias(df, CONFIG)
    op1 = fila(res, "OP-2026-001")
    assert op1["puerto_destino"] == "BUENAVENTURA"
    assert op1["costo_usd"] == Decimal("1500.00")


def test_recargo_del_12_y_conserva_el_original(df):
    res = etl.aplicar_contingencias(df, CONFIG)
    op2 = fila(res, "OP-2026-002")
    assert op2["costo_usd"] == Decimal("2352.00")
    assert op2["costo_usd_original"] == Decimal("2100.00")
    assert op2["puerto_destino_original"] == "BUENAVENTURA"


def test_correrlo_dos_veces_no_acumula_recargo(df):
    una_vez = etl.aplicar_contingencias(df, CONFIG)
    dos_veces = etl.aplicar_contingencias(una_vez, CONFIG)
    assert fila(dos_veces, "OP-2026-004")["costo_usd"] == Decimal("1848.00")


def test_regla_inactiva_no_cambia_nada(df, tmp_path):
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    config["redireccion_puertos"][0]["activa"] = False
    inactiva = tmp_path / "contingencias.json"
    inactiva.write_text(json.dumps(config), encoding="utf-8")
    res = etl.aplicar_contingencias(df, inactiva)
    assert res.filter(pl.col("puerto_destino") == "TUMACO").height == 0
