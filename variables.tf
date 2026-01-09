# =============================================================================
# VARIABLES - Sistema de Carga de CSV a BigTable
# =============================================================================

variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = "Región de GCP"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona de GCP para BigTable"
  type        = string
  default     = "us-central1-c"
}

variable "environment" {
  description = "Ambiente (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "El ambiente debe ser: dev, staging o prod."
  }
}

variable "force_destroy" {
  description = "Permitir destruir bucket con objetos"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels para todos los recursos"
  type        = map(string)
  default = {
    managed_by = "terraform"
    purpose    = "csv-to-bigtable"
  }
}

# BigTable
variable "bigtable_num_nodes" {
  description = "Número de nodos para BigTable"
  type        = number
  default     = 1
}

variable "bigtable_storage_type" {
  description = "Tipo de almacenamiento (SSD o HDD)"
  type        = string
  default     = "SSD"
}

variable "bigtable_deletion_protection" {
  description = "Protección contra eliminación"
  type        = bool
  default     = false
}

variable "bigtable_retention_days" {
  description = "Días de retención de metadatos"
  type        = number
  default     = 90
}

# Cloud Functions
variable "function_max_instances" {
  description = "Máximo de instancias"
  type        = number
  default     = 10
}

variable "function_min_instances" {
  description = "Mínimo de instancias"
  type        = number
  default     = 0
}

variable "processor_memory" {
  description = "Memoria para el processor (para CSVs grandes)"
  type        = string
  default     = "1Gi"
}

variable "processor_timeout" {
  description = "Timeout del processor en segundos"
  type        = number
  default     = 540  # 9 minutos para CSVs grandes
}
