variable "project" {
  description = "GCP ProjectID"
}

variable "region" {
  description = "GCP Region to use"
}

variable "fqdn" {
  description = "Hostname used by glb for ssl certificate"
}

provider "google" {
  project = var.project
}

resource "google_service_account" "runfront" {
  account_id   = "vpcsc-run-front"
  display_name = "vpcsc-run-front"
}

resource "google_service_account" "runback" {
  account_id   = "vpcsc-run-back"
  display_name = "vpcsc-run-back"
}


resource "google_service_account" "sub" {
  account_id   = "vpcsc-sub"
  display_name = "vpcsc-sub"
}


resource "google_pubsub_topic_iam_member" "member" {
  project = var.project
  topic   = google_pubsub_topic.topic.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.runfront.email}"
}

resource "google_project_iam_member" "log-front" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runfront.email}"
}

resource "google_project_iam_member" "datastore" {
  project = var.project
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runback.email}"
}

resource "google_project_iam_member" "log-back" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runback.email}"
}

resource "google_pubsub_topic" "topic" {
  name = "vpcsc-topic"
}

resource "google_vpc_access_connector" "connector" {
  name = "vpcsc-con"
  subnet {
    name = google_compute_subnetwork.vpcsc.name
  }
  region = var.region
}

resource "google_compute_subnetwork" "vpcsc" {
  name                     = "vpcsc-con"
  ip_cidr_range            = "10.2.0.0/28"
  region                   = var.region
  network                  = google_compute_network.vpcsc.id
  private_ip_google_access = true
}

resource "google_compute_network" "vpcsc" {
  name                    = "vpcsc-net"
  auto_create_subnetworks = false
}

resource "google_dns_response_policy" "restricted" {
  provider = google-beta

  project              = var.project
  response_policy_name = "restricted-googleapis"

  networks {
    network_url = google_compute_network.vpcsc.id
  }
}

resource "google_dns_response_policy_rule" "restricted" {
  provider = google-beta

  project         = var.project
  response_policy = google_dns_response_policy.restricted.response_policy_name
  rule_name       = "restricted-googleapis"
  dns_name        = "*.googleapis.com."

  local_data {
    local_datas {
      name    = "restricted.googleapis.com."
      type    = "A"
      ttl     = 300
      rrdatas = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
    }
  }
}

resource "google_dns_response_policy_rule" "restricted-cloudrun" {
  provider = google-beta

  project         = var.project
  response_policy = google_dns_response_policy.restricted.response_policy_name
  rule_name       = "restricted-run"
  dns_name        = "*.run.app."

  local_data {
    local_datas {
      name    = "restricted.googleapis.com."
      type    = "A"
      ttl     = 300
      rrdatas = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
    }
  }
}



resource "google_pubsub_subscription" "push" {
  name  = "vpcsc-sub-push"
  topic = google_pubsub_topic.topic.name

  ack_deadline_seconds = 20


  retry_policy {
    maximum_backoff = "600s"
    minimum_backoff = "10s"
  }

  push_config {
    push_endpoint = format("%s/push", google_cloud_run_service.pubsub_push.status[0].url)

    oidc_token {
      service_account_email = google_service_account.sub.email
      audience              = format("%s/push", google_cloud_run_service.pubsub_push.status[0].url)
    }

    attributes = {
      x-goog-version = "v1"
    }
  }
}

resource "google_cloud_run_service" "pubsub_submit" {
  name     = "pubsub-submit"
  location = var.region

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"        = "2"
        "run.googleapis.com/ingress"              = "internal-and-cloud-load-balancing"
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.connector.id
        "run.googleapis.com/vpc-access-egress"    = "all-traffic"
      }
    }

    spec {
      service_account_name = google_service_account.runfront.email
      containers {
        image = "eu.gcr.io/${var.project}/vpcsc-pubsub:latest"
        env {
          name  = "GOOGLE_PROJECT"
          value = var.project
        }
        env {
          name  = "TOPIC"
          value = google_pubsub_topic.topic.name
        }
      }
    }
  }
  autogenerate_revision_name = true
}

resource "google_cloud_run_service_iam_member" "member" {
  location = google_cloud_run_service.pubsub_push.location
  project  = google_cloud_run_service.pubsub_push.project
  service  = google_cloud_run_service.pubsub_push.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.sub.email}"
}

resource "google_cloud_run_service" "pubsub_push" {
  name     = "pubsub-push"
  location = var.region

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"        = "2"
        "run.googleapis.com/ingress"              = "internal-and-cloud-load-balancing"
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.connector.id
        "run.googleapis.com/vpc-access-egress"    = "all-traffic"
      }
    }

    spec {
      service_account_name = google_service_account.runback.email
      containers {
        image = "eu.gcr.io/${var.project}/vpcsc-pubsub:latest"
        env {
          name  = "GOOGLE_PROJECT"
          value = var.project
        }
        env {
          name  = "TOPIC"
          value = google_pubsub_topic.topic.name
        }
      }
    }
  }
  autogenerate_revision_name = true
}

resource "google_compute_region_network_endpoint_group" "submit" {
  name                  = "vpcsc-submit-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_service.pubsub_submit.name
  }
}


module "lb-http_serverless_negs" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "7.0.0"

  name    = "vpcsc"
  project = var.project

  ssl                             = true
  managed_ssl_certificate_domains = [var.fqdn]
  https_redirect                  = true
  backends = {
    default = {
      description             = null
      protocol                = "HTTP"
      port_name               = "http"
      enable_cdn              = false
      compression_mode        = "DISABLED"
      custom_request_headers  = null
      custom_response_headers = null
      security_policy         = null


      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        {
          group = google_compute_region_network_endpoint_group.submit.id
        }
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = null
        oauth2_client_secret = null
      }
    }
  }
}
