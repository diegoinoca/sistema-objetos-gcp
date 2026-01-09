# =============================================================================
# OUTPUTS - Sistema de Carga de CSV a BigTable
# =============================================================================

output "api_url" {
  description = "URL de la API para subir CSVs"
  value       = google_cloudfunctions2_function.csv_receiver.url
}

output "bucket_name" {
  description = "Nombre del bucket de Cloud Storage"
  value       = google_storage_bucket.csv_bucket.name
}

output "bucket_url" {
  description = "URL del bucket"
  value       = google_storage_bucket.csv_bucket.url
}

output "bigtable_instance" {
  description = "ID de la instancia de BigTable"
  value       = google_bigtable_instance.csv_data.name
}

output "bigtable_table" {
  description = "Nombre de la tabla de BigTable"
  value       = google_bigtable_table.csv_records.name
}

output "pubsub_topic" {
  description = "Topic de Pub/Sub"
  value       = google_pubsub_topic.csv_processing.name
}

output "receiver_function" {
  description = "Nombre de la función receiver"
  value       = google_cloudfunctions2_function.csv_receiver.name
}

output "processor_function" {
  description = "Nombre de la función processor"
  value       = google_cloudfunctions2_function.csv_processor.name
}

output "receiver_sa" {
  description = "Service Account del receiver"
  value       = google_service_account.receiver_sa.email
}

output "processor_sa" {
  description = "Service Account del processor"
  value       = google_service_account.processor_sa.email
}

output "useful_commands" {
  description = "Comandos útiles"
  value = <<-EOT

    # =========================================================================
    # COMANDOS ÚTILES
    # =========================================================================

    # Subir CSV via API
    curl -X POST "${google_cloudfunctions2_function.csv_receiver.url}" \
      -H "Content-Type: multipart/form-data" \
      -F "file=@datos.csv"

    # Subir CSV directamente al bucket
    gsutil cp datos.csv gs://${google_storage_bucket.csv_bucket.name}/

    # Ver logs del receiver
    gcloud functions logs read ${google_cloudfunctions2_function.csv_receiver.name} \
      --gen2 --region=${var.region} --limit=50

    # Ver logs del processor
    gcloud functions logs read ${google_cloudfunctions2_function.csv_processor.name} \
      --gen2 --region=${var.region} --limit=50

    # Configurar cbt
    echo "project = ${var.project_id}" > ~/.cbtrc
    echo "instance = ${google_bigtable_instance.csv_data.name}" >> ~/.cbtrc

    # Leer datos de BigTable
    cbt read ${google_bigtable_table.csv_records.name} count=10

    # Contar registros
    cbt count ${google_bigtable_table.csv_records.name}

  EOT
}

output "resources_summary" {
  description = "Resumen de recursos"
  value = {
    api_url  = google_cloudfunctions2_function.csv_receiver.url
    bucket   = google_storage_bucket.csv_bucket.name
    bigtable = {
      instance = google_bigtable_instance.csv_data.name
      table    = google_bigtable_table.csv_records.name
    }
    functions = {
      receiver  = google_cloudfunctions2_function.csv_receiver.name
      processor = google_cloudfunctions2_function.csv_processor.name
    }
  }
}
