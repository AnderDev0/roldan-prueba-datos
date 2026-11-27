"""
ETL de operaciones logisticas: CSV -> limpieza y validacion -> Parquet -> S3

Uso (desde la raiz del repo):
    python fase2_etl/etl_operaciones.py --input data/raw/operaciones_logisticas.csv
    python fase2_etl/etl_operaciones.py --input data/raw/operaciones_logisticas.csv --bucket <bucket> --perfil <perfil>
"""

import argparse
import json
import logging
import shutil
from datetime import date, datetime, timezone
from pathlib import Path

import polars as pl

log = logging.getLogger("etl_operaciones")

ESTADOS_VALIDOS = ["EN TRANSITO", "ADUANA", "RETRASADO", "ENTREGADO"]
COLUMNAS_TEXTO = [
    "tipo_carga", "puerto_origen", "puerto_destino", "nombre_transportista",
    "estado_actual", "coordinador_asignado", "bodega_destino",
]
PENALIDAD_ERROR = 25
PENALIDAD_ADVERTENCIA = 10
DIAS_MAX_EN_TRANSITO = 30


def leer_csv(ruta: Path) -> pl.DataFrame:
    # todo como texto, los tipos se convierten despues de limpiar
    return pl.read_csv(ruta, infer_schema=False, null_values=["NULL", "null", ""])


def limpiar(df: pl.DataFrame) -> pl.DataFrame:
    df = df.with_columns(pl.col(pl.String).str.strip_chars().str.replace_all(r"\s+", " "))

    return df.with_columns(
        pl.col(COLUMNAS_TEXTO)
        .str.to_uppercase()
        .str.replace_many(["Á", "É", "Í", "Ó", "Ú"], ["A", "E", "I", "O", "U"]),
        pl.col("contenedor_num", "id_operacion", "id_transportista").str.to_uppercase(),
        pl.col("contacto_transportista").str.to_lowercase(),
        pl.col("peso_kg").cast(pl.Float64, strict=False),
        pl.col("costo_usd").cast(pl.Decimal(12, 2), strict=False),
        pl.col("fecha_arribo").str.to_date("%Y-%m-%d", strict=False),
    )


def digito_control_iso6346(numero: str | None) -> bool:
    """Valida el ultimo digito del contenedor segun ISO 6346."""
    if numero is None or len(numero) != 11:
        return False
    valores, v = {}, 10
    for letra in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        if v % 11 == 0:
            v += 1
        valores[letra] = v
        v += 1
    try:
        suma = sum(
            (valores[c] if c.isalpha() else int(c)) * 2**i
            for i, c in enumerate(numero[:10])
        )
        return suma % 11 % 10 == int(numero[10])
    except (KeyError, ValueError):
        return False


def validar(df: pl.DataFrame, fecha_proceso: date) -> pl.DataFrame:
    errores = {
        "id_operacion con formato invalido": ~pl.col("id_operacion").str.contains(r"^OP-\d{4}-\d{3,}$").fill_null(False),
        "id_operacion duplicado": pl.col("id_operacion").is_duplicated(),
        "peso_kg vacio o menor/igual a 0": pl.col("peso_kg").is_null() | (pl.col("peso_kg") <= 0),
        "costo_usd vacio o menor/igual a 0": pl.col("costo_usd").is_null() | (pl.col("costo_usd") <= 0),
        "estado no reconocido": ~pl.col("estado_actual").is_in(ESTADOS_VALIDOS).fill_null(False),
        "transportista sin contacto valido": ~pl.col("contacto_transportista").str.contains(r"^[\w.%+-]+@[\w.-]+\.[a-z]{2,}$").fill_null(False),
        "fecha_arribo vacia o invalida": pl.col("fecha_arribo").is_null(),
        "contenedor con formato invalido": ~pl.col("contenedor_num").str.contains(r"^[A-Z]{3}[UJZ]\d{7}$").fill_null(False),
    }
    advertencias = {
        "digito de control del contenedor no coincide (ISO 6346)":
            ~pl.col("contenedor_num").map_elements(digito_control_iso6346, return_dtype=pl.Boolean),
        f"arribo hace mas de {DIAS_MAX_EN_TRANSITO} dias y sigue EN TRANSITO":
            (pl.col("estado_actual") == "EN TRANSITO")
            & ((pl.lit(fecha_proceso) - pl.col("fecha_arribo")).dt.total_days() > DIAS_MAX_EN_TRANSITO),
    }

    def a_lista(reglas: dict) -> pl.Expr:
        return pl.concat_list(
            [pl.when(cond.fill_null(False)).then(pl.lit(msg)).otherwise(None) for msg, cond in reglas.items()]
        ).list.drop_nulls()

    df = df.with_columns(errores=a_lista(errores), advertencias=a_lista(advertencias))
    df = df.with_columns(
        puntaje_calidad=(
            100
            - pl.col("errores").list.len().cast(pl.Int32) * PENALIDAD_ERROR
            - pl.col("advertencias").list.len().cast(pl.Int32) * PENALIDAD_ADVERTENCIA
        ).clip(0, 100).cast(pl.Int8)
    )

    fuera_de_rango = df.filter(~pl.col("puntaje_calidad").is_between(0, 100)).height
    if fuera_de_rango:
        raise ValueError(f"{fuera_de_rango} registros con puntaje fuera de 0-100")
    return df


