"""
CSV Processor - Cloud Function Pub/Sub
======================================
Procesa archivos CSV desde Cloud Storage y carga los datos a BigTable.

Trigger: Pub/Sub (Storage Notification)
Eventos: OBJECT_FINALIZE

Esquema BigTable:
  Row Key: {file_hash}_{row_number}
  Column Families:
    - data: columnas del CSV
    - metadata: información del archivo y procesamiento
"""

import os
import csv
import json
import base64
import hashlib
import io
from datetime import datetime
import functions_framework
from google.cloud import storage
from google.cloud import bigtable
from google.cloud.bigtable import row as bt_row

# Configuración
PROJECT_ID = os.environ.get('PROJECT_ID')
BIGTABLE_INSTANCE = os.environ.get('BIGTABLE_INSTANCE')
BIGTABLE_TABLE = os.environ.get('BIGTABLE_TABLE')
BUCKET_NAME = os.environ.get('BUCKET_NAME')

# Configuración de procesamiento
BATCH_SIZE = 1000  # Número de filas por batch de escritura
MAX_ROWS = 1000000  # Máximo de filas a procesar


def get_storage_client():
    """Obtiene cliente de Cloud Storage."""
    return storage.Client(project=PROJECT_ID)


def get_bigtable_table():
    """Obtiene tabla de BigTable."""
    client = bigtable.Client(project=PROJECT_ID, admin=False)
    instance = client.instance(BIGTABLE_INSTANCE)
    return instance.table(BIGTABLE_TABLE)


def generate_file_hash(bucket: str, name: str) -> str:
    """Genera hash único para el archivo."""
    unique_string = f"{bucket}/{name}"
    return hashlib.md5(unique_string.encode()).hexdigest()[:12]


def generate_row_key(file_hash: str, row_number: int) -> str:
    """
    Genera row key para BigTable.
    Formato: {file_hash}_{row_number:010d}
    El padding asegura orden correcto.
    """
    return f"{file_hash}_{row_number:010d}"


def sanitize_column_name(name: str) -> str:
    """
    Sanitiza nombre de columna para BigTable.
    - Remueve caracteres especiales
    - Convierte a minúsculas
    - Reemplaza espacios con _
    """
    import re
    # Remover caracteres no alfanuméricos excepto _
    sanitized = re.sub(r'[^\w\s]', '', name)
    # Reemplazar espacios con _
    sanitized = sanitized.replace(' ', '_')
    # Convertir a minúsculas
    sanitized = sanitized.lower()
    # Limitar longitud
    return sanitized[:64] if sanitized else 'column'


def download_csv_from_storage(bucket_name: str, blob_name: str) -> str:
    """
    Descarga CSV de Cloud Storage.
    
    Returns:
        Contenido del CSV como string
    """
    client = get_storage_client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    
    content = blob.download_as_text()
    return content


def detect_delimiter(sample: str) -> str:
    """
    Detecta el delimitador del CSV.
    Soporta: , ; \t |
    """
    delimiters = [',', ';', '\t', '|']
    
    # Tomar primera línea
    first_line = sample.split('\n')[0]
    
    # Contar ocurrencias de cada delimitador
    counts = {d: first_line.count(d) for d in delimiters}
    
    # Retornar el más común
    max_delimiter = max(counts, key=counts.get)
    
    return max_delimiter if counts[max_delimiter] > 0 else ','


def process_csv_content(content: str, file_hash: str, blob_name: str) -> dict:
    """
    Procesa contenido CSV y lo carga a BigTable.
    
    Args:
        content: Contenido del CSV
        file_hash: Hash único del archivo
        blob_name: Nombre del blob
        
    Returns:
        dict con estadísticas del procesamiento
    """
    table = get_bigtable_table()
    timestamp = datetime.utcnow()
    
    # Detectar delimitador
    delimiter = detect_delimiter(content)
    print(f"📊 Delimitador detectado: '{delimiter}'")
    
    # Parsear CSV
    csv_file = io.StringIO(content)
    reader = csv.DictReader(csv_file, delimiter=delimiter)
    
    # Obtener y sanitizar nombres de columnas
    if reader.fieldnames:
        original_columns = list(reader.fieldnames)
        columns = [sanitize_column_name(col) for col in original_columns]
        column_mapping = dict(zip(original_columns, columns))
    else:
        raise ValueError("CSV no tiene encabezados")
    
    print(f"📋 Columnas detectadas: {columns}")
    
    # Estadísticas
    stats = {
        'total_rows': 0,
        'processed_rows': 0,
        'error_rows': 0,
        'batches_written': 0,
        'columns': columns,
        'file_hash': file_hash,
        'blob_name': blob_name
    }
    
    # Procesar en batches
    rows_batch = []
    
    for row_num, row in enumerate(reader, start=1):
        if row_num > MAX_ROWS:
            print(f"⚠️ Límite de {MAX_ROWS} filas alcanzado")
            break
        
        stats['total_rows'] += 1
        
        try:
            # Generar row key
            row_key = generate_row_key(file_hash, row_num)
            
            # Crear fila de BigTable
            bt_row_obj = table.direct_row(row_key)
            
            # Agregar datos del CSV (column family: data)
            for orig_col, value in row.items():
                if value is not None:
                    col_name = column_mapping.get(orig_col, sanitize_column_name(orig_col))
                    bt_row_obj.set_cell(
                        'data',
                        col_name.encode('utf-8'),
                        str(value).encode('utf-8'),
                        timestamp=timestamp
                    )
            
            # Agregar metadatos (column family: metadata)
            bt_row_obj.set_cell('metadata', b'row_number', str(row_num).encode(), timestamp=timestamp)
            bt_row_obj.set_cell('metadata', b'file_hash', file_hash.encode(), timestamp=timestamp)
            bt_row_obj.set_cell('metadata', b'source_file', blob_name.encode(), timestamp=timestamp)
            bt_row_obj.set_cell('metadata', b'processed_at', timestamp.isoformat().encode(), timestamp=timestamp)
            
            rows_batch.append(bt_row_obj)
            stats['processed_rows'] += 1
            
            # Escribir batch
            if len(rows_batch) >= BATCH_SIZE:
                table.mutate_rows(rows_batch)
                stats['batches_written'] += 1
                print(f"📝 Batch {stats['batches_written']} escrito ({len(rows_batch)} filas)")
                rows_batch = []
                
        except Exception as e:
            print(f"⚠️ Error en fila {row_num}: {e}")
            stats['error_rows'] += 1
    
    # Escribir batch final
    if rows_batch:
        table.mutate_rows(rows_batch)
        stats['batches_written'] += 1
        print(f"📝 Batch final escrito ({len(rows_batch)} filas)")
    
    # Guardar resumen del archivo
    save_file_summary(table, file_hash, blob_name, stats, timestamp)
    
    return stats


