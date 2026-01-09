"""
CSV Receiver - Cloud Function HTTP
==================================
Recibe archivos CSV via HTTP POST y los guarda en Cloud Storage.

Endpoints:
  POST /           - Subir CSV (multipart/form-data o application/json)
  GET  /health     - Health check

Formatos soportados:
  1. multipart/form-data con campo 'file'
  2. application/json con campo 'data' (contenido CSV) y 'filename'
"""

import os
import json
import uuid
from datetime import datetime
from flask import jsonify
import functions_framework
from google.cloud import storage
from werkzeug.utils import secure_filename

# Configuración
PROJECT_ID = os.environ.get('PROJECT_ID')
BUCKET_NAME = os.environ.get('BUCKET_NAME')

# Extensiones permitidas
ALLOWED_EXTENSIONS = {'csv', 'txt'}
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50MB


def get_storage_client():
    """Obtiene cliente de Cloud Storage."""
    return storage.Client(project=PROJECT_ID)


def allowed_file(filename):
    """Verifica si el archivo tiene extensión permitida."""
    return '.' in filename and \
           filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS


def generate_blob_name(original_filename):
    """
    Genera nombre único para el blob.
    Formato: YYYY/MM/DD/HH/uuid_filename.csv
    """
    now = datetime.utcnow()
    unique_id = str(uuid.uuid4())[:8]
    safe_filename = secure_filename(original_filename)
    
    return f"{now.year}/{now.month:02d}/{now.day:02d}/{now.hour:02d}/{unique_id}_{safe_filename}"


def upload_to_storage(content, blob_name, content_type='text/csv'):
    """
    Sube contenido a Cloud Storage.
    
    Args:
        content: Contenido del archivo (bytes o string)
        blob_name: Nombre del blob
        content_type: Tipo de contenido
        
    Returns:
        dict con información del upload
    """
    client = get_storage_client()
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_name)
    
    # Convertir a bytes si es string
    if isinstance(content, str):
        content = content.encode('utf-8')
    
    # Subir archivo
    blob.upload_from_string(content, content_type=content_type)
    
    # Obtener metadatos
    blob.reload()
    
    return {
        'bucket': BUCKET_NAME,
        'name': blob_name,
        'size': blob.size,
        'content_type': blob.content_type,
        'md5_hash': blob.md5_hash,
        'time_created': blob.time_created.isoformat() if blob.time_created else None,
        'public_url': f"gs://{BUCKET_NAME}/{blob_name}"
    }


@functions_framework.http
def upload_csv(request):
    """
    Entry point de la Cloud Function HTTP.
    
    Soporta:
      - GET /health - Health check
      - POST / - Upload CSV
    """
    # CORS headers
    headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
    }
    
    # Preflight request
    if request.method == 'OPTIONS':
        return ('', 204, headers)
    
    # Health check
    if request.method == 'GET':
        if request.path == '/health' or request.path == '/':
            return (jsonify({
                'status': 'healthy',
                'service': 'csv-receiver',
                'bucket': BUCKET_NAME,
                'timestamp': datetime.utcnow().isoformat()
            }), 200, headers)
    
    # Upload CSV
    if request.method == 'POST':
        try:
            content = None
            filename = None
            
            # Opción 1: multipart/form-data
            if request.files and 'file' in request.files:
                file = request.files['file']
                
                if file.filename == '':
                    return (jsonify({
                        'error': 'No se seleccionó archivo',
                        'code': 'NO_FILE_SELECTED'
                    }), 400, headers)
                
                if not allowed_file(file.filename):
                    return (jsonify({
                        'error': 'Tipo de archivo no permitido. Use .csv o .txt',
                        'code': 'INVALID_FILE_TYPE'
                    }), 400, headers)
                
                filename = file.filename
                content = file.read()
                
                # Verificar tamaño
                if len(content) > MAX_FILE_SIZE:
                    return (jsonify({
                        'error': f'Archivo muy grande. Máximo {MAX_FILE_SIZE / 1024 / 1024}MB',
                        'code': 'FILE_TOO_LARGE'
                    }), 400, headers)
            
            # Opción 2: application/json
            elif request.is_json:
                data = request.get_json()
                
                if 'data' not in data:
                    return (jsonify({
                        'error': 'Campo "data" requerido con contenido CSV',
                        'code': 'MISSING_DATA'
                    }), 400, headers)
                
                content = data['data']
                filename = data.get('filename', f'upload_{datetime.utcnow().strftime("%Y%m%d_%H%M%S")}.csv')
                
                if not filename.endswith('.csv'):
                    filename += '.csv'
            
            # Opción 3: text/csv directo
            elif request.content_type and 'text/csv' in request.content_type:
                content = request.get_data()
                filename = request.args.get('filename', f'upload_{datetime.utcnow().strftime("%Y%m%d_%H%M%S")}.csv')
            
            else:
                return (jsonify({
                    'error': 'Formato no soportado. Use multipart/form-data, application/json, o text/csv',
                    'code': 'UNSUPPORTED_FORMAT',
                    'supported_formats': [
                        'multipart/form-data (campo: file)',
                        'application/json (campos: data, filename)',
                        'text/csv (query param: filename)'
                    ]
                }), 400, headers)
            
            # Validar que hay contenido
            if not content:
                return (jsonify({
                    'error': 'Archivo vacío',
                    'code': 'EMPTY_FILE'
                }), 400, headers)
            
            # Generar nombre único
            blob_name = generate_blob_name(filename)
            
            # Subir a Storage
            print(f"📤 Subiendo archivo: {filename} -> {blob_name}")
            result = upload_to_storage(content, blob_name)
            
            print(f"✅ Archivo subido exitosamente: {blob_name}")
            
            # Contar líneas (aproximado)
            if isinstance(content, bytes):
                line_count = content.count(b'\n')
            else:
                line_count = content.count('\n')
            
            return (jsonify({
                'status': 'success',
                'message': 'CSV subido correctamente',
                'file': {
                    'original_name': filename,
                    'stored_name': blob_name,
                    'bucket': BUCKET_NAME,
                    'size_bytes': result['size'],
                    'estimated_rows': line_count,
                    'gs_uri': result['public_url']
                },
                'processing': {
                    'status': 'queued',
                    'message': 'El archivo será procesado automáticamente'
                }
            }), 200, headers)
            
        except Exception as e:
            print(f"❌ Error procesando upload: {e}")
            return (jsonify({
                'error': str(e),
                'code': 'UPLOAD_ERROR'
            }), 500, headers)
    
    # Método no permitido
    return (jsonify({
        'error': 'Método no permitido',
        'allowed_methods': ['GET', 'POST']
    }), 405, headers)
