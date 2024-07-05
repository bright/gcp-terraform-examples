terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.36.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.4.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.2"
    }
  }
}

provider "google" {

}

variable "deploy_env" {
  default = "stage"
}

variable "billing_account" {
  default = "011E25-D2A15A-01891C"
}

variable "organisation_id" {
  default = "1084031091051"
}

resource "google_project" "simple-app-engine" {
  name            = "${var.deploy_env}-simple-gae"
  project_id      = "${var.deploy_env}-simple-gae"
  org_id          = var.organisation_id
  billing_account = var.billing_account
}

resource "google_project_service" "enabled_services" {
  for_each = toset([
    "secretmanager.googleapis.com",
  ])
  project = google_project.simple-app-engine.project_id
  service = each.key
}

variable "location_id" {
  default = "europe-central2"
}

resource "google_app_engine_application" "app-engine-app" {
  project       = google_project.simple-app-engine.project_id
  location_id   = var.location_id
  database_type = "CLOUD_DATASTORE_COMPATIBILITY"
}

resource "google_service_account" "app-engine-app-service-account" {
  project    = google_project.simple-app-engine.project_id
  account_id = google_project.simple-app-engine.name
}

resource "google_secret_manager_secret" "first-api-key" {
  project   = google_project.simple-app-engine.project_id
  secret_id = "${var.deploy_env}-first-api-key"
  replication {
    auto {
    }
  }
}
resource "google_secret_manager_secret_iam_member" "gae-access-first-api-key" {
  secret_id = google_secret_manager_secret.first-api-key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project.simple-app-engine.project_id}@appspot.gserviceaccount.com"
}

resource "google_secret_manager_secret" "second-api-key" {
  project   = google_project.simple-app-engine.project_id
  secret_id = "${var.deploy_env}-second-api-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "gae-access-second-api-key" {
  secret_id = google_secret_manager_secret.second-api-key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project.simple-app-engine.project_id}@appspot.gserviceaccount.com"
}

resource "google_secret_manager_secret" "third-api-key" {
  project   = google_project.simple-app-engine.project_id
  secret_id = "${var.deploy_env}-third-api-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "gae-access-third-api-key" {
  secret_id = google_secret_manager_secret.third-api-key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project.simple-app-engine.project_id}@appspot.gserviceaccount.com"
}

resource "google_secret_manager_secret" "forth-api-key" {
  project   = google_project.simple-app-engine.project_id
  secret_id = "${var.deploy_env}-forth-api-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "gae-access-forth-api-key" {
  secret_id = google_secret_manager_secret.forth-api-key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project.simple-app-engine.project_id}@appspot.gserviceaccount.com"
}

resource "google_logging_project_bucket_config" "_Default" {
  project    = google_project.simple-app-engine.project_id
  location  = "global"
  retention_days = 30
  bucket_id = "_Default"
  enable_analytics = true
}

#region Optional but in the domain of CICD

# can also be specified in yaml and CLI invocations files
resource "google_app_engine_standard_app_version" "latest_version" {
  project    = google_project.simple-app-engine.project_id
  version_id = "${google_project.simple-app-engine.name}-${data.archive_file.sample-node-app.output_md5}"
  service    = "default"
  runtime    = "nodejs20"

  #   service_account = google_service_account.app-engine-app-service-account.email

  entrypoint {
    shell = "node index.js"
  }
  env_variables = {
    DEPLOY_ENV = var.deploy_env
  }

  deployment {
    zip {
      source_url = "https://storage.googleapis.com/${google_storage_bucket_object.app.bucket}/${google_storage_bucket_object.app.name}"
    }
  }

  instance_class = "F1"

  automatic_scaling {
    min_idle_instances = 0
    standard_scheduler_settings {
      target_cpu_utilization        = 0.5
      target_throughput_utilization = 0.75
      min_instances                 = 0
      max_instances                 = 4
    }
  }
  inbound_services = ["INBOUND_SERVICE_WARMUP"]
  noop_on_destroy           = true
  delete_service_on_destroy = true
}

resource "google_app_engine_service_split_traffic" "default_version_split" {
  project         = google_project.simple-app-engine.project_id
  service         = google_app_engine_standard_app_version.latest_version.service
  migrate_traffic = var.deploy_env == "stage"
  split {
    allocations = {
      (google_app_engine_standard_app_version.latest_version.version_id) = 1
    }
    shard_by = "RANDOM"
  }
}

resource "google_app_engine_standard_app_version" "alpha_latest_version" {
  project    = google_project.simple-app-engine.project_id
  version_id = "${google_project.simple-app-engine.name}-${data.archive_file.sample-node-app.output_md5}"
  service    = "alpha"
  runtime    = "nodejs20"

  #   service_account = google_service_account.app-engine-app-service-account.email

  entrypoint {
    shell = "node index.js"
  }
  env_variables = {
    DEPLOY_ENV = var.deploy_env
  }

  deployment {
    zip {
      source_url = "https://storage.googleapis.com/${google_storage_bucket_object.app.bucket}/${google_storage_bucket_object.app.name}"
    }
  }

  instance_class = "F1"

  automatic_scaling {
    min_idle_instances = 0
  }
  inbound_services = ["INBOUND_SERVICE_WARMUP"]

  noop_on_destroy           = true
  delete_service_on_destroy = true
}

resource "google_app_engine_service_split_traffic" "alpha_version_split" {
  project         = google_project.simple-app-engine.project_id
  service         = google_app_engine_standard_app_version.alpha_latest_version.service
  migrate_traffic = var.deploy_env == "stage"
  split {
    allocations = {
      (google_app_engine_standard_app_version.alpha_latest_version.version_id) = 1
    }
    shard_by = "RANDOM"
  }
}

resource "google_app_engine_application_url_dispatch_rules" "alpha_rule" {
  project = google_project.simple-app-engine.project_id
  dispatch_rules {
    domain  = "alpha-dot-${google_app_engine_application.app-engine-app.default_hostname}"
    path    = "/*"
    service = google_app_engine_standard_app_version.alpha_latest_version.service
  }
  depends_on = [
    google_app_engine_application.app-engine-app, google_app_engine_standard_app_version.alpha_latest_version
  ]
}


# Not strictly required but makes it easier to showcase things working end to end
data "archive_file" "sample-node-app" {
  type        = "zip"
  source_dir  = "../sample-node-app"
  output_path = "../sample-node-app.zip"
}

resource "google_storage_bucket_object" "app" {
  name   = "app.zip"
  source = data.archive_file.sample-node-app.output_path
  bucket = google_app_engine_application.app-engine-app.code_bucket
}

output "app-engine-app-domain" {
  value = google_app_engine_application.app-engine-app.default_hostname
}

output "default-version-url" {
  value = "https://${google_app_engine_application.app-engine-app.default_hostname}"
}

output "alpha-version-url" {
  value = "https://alpha-dot-${google_app_engine_application.app-engine-app.default_hostname}"
}

# Shouldn't be used like this but this, it's just for demo
resource "google_secret_manager_secret_version" "first-api-key-version" {
  secret      = google_secret_manager_secret.first-api-key.id
  secret_data = "abc123"
}
resource "google_secret_manager_secret_version" "second-api-key-version" {
  secret      = google_secret_manager_secret.second-api-key.id
  secret_data = "567efg"
}
resource "google_secret_manager_secret_version" "third-api-key-version" {
  secret      = google_secret_manager_secret.third-api-key.id
  secret_data = "hij789"
}
resource "google_secret_manager_secret_version" "forth-api-key-version" {
  secret      = google_secret_manager_secret.forth-api-key.id
  secret_data = "xyz987"
}

#endregion
