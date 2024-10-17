# Configure the Google Cloud provider
provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = file(var.service_account_key)
}

# Create a VPC
resource "google_compute_network" "vpc" {
  name                    = "openwebui-vpc"
  auto_create_subnetworks = false
}

# Create a subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "openwebui-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Create a GCS bucket
resource "google_storage_bucket" "bucket" {
  name                        = "openwebui-storage-${var.project_id}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  # Use the custom service account for the bucket
  lifecycle {
    ignore_changes = [
      labels,
    ]
  }
}

resource "google_storage_bucket_iam_member" "bucket_access" {
  bucket = google_storage_bucket.bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gke_sa.email}"
}

# Create a GKE cluster
resource "google_container_cluster" "primary" {
  name     = "openwebui-cluster"
  location = var.region

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  # Use the custom service account for the cluster
  node_config {
    service_account = google_service_account.gke_sa.email
  }
  deletion_protection = false  # Add this line
}

# Create a separately managed node pool 
resource "google_container_node_pool" "primary_nodes" {
  name       = "openwebui-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_num_nodes

  node_config {
    service_account = google_service_account.gke_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    machine_type = "n1-standard-1"
    tags         = ["gke-node", "openwebui-gke"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# Retrieve an access token as the Terraform runner
data "google_client_config" "provider" {}

data "google_container_cluster" "my_cluster" {
  name     = google_container_cluster.primary.name
  location = var.region
}

provider "kubernetes" {
  host  = "https://${data.google_container_cluster.my_cluster.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    data.google_container_cluster.my_cluster.master_auth[0].cluster_ca_certificate,
  )
}

# Create a Regional Persistent Disk for Ollama
resource "google_compute_region_disk" "ollama_disk" {
  name          = "ollama-disk"
  type          = "pd-standard"
  region        = var.region 
  size          = 200  # Increase to 200 GB
  replica_zones = ["${var.region}-a", "${var.region}-b"]
}

# Create a PersistentVolume for Ollama
resource "kubernetes_persistent_volume" "ollama_pv" {
  metadata {
    name = "ollama-pv"
  }
  spec {
    capacity = {
      storage = "200Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      gce_persistent_disk {
        pd_name = google_compute_region_disk.ollama_disk.name
        fs_type = "ext4"
      }
    }
    storage_class_name               = "standard"
    persistent_volume_reclaim_policy = "Delete"
  }
}

# Create a PersistentVolumeClaim for Ollama
resource "kubernetes_persistent_volume_claim" "ollama_pvc" {
  metadata {
    name = "ollama-pvc"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "200Gi"  # Update to match the new disk size
      }
    }
    volume_name = kubernetes_persistent_volume.ollama_pv.metadata[0].name
  }
}

# Deploy Ollama
resource "kubernetes_deployment" "ollama" {
  metadata {
    name = "ollama"
    labels = {
      app = "ollama"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "ollama"
      }
    }

    template {
      metadata {
        labels = {
          app = "ollama"
        }
      }

      spec {
        container {
          image = "ollama/ollama:latest"
          name  = "ollama"

          port {
            container_port = 11434
          }

          volume_mount {
            name       = "ollama-storage"
            mount_path = "/root/.ollama"
          }
        }

        volume {
          name = "ollama-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ollama_pvc.metadata[0].name
          }
        }
      }
    }
  }
}

# Expose Ollama service
resource "kubernetes_service" "ollama" {
  metadata {
    name = "ollama"
  }
  spec {
    selector = {
      app = kubernetes_deployment.ollama.metadata[0].labels.app
    }
    port {
      port        = 11434
      target_port = 11434
    }
    type = "ClusterIP"
  }
}

# Create a Regional Persistent Disk for Open WebUI
resource "google_compute_region_disk" "openwebui_disk" {
  name          = "openwebui-disk"
  type          = "pd-standard"
  region        = var.region 
  size          = 200  # Increase to 200 GB
  replica_zones = ["${var.region}-a", "${var.region}-b"]
}

# Create a PersistentVolume for Open WebUI
resource "kubernetes_persistent_volume" "openwebui_pv" {
  metadata {
    name = "openwebui-pv"
  }
  spec {
    capacity = {
      storage = "200Gi"  # Update to match the new disk size
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      gce_persistent_disk {
        pd_name = google_compute_region_disk.openwebui_disk.name
        fs_type = "ext4"
      }
    }
    storage_class_name               = "standard"
    persistent_volume_reclaim_policy = "Delete"
  }
}

# Create a PersistentVolumeClaim for Open WebUI
resource "kubernetes_persistent_volume_claim" "openwebui_pvc" {
  metadata {
    name = "openwebui-pvc"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "200Gi"  # Update to match the new disk size
      }
    }
    volume_name = kubernetes_persistent_volume.openwebui_pv.metadata[0].name
  }
}

# Deploy Open WebUI
resource "kubernetes_deployment" "openwebui" {
  metadata {
    name = "openwebui"
    labels = {
      app = "openwebui"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "openwebui"
      }
    }

    template {
      metadata {
        labels = {
          app = "openwebui"
        }
      }

      spec {
        container {
          image = "ghcr.io/open-webui/open-webui:main"
          name  = "openwebui"

          port {
            container_port = 8080
          }

          env {
            name  = "OLLAMA_API_BASE_URL"
            value = "http://ollama:11434/api"
          }

          volume_mount {
            name       = "openwebui-storage"
            mount_path = "/app/backend/data"
          }
        }

        volume {
          name = "openwebui-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openwebui_pvc.metadata[0].name
          }
        }
      }
    }
  }
}

# Expose Open WebUI service
resource "kubernetes_service" "openwebui" {
  metadata {
    name = "openwebui"
  }
  spec {
    selector = {
      app = kubernetes_deployment.openwebui.metadata[0].labels.app
    }
    port {
      port        = 80
      target_port = 8080
    }
    type = "LoadBalancer"
  }
}

# Variables
variable "project_id" {
  description = "GCP Project ID"
}

variable "region" {
  description = "GCP region"
  default     = "europe-west1"
}

variable "gke_num_nodes" {
  default     = 2
  description = "Number of GKE nodes"
}

variable "service_account_key" {
  description = "Path to the service account key file"
}

# Outputs
output "kubernetes_cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE Cluster Name"
}

output "kubernetes_cluster_host" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE Cluster Host"
}

output "gcs_bucket_name" {
  value       = google_storage_bucket.bucket.name
  description = "GCS Bucket Name"
}

output "openwebui_external_ip" {
  value       = kubernetes_service.openwebui.status[0].load_balancer[0].ingress[0].ip
  description = "External IP address for Open WebUI"
}

# Create a custom service account for the GKE nodes
resource "google_service_account" "gke_sa" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"
}

# Grant necessary roles to the service account
resource "google_project_iam_member" "gke_sa_roles" {
  for_each = toset([
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}
