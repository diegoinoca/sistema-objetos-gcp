#!/bin/bash
# =============================================================================
# Script de Pruebas - Sistema de Carga de CSV a BigTable
# =============================================================================

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variables
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}
REGION=${REGION:-"us-central1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}

BUCKET_NAME="${PROJECT_ID}-csv-upload-${ENVIRONMENT}"
RECEIVER_NAME="csv-receiver-${ENVIRONMENT}"
PROCESSOR_NAME="csv-processor-${ENVIRONMENT}"
BIGTABLE_INSTANCE="csv-data-${ENVIRONMENT}"
BIGTABLE_TABLE="csv-records"

# Funciones
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

echo ""
echo "=============================================================="
echo " 🧪 PRUEBAS DEL SISTEMA CSV TO BIGTABLE"
echo "=============================================================="
echo ""
log_info "Proyecto: $PROJECT_ID"
log_info "Bucket: $BUCKET_NAME"
log_info "BigTable: $BIGTABLE_INSTANCE"
echo ""

# Prueba 1: Verificar recursos
log_test "PRUEBA 1: Verificar recursos"
gsutil ls gs://${BUCKET_NAME} > /dev/null 2>&1 && log_success "Bucket existe" || { log_error "Bucket NO existe"; exit 1; }
gcloud bigtable instances describe ${BIGTABLE_INSTANCE} > /dev/null 2>&1 && log_success "BigTable existe" || { log_error "BigTable NO existe"; exit 1; }

# Prueba 2: Obtener URL de la API
log_test "PRUEBA 2: Obtener URL de API"
API_URL=$(gcloud functions describe ${RECEIVER_NAME} --gen2 --region=${REGION} --format="value(url)" 2>/dev/null)
if [ -n "$API_URL" ]; then
    log_success "API URL: $API_URL"
else
    log_error "No se pudo obtener URL"
    exit 1
fi

# Prueba 3: Health check
log_test "PRUEBA 3: Health check de la API"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/health")
[ "$HTTP_CODE" = "200" ] && log_success "Health check OK (HTTP $HTTP_CODE)" || log_warning "Health check HTTP $HTTP_CODE"

# Prueba 4: Crear CSV de prueba
log_test "PRUEBA 4: Crear CSV de prueba"
cat > /tmp/test_data.csv << EOF
id,producto,categoria,precio,stock,fecha_registro
1,Laptop HP,Computadores,899990,50,2024-01-15
2,Mouse Logitech,Accesorios,29990,200,2024-01-16
3,Monitor Samsung,Monitores,349990,30,2024-01-17
4,Teclado Mecánico,Accesorios,79990,100,2024-01-18
5,Webcam HD,Accesorios,49990,75,2024-01-19
6,Disco SSD 1TB,Almacenamiento,89990,60,2024-01-20
7,RAM 16GB,Componentes,69990,80,2024-01-21
8,Audífonos Sony,Audio,149990,40,2024-01-22
9,Tablet iPad,Tablets,699990,25,2024-01-23
10,Cargador USB-C,Accesorios,19990,150,2024-01-24
EOF
log_success "CSV creado: /tmp/test_data.csv"
echo ""
cat /tmp/test_data.csv
echo ""

# Prueba 5: Subir CSV via API
log_test "PRUEBA 5: Subir CSV via API"
RESPONSE=$(curl -s -X POST "${API_URL}" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@/tmp/test_data.csv")
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

if echo "$RESPONSE" | grep -q "success"; then
    log_success "CSV subido exitosamente"
else
    log_warning "Verificar respuesta de la API"
fi

# Prueba 6: Esperar procesamiento
log_test "PRUEBA 6: Esperar procesamiento (45 segundos)"
for i in {1..45}; do
    echo -n "."
    sleep 1
done
echo ""
log_success "Tiempo de espera completado"

# Prueba 7: Verificar logs del processor
log_test "PRUEBA 7: Verificar logs del processor"
gcloud functions logs read ${PROCESSOR_NAME} --gen2 --region=${REGION} --limit=15

# Prueba 8: Verificar datos en BigTable
log_test "PRUEBA 8: Verificar datos en BigTable"
echo "project = ${PROJECT_ID}" > ~/.cbtrc
echo "instance = ${BIGTABLE_INSTANCE}" >> ~/.cbtrc

echo ""
log_info "Leyendo registros de BigTable..."
cbt read ${BIGTABLE_TABLE} count=5 2>/dev/null || log_warning "No se pudieron leer registros"

echo ""
log_info "Contando registros..."
COUNT=$(cbt count ${BIGTABLE_TABLE} 2>/dev/null || echo "0")
log_info "Total de registros: $COUNT"

# Prueba 9: Leer resumen del archivo
log_test "PRUEBA 9: Verificar resumen del archivo"
cbt read ${BIGTABLE_TABLE} prefix=_summary_ 2>/dev/null || log_warning "No se encontró resumen"

# Resumen
echo ""
echo "=============================================================="
echo " 📊 RESUMEN DE PRUEBAS"
echo "=============================================================="
echo ""
log_success "Pruebas completadas"
echo ""
log_info "API URL: $API_URL"
log_info "Bucket: gs://${BUCKET_NAME}"
log_info "BigTable: ${BIGTABLE_INSTANCE}/${BIGTABLE_TABLE}"
echo ""
log_info "Comandos útiles:"
echo ""
echo "  # Subir otro CSV"
echo "  curl -X POST \"$API_URL\" -F \"file=@tu_archivo.csv\""
echo ""
echo "  # Ver logs"
echo "  gcloud functions logs read ${PROCESSOR_NAME} --gen2 --region=${REGION}"
echo ""
echo "  # Leer BigTable"
echo "  cbt read ${BIGTABLE_TABLE} count=20"
echo ""

# Limpiar
rm -f /tmp/test_data.csv
