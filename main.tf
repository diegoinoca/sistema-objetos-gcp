# =============================================================================
# LOCALS
# =============================================================================

locals {
  bucket_name           = "${var.project_id}-csv-upload-${var.environment}"
  pubsub_topic_name     = "csv-processing-${var.environment}"
  dlq_topic_name        = "csv-processing-${var.environment}-dlq"
  receiver_name         = "csv-receiver-${var.environment}"
  processor_name        = "csv-processor-${var.environment}"
  bigtable_instance_id  = "csv-data-${var.environment}"
  bigtable_table_id     = "csv-records"
  sa_receiver_name      = "csv-receiver-sa"
  sa_processor_name     = "csv-processor-sa"
}

# =============================================================================
# HABILITAR APIs
# =============================================================================

resource "google_project_service" "apis" {
  for_each = toset([
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "bigtable.googleapis.com",
    "bigtableadmin.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com"
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# =============================================================================
# SERVICE ACCOUNTS
# =============================================================================

# Service Account para CSV Receiver
resource "google_service_account" "receiver_sa" {
  account_id   = local.sa_receiver_name
  display_name = "CSV Receiver Service Account"
  description  = "SA para la función que recibe CSVs via HTTP"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

# Service Account para CSV Processor
resource "google_service_account" "processor_sa" {
  account_id   = local.sa_processor_name
  display_name = "CSV Processor Service Account"
  description  = "SA para la función que procesa CSVs y carga a BigTable"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

# Permisos para Receiver SA
resource "google_project_iam_member" "receiver_storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.receiver_sa.email}"
}

resource "google_project_iam_member" "receiver_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.receiver_sa.email}"
}

resource "google_project_iam_member" "receiver_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.receiver_sa.email}"
}

# Permisos para Processor SA
resource "google_project_iam_member" "processor_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.processor_sa.email}"
}

resource "google_project_iam_member" "processor_bigtable_user" {
  project = var.project_id
  role    = "roles/bigtable.user"
  member  = "serviceAccount:${google_service_account.processor_sa.email}"
}

resource "google_project_iam_member" "processor_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.processor_sa.email}"
}

resource "google_project_iam_member" "processor_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.processor_sa.email}"
}

# =============================================================================
# CLOUD STORAGE BUCKET
# =============================================================================

resource "google_storage_bucket" "csv_bucket" {
  name          = local.bucket_name
  location      = var.region
  project       = var.project_id
  force_destroy = var.force_destroy

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # Lifecycle: mover a Nearline después de 30 días
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Lifecycle: eliminar después de 90 días
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "csv-upload"
  })

  depends_on = [google_project_service.apis]
}

# =============================================================================
# PUB/SUB
# =============================================================================

# Topic principal
resource "google_pubsub_topic" "csv_processing" {
  name    = local.pubsub_topic_name
  project = var.project_id

  labels = merge(var.labels, {
    environment = var.environment
  })

  depends_on = [google_project_service.apis]
}

# Dead Letter Topic
resource "google_pubsub_topic" "dead_letter" {
  name    = local.dlq_topic_name
  project = var.project_id

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "dead-letter-queue"
  })

  depends_on = [google_project_service.apis]
}

# Subscription con retry y DLQ
resource "google_pubsub_subscription" "csv_processing_sub" {
  name    = "${local.pubsub_topic_name}-sub"
  topic   = google_pubsub_topic.csv_processing.name
  project = var.project_id

  ack_deadline_seconds = 300  # 5 minutos para procesar CSVs grandes

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  labels = merge(var.labels, {
    environment = var.environment
  })
}

# Subscription para DLQ
resource "google_pubsub_subscription" "dlq_sub" {
  name    = "${local.dlq_topic_name}-sub"
  topic   = google_pubsub_topic.dead_letter.name
  project = var.project_id

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días

  labels = merge(var.labels, {
    environment = var.environment
  })
}

# Permisos para Storage Notification
data "google_storage_project_service_account" "gcs_account" {
  project = var.project_id
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic   = google_pubsub_topic.csv_processing.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
  project = var.project_id
}

# =============================================================================
# STORAGE NOTIFICATION
# =============================================================================

resource "google_storage_notification" "csv_notification" {
  bucket         = google_storage_bucket.csv_bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.csv_processing.id

  event_types = [
    "OBJECT_FINALIZE"
  ]

  # Solo notificar para archivos CSV
  object_name_prefix = ""

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# =============================================================================
# BIGTABLE
# =============================================================================

resource "google_bigtable_instance" "csv_data" {
  name                = local.bigtable_instance_id
  project             = var.project_id
  deletion_protection = var.bigtable_deletion_protection

  cluster {
    cluster_id   = "${local.bigtable_instance_id}-cluster"
    zone         = var.zone
    num_nodes    = var.bigtable_num_nodes
    storage_type = var.bigtable_storage_type
  }

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "csv-data"
  })

  depends_on = [google_project_service.apis]
}