def escribir_salida(df: pl.DataFrame, carpeta: Path, archivo_origen: Path, fecha_proceso: date) -> dict:
    nombre = archivo_origen.stem
    df = df.with_columns(
        fecha_proceso=pl.lit(datetime.now(timezone.utc)),
        archivo_origen=pl.lit(archivo_origen.name),
    )
    validos = df.filter(pl.col("errores").list.len() == 0).drop("errores")
    rechazados = df.filter(pl.col("errores").list.len() > 0)

    if carpeta.exists():
        shutil.rmtree(carpeta)

    # capa cruda: el archivo tal cual llego
    destino_raw = carpeta / "raw/operaciones" / f"fecha_proceso={fecha_proceso}" / archivo_origen.name
    destino_raw.parent.mkdir(parents=True)
    shutil.copy2(archivo_origen, destino_raw)

    # capa limpia particionada por anio y mes de arribo
    validos = validos.with_columns(
        anio=pl.col("fecha_arribo").dt.year(), mes=pl.col("fecha_arribo").dt.month()
    )
    for (anio, mes), particion in validos.group_by(["anio", "mes"]):
        ruta = carpeta / "clean/operaciones" / f"anio={anio}" / f"mes={mes:02d}" / f"{nombre}.parquet"
        ruta.parent.mkdir(parents=True, exist_ok=True)
        particion.drop("anio", "mes").sort("id_operacion").write_parquet(ruta, compression="snappy")

    if rechazados.height:
        ruta = carpeta / "rechazados/operaciones" / f"fecha_proceso={fecha_proceso}" / f"{nombre}.parquet"
        ruta.parent.mkdir(parents=True)
        rechazados.write_parquet(ruta, compression="snappy")

    reporte = {
        "archivo": archivo_origen.name,
        "fecha_proceso": str(fecha_proceso),
        "total_registros": df.height,
        "validos": validos.height,
        "rechazados": rechazados.height,
        "porcentaje_validos": round(100 * validos.height / df.height, 1) if df.height else 0,
        "puntaje_promedio": round(df["puntaje_calidad"].mean(), 1) if df.height else 0,
        "errores": conteo(df, "errores"),
        "advertencias": conteo(df, "advertencias"),
        "rechazados_detalle": rechazados.select("id_operacion", "errores").to_dicts(),
    }
    ruta = carpeta / "calidad" / f"fecha_proceso={fecha_proceso}" / f"{nombre}.json"
    ruta.parent.mkdir(parents=True)
    ruta.write_text(json.dumps(reporte, ensure_ascii=False, indent=2), encoding="utf-8")
    return reporte


def conteo(df: pl.DataFrame, columna: str) -> dict:
    explotado = df.select(pl.col(columna).explode()).drop_nulls()
    return dict(explotado.group_by(columna).len().sort("len", descending=True).iter_rows())


def subir_a_s3(carpeta: Path, bucket: str, prefijo: str = "", perfil: str | None = None) -> list[str]:
    import boto3

    # las credenciales salen del perfil de AWS o de variables de entorno, nunca del codigo
    s3 = boto3.Session(profile_name=perfil).client("s3")
    subidos = []
    for archivo in sorted(p for p in carpeta.rglob("*") if p.is_file()):
        llave = "/".join(filter(None, [prefijo.strip("/"), archivo.relative_to(carpeta).as_posix()]))
        s3.upload_file(str(archivo), bucket, llave)
        subidos.append(f"s3://{bucket}/{llave}")
        log.info("subido %s", subidos[-1])
    return subidos


def ejecutar(entrada: Path, salida: Path, bucket: str | None = None,
             prefijo: str = "", perfil: str | None = None, fecha_proceso: date | None = None) -> dict:
    fecha_proceso = fecha_proceso or date.today()
    df = leer_csv(entrada)
    log.info("leidos %s registros de %s", df.height, entrada.name)

    df = validar(limpiar(df), fecha_proceso)
    reporte = escribir_salida(df, salida, entrada, fecha_proceso)
    log.info("validos: %s | rechazados: %s", reporte["validos"], reporte["rechazados"])

    if bucket:
        subir_a_s3(salida, bucket, prefijo, perfil)
    return reporte


def main():
    parser = argparse.ArgumentParser(description="ETL de operaciones logisticas hacia S3")
    parser.add_argument("--input", required=True, type=Path, help="ruta del CSV")
    parser.add_argument("--salida", default=Path(__file__).parent / "salida", type=Path, help="carpeta local de salida")
    parser.add_argument("--bucket", help="bucket de S3; si no se pasa, solo se genera la salida local")
    parser.add_argument("--prefijo", default="", help="carpeta dentro del bucket")
    parser.add_argument("--perfil", help="perfil de AWS (~/.aws/credentials)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    reporte = ejecutar(args.input, args.salida, args.bucket, args.prefijo, args.perfil)
    print(json.dumps(reporte, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