def save_file_summary(table, file_hash: str, blob_name: str, stats: dict, timestamp: datetime):
    """
    Guarda un registro resumen del archivo procesado.
    Row Key: _summary_{file_hash}
    """
    row_key = f"_summary_{file_hash}"
    row = table.direct_row(row_key)
    
    row.set_cell('metadata', b'file_hash', file_hash.encode(), timestamp=timestamp)
    row.set_cell('metadata', b'source_file', blob_name.encode(), timestamp=timestamp)
    row.set_cell('metadata', b'total_rows', str(stats['total_rows']).encode(), timestamp=timestamp)
    row.set_cell('metadata', b'processed_rows', str(stats['processed_rows']).encode(), timestamp=timestamp)
    row.set_cell('metadata', b'error_rows', str(stats['error_rows']).encode(), timestamp=timestamp)
    row.set_cell('metadata', b'columns', json.dumps(stats['columns']).encode(), timestamp=timestamp)
    row.set_cell('metadata', b'processed_at', timestamp.isoformat().encode(), timestamp=timestamp)
    row.set_cell('metadata', b'status', b'completed', timestamp=timestamp)
    
    row.commit()
    print(f"📊 Resumen guardado: {row_key}")


@functions_framework.cloud_event
def process_csv(cloud_event):
    """
    Entry point de la Cloud Function.
    
    Trigger: Pub/Sub (Storage Notification OBJECT_FINALIZE)
    """
    print(f"📥 Evento recibido: {cloud_event['id']}")
    
    try:
        # Decodificar mensaje Pub/Sub
        pubsub_message = cloud_event.data.get('message', {})
        
        if 'data' not in pubsub_message:
            print("⚠️ Mensaje sin datos")
            return
        
        message_data = base64.b64decode(pubsub_message['data']).decode('utf-8')
        event_data = json.loads(message_data)
        
        # Los campos pueden tener diferentes nombres según el formato
        bucket = event_data.get('bucket', '')
        blob_name = event_data.get('name', '')
        # 'eventType' en algunos casos, 'kind' en otros
        event_type = event_data.get('eventType', event_data.get('kind', ''))
        content_type = event_data.get('contentType', event_data.get('mediaType', ''))
        
        print(f"📄 Archivo: gs://{bucket}/{blob_name}")
        print(f"📌 Evento: {event_type}")
        print(f"📋 Tipo: {content_type}")
        
        # Verificar que es el bucket correcto
        if bucket and bucket != BUCKET_NAME:
            print(f"⏭️ Ignorando - bucket diferente: {bucket}")
            return
        
        # Verificar que es un CSV
        if not blob_name or not blob_name.lower().endswith('.csv'):
            print(f"⏭️ Ignorando - no es CSV: {blob_name}")
            return
        
        # Si llegamos aquí y tenemos bucket + blob_name, procesamos
        # Las notificaciones de Storage con OBJECT_FINALIZE pueden no incluir explícitamente el eventType
        
        # Generar hash del archivo
        file_hash = generate_file_hash(bucket, blob_name)
        print(f"🔑 File hash: {file_hash}")
        
        # Descargar CSV
        print(f"📥 Descargando CSV...")
        csv_content = download_csv_from_storage(bucket, blob_name)
        
        # Obtener tamaño
        size_bytes = len(csv_content.encode('utf-8'))
        size_mb = size_bytes / (1024 * 1024)
        print(f"📊 Tamaño: {size_mb:.2f} MB")
        
        # Procesar CSV
        print(f"⚙️ Procesando CSV...")
        stats = process_csv_content(csv_content, file_hash, blob_name)
        
        # Log resultado
        print(f"✅ Procesamiento completado:")
        print(f"   📊 Total filas: {stats['total_rows']}")
        print(f"   ✅ Procesadas: {stats['processed_rows']}")
        print(f"   ❌ Errores: {stats['error_rows']}")
        print(f"   📝 Batches: {stats['batches_written']}")
        print(f"   📋 Columnas: {stats['columns']}")
        
    except Exception as e:
        print(f"❌ Error procesando evento: {e}")
        raise  # Re-raise para activar retry


def process_csv_manual(bucket: str, blob_name: str):
    """
    Función auxiliar para procesar un CSV manualmente.
    Útil para testing y reprocesamiento.
    """
    file_hash = generate_file_hash(bucket, blob_name)
    csv_content = download_csv_from_storage(bucket, blob_name)
    stats = process_csv_content(csv_content, file_hash, blob_name)
    return stats