resource "google_bigtable_table" "csv_records" {
  name          = local.bigtable_table_id
  instance_name = google_bigtable_instance.csv_data.name
  project       = var.project_id

  # Column Family para datos del CSV
  column_family {
    family = "data"
  }

  # Column Family para metadatos
  column_family {
    family = "metadata"
  }

  depends_on = [google_bigtable_instance.csv_data]
}

# GC Policy
resource "google_bigtable_gc_policy" "metadata_retention" {
  instance_name = google_bigtable_instance.csv_data.name
  table         = google_bigtable_table.csv_records.name
  column_family = "metadata"
  project       = var.project_id

  max_age {
    duration = "${var.bigtable_retention_days * 24 * 3600}s"
  }
}

# =============================================================================
# CLOUD FUNCTIONS - SOURCE BUCKET
# =============================================================================

resource "google_storage_bucket" "function_source" {
  name                        = "${var.project_id}-csv-functions-source-${var.environment}"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "function-source"
  })

  depends_on = [google_project_service.apis]
}

# =============================================================================
# CLOUD FUNCTION - CSV RECEIVER (HTTP)
# =============================================================================

data "archive_file" "receiver_source" {
  type        = "zip"
  source_dir  = "${path.module}/cloud-functions/csv-receiver"
  output_path = "${path.module}/csv-receiver.zip"
}

resource "google_storage_bucket_object" "receiver_code" {
  name   = "csv-receiver-${data.archive_file.receiver_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.receiver_source.output_path
}

resource "google_cloudfunctions2_function" "csv_receiver" {
  name        = local.receiver_name
  location    = var.region
  project     = var.project_id
  description = "Recibe CSV via HTTP y lo guarda en Cloud Storage"

  build_config {
    runtime     = "python311"
    entry_point = "upload_csv"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.receiver_code.name
      }
    }
  }

  service_config {
    max_instance_count    = var.function_max_instances
    min_instance_count    = var.function_min_instances
    available_memory      = "512M"
    timeout_seconds       = 120
    service_account_email = google_service_account.receiver_sa.email

    environment_variables = {
      PROJECT_ID    = var.project_id
      BUCKET_NAME   = local.bucket_name
      PUBSUB_TOPIC  = local.pubsub_topic_name
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "csv-receiver"
  })

  depends_on = [
    google_project_service.apis,
    google_storage_bucket.csv_bucket,
    google_project_iam_member.receiver_storage_admin,
    google_project_iam_member.receiver_pubsub_publisher,
    google_project_iam_member.receiver_logging
  ]
}

# Permitir invocación pública del receiver
resource "google_cloud_run_service_iam_member" "receiver_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.csv_receiver.name
  role     = "roles/run.invoker"
  member   = "allUsers"

  depends_on = [google_cloudfunctions2_function.csv_receiver]
}

# =============================================================================
# CLOUD FUNCTION - CSV PROCESSOR (Pub/Sub)
# =============================================================================

data "archive_file" "processor_source" {
  type        = "zip"
  source_dir  = "${path.module}/cloud-functions/csv-processor"
  output_path = "${path.module}/csv-processor.zip"
}

resource "google_storage_bucket_object" "processor_code" {
  name   = "csv-processor-${data.archive_file.processor_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.processor_source.output_path
}

resource "google_cloudfunctions2_function" "csv_processor" {
  name        = local.processor_name
  location    = var.region
  project     = var.project_id
  description = "Procesa CSV desde Storage y carga datos a BigTable"

  build_config {
    runtime     = "python311"
    entry_point = "process_csv"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.processor_code.name
      }
    }
  }

  service_config {
    max_instance_count    = var.function_max_instances
    min_instance_count    = var.function_min_instances
    available_memory      = var.processor_memory
    timeout_seconds       = var.processor_timeout
    service_account_email = google_service_account.processor_sa.email

    environment_variables = {
      PROJECT_ID        = var.project_id
      BIGTABLE_INSTANCE = local.bigtable_instance_id
      BIGTABLE_TABLE    = local.bigtable_table_id
      BUCKET_NAME       = local.bucket_name
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.csv_processing.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  labels = merge(var.labels, {
    environment = var.environment
    purpose     = "csv-processor"
  })

  depends_on = [
    google_project_service.apis,
    google_bigtable_table.csv_records,
    google_project_iam_member.processor_storage_viewer,
    google_project_iam_member.processor_bigtable_user,
    google_project_iam_member.processor_pubsub_subscriber,
    google_project_iam_member.processor_logging
  ]
}

# Permisos para que Eventarc invoque el processor
resource "google_cloud_run_service_iam_member" "processor_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.csv_processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.processor_sa.email}"

  depends_on = [google_cloudfunctions2_function.csv_processor]
}

# Permisos para Pub/Sub Service Agent
data "google_project" "project" {
  project_id = var.project_id
}

resource "google_cloud_run_service_iam_member" "pubsub_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.csv_processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  depends_on = [google_cloudfunctions2_function.csv_processor]
}

# Permisos para Eventarc Service Agent
resource "google_cloud_run_service_iam_member" "eventarc_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.csv_processor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-eventarc.iam.gserviceaccount.com"

  depends_on = [google_cloudfunctions2_function.csv_processor]
}
