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
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }
  }
}

provider "google" {

}

variable "deploy_env" {
  default = "stage"
}

variable "image_tag" {
  default = "v2"
}

variable "billing_account" {
  default = "011E25-D2A15A-01891C"
}

variable "organisation_id" {
  default = "1084031091051"
}

variable "location_id" {
  default = "europe-central2"
}

variable "google_application_credentials_access_token" {
}

resource "google_project" "app-engine-to-cloud-run-migration" {
  name            = "${var.deploy_env}-gae-to-cloud-run"
  project_id      = "${var.deploy_env}-gae-to-cloud-run"
  org_id          = var.organisation_id
  billing_account = var.billing_account
}

resource "google_project_service" "enabled_services" {
  for_each = toset([
    "secretmanager.googleapis.com",
    "run.googleapis.com",
  ])
  project = google_project.app-engine-to-cloud-run-migration.project_id
  service = each.key
}

resource "google_app_engine_application" "app-engine-app" {
  project       = google_project.app-engine-to-cloud-run-migration.project_id
  location_id   = var.location_id
  database_type = "CLOUD_DATASTORE_COMPATIBILITY"
}

resource "google_service_account" "app-engine-app-service-account" {
  project    = google_project.app-engine-to-cloud-run-migration.project_id
  account_id = google_project.app-engine-to-cloud-run-migration.name
}

resource "google_secret_manager_secret" "first-api-key" {
  project   = google_project.app-engine-to-cloud-run-migration.project_id
  secret_id = "${var.deploy_env}-first-api-key"
  replication {
    auto {
    }
  }
  depends_on = [google_project_service.enabled_services]
}

resource "google_secret_manager_secret_iam_member" "gae-access-first-api-key" {
  secret_id = google_secret_manager_secret.first-api-key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project.app-engine-to-cloud-run-migration.project_id}@appspot.gserviceaccount.com"
}

resource "google_logging_project_bucket_config" "_Default" {
  project          = google_project.app-engine-to-cloud-run-migration.project_id
  location         = "global"
  retention_days   = 30
  bucket_id        = "_Default"
  enable_analytics = true
}

locals {
  service-image-host = "${google_artifact_registry_repository.service-images-repo.location}-docker.pkg.dev"
  service-image-uri  = "${local.service-image-host}/${google_project.app-engine-to-cloud-run-migration.project_id}/${google_artifact_registry_repository.service-images-repo.repository_id}/service"
}


provider "docker" {
  registry_auth {
    address = "https://${local.service-image-host}"
    config_file_content = jsonencode({
      credHelpers = {
        (local.service-image-host) = "gcloud"
      }
    })
  }
}

output "registry_address" {
  value = "https://${local.service-image-host}"
}

# Build the Docker image
resource "docker_image" "service-image-tag" {
  name = "${local.service-image-uri}:${var.image_tag}"
  build {
    context    = "${path.cwd}/../sample-node-app"
    dockerfile = "./Dockerfile"
    platform   = "linux/amd64"
  }
  depends_on = [google_artifact_registry_repository.service-images-repo]
}

# Push the Docker image
resource "docker_registry_image" "service-image-registry" {
  name          = docker_image.service-image-tag.name
  keep_remotely = true
  depends_on = [docker_registry_image.service-image-registry]
}

resource "google_artifact_registry_repository" "service-images-repo" {
  location      = var.location_id
  project       = google_project.app-engine-to-cloud-run-migration.project_id
  repository_id = google_project.app-engine-to-cloud-run-migration.name
  description   = "example docker repository"
  format        = "DOCKER"
  docker_config {
    immutable_tags = true
  }
}

resource "google_service_account" "cloud-run-service-account" {
  account_id = "${var.deploy_env}-service"
  project    = google_project.app-engine-to-cloud-run-migration.project_id
}


resource "google_cloud_run_v2_service" "service-run" {
  name     = "${var.deploy_env}-service"
  project  = google_project.app-engine-to-cloud-run-migration.project_id
  location = var.location_id

  template {
    containers {
      image = "${local.service-image-uri}:${var.image_tag}"
      env {
        name  = "DEPLOY_ENV"
        value = var.deploy_env
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = google_project.app-engine-to-cloud-run-migration.project_id
      }
    }

    service_account = google_service_account.cloud-run-service-account.email
  }
  depends_on = [docker_registry_image.service-image-registry]
}

# allow cloud run to read services
resource "google_secret_manager_secret_iam_member" "secret_access" {
  project = google_project.app-engine-to-cloud-run-migration.project_id
  secret_id = google_secret_manager_secret.first-api-key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud-run-service-account.email}"
}


# allow all users to call the service
resource "google_cloud_run_v2_service_iam_member" "anyone-can-invoke-cloud-run-service" {
  project  = google_project.app-engine-to-cloud-run-migration.project_id
  location = google_cloud_run_v2_service.service-run.location
  name     = google_cloud_run_v2_service.service-run.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

#region Optional but in the domain of CICD

# can also be specified in yaml and CLI invocations files
resource "google_app_engine_standard_app_version" "default_version" {
  project    = google_project.app-engine-to-cloud-run-migration.project_id
  version_id = "${google_project.app-engine-to-cloud-run-migration.name}-${data.archive_file.sample-node-app.output_md5}"
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
  project         = google_project.app-engine-to-cloud-run-migration.project_id
  service         = google_app_engine_standard_app_version.default_version.service
  migrate_traffic = var.deploy_env == "stage"
  split {
    allocations = {
      (google_app_engine_standard_app_version.default_version.version_id) = 1
    }
    shard_by = "RANDOM"
  }
}

resource "google_app_engine_standard_app_version" "alpha_version" {
  project    = google_project.app-engine-to-cloud-run-migration.project_id
  version_id = "${google_project.app-engine-to-cloud-run-migration.name}-${data.archive_file.sample-node-app.output_md5}"
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


  inbound_services = ["INBOUND_SERVICE_WARMUP"]

  noop_on_destroy           = true
  delete_service_on_destroy = true
  depends_on = [google_app_engine_standard_app_version.default_version]
}

resource "google_app_engine_service_split_traffic" "alpha_version_split" {
  project         = google_project.app-engine-to-cloud-run-migration.project_id
  service         = google_app_engine_standard_app_version.alpha_version.service
  migrate_traffic = var.deploy_env == "stage"
  split {
    allocations = {
      (google_app_engine_standard_app_version.alpha_version.version_id) = 1
    }
    shard_by = "RANDOM"
  }
}

resource "google_app_engine_application_url_dispatch_rules" "alpha_rule" {
  project = google_project.app-engine-to-cloud-run-migration.project_id
  dispatch_rules {
    domain  = "alpha-dot-${google_app_engine_application.app-engine-app.default_hostname}"
    path    = "/*"
    service = google_app_engine_standard_app_version.alpha_version.service
  }
  depends_on = [
    google_app_engine_application.app-engine-app, google_app_engine_standard_app_version.alpha_version
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
#endregion
