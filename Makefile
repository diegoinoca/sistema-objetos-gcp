# =============================================================================
# Makefile - Sistema de Carga de CSV a BigTable
# =============================================================================

PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION ?= us-central1
ZONE ?= us-central1-c
ENVIRONMENT ?= dev

# Colores
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
CYAN := \033[0;36m
NC := \033[0m

# Nombres de recursos
BUCKET_NAME := $(PROJECT_ID)-csv-upload-$(ENVIRONMENT)
RECEIVER_NAME := csv-receiver-$(ENVIRONMENT)
PROCESSOR_NAME := csv-processor-$(ENVIRONMENT)
BIGTABLE_INSTANCE := csv-data-$(ENVIRONMENT)
BIGTABLE_TABLE := csv-records

.PHONY: help
help:
	@echo ""
	@echo "$(CYAN)============================================================$(NC)"
	@echo "$(CYAN) Sistema de Carga de CSV a BigTable                         $(NC)"
	@echo "$(CYAN)============================================================$(NC)"
	@echo ""
	@echo "$(YELLOW)Configuración:$(NC)"
	@echo "  PROJECT_ID:  $(PROJECT_ID)"
	@echo "  REGION:      $(REGION)"
	@echo "  ENVIRONMENT: $(ENVIRONMENT)"
	@echo ""
	@echo "$(YELLOW)Infraestructura:$(NC)"
	@echo "  $(GREEN)make init$(NC)           - Inicializar Terraform"
	@echo "  $(GREEN)make plan$(NC)           - Ver plan de cambios"
	@echo "  $(GREEN)make apply$(NC)          - Aplicar infraestructura"
	@echo "  $(GREEN)make destroy$(NC)        - Destruir infraestructura"
	@echo ""
	@echo "$(YELLOW)Pruebas:$(NC)"
	@echo "  $(GREEN)make test$(NC)           - Ejecutar pruebas completas"
	@echo "  $(GREEN)make test-upload$(NC)    - Subir CSV de prueba via API"
	@echo "  $(GREEN)make test-gsutil$(NC)    - Subir CSV via gsutil"
	@echo "  $(GREEN)make test-verify$(NC)    - Verificar datos en BigTable"
	@echo ""
	@echo "$(YELLOW)Monitoreo:$(NC)"
	@echo "  $(GREEN)make logs-receiver$(NC)  - Logs del receiver"
	@echo "  $(GREEN)make logs-processor$(NC) - Logs del processor"
	@echo "  $(GREEN)make bigtable-read$(NC)  - Leer datos de BigTable"
	@echo "  $(GREEN)make bigtable-count$(NC) - Contar registros"
	@echo "  $(GREEN)make status$(NC)         - Estado de recursos"
	@echo ""
	@echo "$(YELLOW)Utilidades:$(NC)"
	@echo "  $(GREEN)make api-url$(NC)        - Mostrar URL de la API"
	@echo "  $(GREEN)make setup-cbt$(NC)      - Configurar cliente cbt"
	@echo "  $(GREEN)make create-sample$(NC)  - Crear CSV de ejemplo"
	@echo ""

# =============================================================================
# TERRAFORM
# =============================================================================

.PHONY: init
init:
	@echo "$(BLUE)[INFO]$(NC) Inicializando Terraform..."
	@terraform init
	@echo "$(GREEN)[✓]$(NC) Terraform inicializado"

.PHONY: plan
plan:
	@echo "$(BLUE)[INFO]$(NC) Generando plan..."
	@terraform plan \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="environment=$(ENVIRONMENT)"

.PHONY: apply
apply:
	@echo "$(BLUE)[INFO]$(NC) Aplicando infraestructura..."
	@terraform apply \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="environment=$(ENVIRONMENT)"
	@echo "$(GREEN)[✓]$(NC) Infraestructura aplicada"

.PHONY: apply-auto
apply-auto:
	@terraform apply -auto-approve \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="environment=$(ENVIRONMENT)"

.PHONY: destroy
destroy:
	@terraform destroy \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="zone=$(ZONE)" \
		-var="environment=$(ENVIRONMENT)"

.PHONY: output
output:
	@terraform output

# =============================================================================
# PRUEBAS
# =============================================================================

.PHONY: create-sample
create-sample:
	@echo "$(BLUE)[INFO]$(NC) Creando CSV de ejemplo..."
	@echo "id,nombre,email,edad,ciudad,salario" > /tmp/sample.csv
	@echo "1,Juan Perez,juan@email.com,28,Santiago,50000" >> /tmp/sample.csv
	@echo "2,Maria Garcia,maria@email.com,32,Valparaiso,65000" >> /tmp/sample.csv
	@echo "3,Carlos Lopez,carlos@email.com,25,Concepcion,45000" >> /tmp/sample.csv
	@echo "4,Ana Martinez,ana@email.com,35,La Serena,70000" >> /tmp/sample.csv
	@echo "5,Pedro Sanchez,pedro@email.com,29,Antofagasta,55000" >> /tmp/sample.csv
	@echo "$(GREEN)[✓]$(NC) CSV creado: /tmp/sample.csv"
	@cat /tmp/sample.csv

.PHONY: api-url
api-url:
	@echo ""
	@echo "$(CYAN)URL de la API:$(NC)"
	@terraform output -raw api_url 2>/dev/null || gcloud functions describe $(RECEIVER_NAME) --gen2 --region=$(REGION) --format="value(url)"
	@echo ""

.PHONY: test-upload
test-upload: create-sample
	@echo ""
	@echo "$(BLUE)[TEST]$(NC) Subiendo CSV via API..."
	@API_URL=$$(terraform output -raw api_url 2>/dev/null); \
	curl -X POST "$$API_URL" \
		-H "Content-Type: multipart/form-data" \
		-F "file=@/tmp/sample.csv" | jq .
	@echo ""
	@echo "$(GREEN)[✓]$(NC) CSV enviado"

.PHONY: test-gsutil
test-gsutil: create-sample
	@echo ""
	@echo "$(BLUE)[TEST]$(NC) Subiendo CSV via gsutil..."
	@gsutil cp /tmp/sample.csv gs://$(BUCKET_NAME)/test/sample_$$(date +%s).csv
	@echo "$(GREEN)[✓]$(NC) CSV subido al bucket"

.PHONY: test-wait
test-wait:
	@echo ""
	@echo "$(BLUE)[INFO]$(NC) Esperando 30 segundos para procesamiento..."
	@sleep 30
	@echo "$(GREEN)[✓]$(NC) Completado"

.PHONY: test-verify
test-verify: setup-cbt
	@echo ""
	@echo "$(BLUE)[TEST]$(NC) Verificando datos en BigTable..."
	@cbt read $(BIGTABLE_TABLE) count=10
	@echo ""
	@echo "$(BLUE)[INFO]$(NC) Contando registros..."
	@cbt count $(BIGTABLE_TABLE)

.PHONY: test
test: test-upload test-wait test-verify
	@echo ""
	@echo "$(GREEN)============================================================$(NC)"
	@echo "$(GREEN) ✓ PRUEBAS COMPLETADAS                                      $(NC)"
	@echo "$(GREEN)============================================================$(NC)"

# =============================================================================
# MONITOREO
# =============================================================================

.PHONY: logs-receiver
logs-receiver:
	@echo "$(BLUE)[INFO]$(NC) Logs del receiver..."
	@gcloud functions logs read $(RECEIVER_NAME) --gen2 --region=$(REGION) --limit=30

.PHONY: logs-processor
logs-processor:
	@echo "$(BLUE)[INFO]$(NC) Logs del processor..."
	@gcloud functions logs read $(PROCESSOR_NAME) --gen2 --region=$(REGION) --limit=30

.PHONY: logs
logs: logs-receiver logs-processor

.PHONY: setup-cbt
setup-cbt:
	@echo "$(BLUE)[INFO]$(NC) Configurando cbt..."
	@echo "project = $(PROJECT_ID)" > ~/.cbtrc
	@echo "instance = $(BIGTABLE_INSTANCE)" >> ~/.cbtrc
	@echo "$(GREEN)[✓]$(NC) cbt configurado"

.PHONY: bigtable-read
bigtable-read: setup-cbt
	@echo "$(BLUE)[INFO]$(NC) Leyendo datos de BigTable..."
	@cbt read $(BIGTABLE_TABLE) count=20

.PHONY: bigtable-count
bigtable-count: setup-cbt
	@echo "$(BLUE)[INFO]$(NC) Contando registros..."
	@cbt count $(BIGTABLE_TABLE)

.PHONY: bigtable-summary
bigtable-summary: setup-cbt
	@echo "$(BLUE)[INFO]$(NC) Leyendo resúmenes de archivos..."
	@cbt read $(BIGTABLE_TABLE) prefix=_summary_

.PHONY: status
status:
	@echo ""
	@echo "$(CYAN)============================================================$(NC)"
	@echo "$(CYAN) ESTADO DE RECURSOS                                         $(NC)"
	@echo "$(CYAN)============================================================$(NC)"
	@echo ""
	@echo "$(YELLOW)Bucket:$(NC)"
	@gsutil ls -L -b gs://$(BUCKET_NAME) 2>/dev/null | head -5 || echo "  $(RED)[✗]$(NC) No encontrado"
	@echo ""
	@echo "$(YELLOW)Receiver:$(NC)"
	@gcloud functions describe $(RECEIVER_NAME) --gen2 --region=$(REGION) --format="yaml(name, state, url)" 2>/dev/null || echo "  $(RED)[✗]$(NC) No encontrado"
	@echo ""
	@echo "$(YELLOW)Processor:$(NC)"
	@gcloud functions describe $(PROCESSOR_NAME) --gen2 --region=$(REGION) --format="yaml(name, state)" 2>/dev/null || echo "  $(RED)[✗]$(NC) No encontrado"
	@echo ""
	@echo "$(YELLOW)BigTable:$(NC)"
	@gcloud bigtable instances describe $(BIGTABLE_INSTANCE) --format="yaml(name, state)" 2>/dev/null || echo "  $(RED)[✗]$(NC) No encontrado"

# =============================================================================
# LIMPIEZA
# =============================================================================

.PHONY: clean
clean:
	@rm -rf .terraform .terraform.lock.hcl terraform.tfstate*
	@rm -f csv-receiver.zip csv-processor.zip
	@rm -f /tmp/sample.csv

.PHONY: bucket-list
bucket-list:
	@gsutil ls -l gs://$(BUCKET_NAME)/

.PHONY: bucket-clear
bucket-clear:
	@echo "$(YELLOW)[!]$(NC) Eliminando objetos del bucket..."
	@gsutil -m rm -r gs://$(BUCKET_NAME)/** 2>/dev/null || true
	@echo "$(GREEN)[✓]$(NC) Bucket limpiado"

.DEFAULT_GOAL := help
