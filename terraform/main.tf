# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
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
  name     = "openwebui-storage-${var.project_id}"
  location = var.region
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
}

# Create a separately managed node pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "openwebui-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_num_nodes

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only",
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
  default     = "us-central1"
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
  value       = kubernetes_service.openwebui.status.0.load_balancer.0.ingress.0.ip
  description = "External IP address for Open WebUI"
}