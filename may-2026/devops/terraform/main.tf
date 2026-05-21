terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Core Compute API Enablement
resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# Network Topology Configuration
resource "google_compute_network" "iii_vpc" {
  name                    = "iii-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

resource "google_compute_subnetwork" "private" {
  name                     = "iii-private-subnet"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = var.region
  network                  = google_compute_network.iii_vpc.id
  private_ip_google_access = true
}

# Nat Gateway for Egress Internet Connection (Private VMs)
resource "google_compute_router" "nat_router" {
  name    = "iii-nat-router"
  network = google_compute_network.iii_vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "iii-cloud-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

# Firewall Infrastructure Rules
resource "google_compute_firewall" "allow_http_to_gateway" {
  name    = "fw-allow-http-to-gateway"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gateway"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "fw-allow-ssh-all"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal" {
  name    = "fw-allow-internal"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.1.0/24"]
}

# Compute Nodes Configuration
resource "google_compute_instance" "gateway" {
  name         = "vm-gateway"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["gateway"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = "10.0.1.4"
    access_config {} # Gateway receives public IPv4 allocation
  }

  metadata_startup_script = file("${path.module}/../scripts/setup-gateway.sh")

  depends_on = [
    google_compute_subnetwork.private,
    google_compute_firewall.allow_http_to_gateway,
    google_compute_firewall.allow_ssh,
    google_compute_firewall.allow_internal,
  ]
}

resource "google_compute_instance" "engine" {
  name         = "vm-engine"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = "10.0.1.10"
  }

  metadata_startup_script = file("${path.module}/../scripts/setup-engine.sh")

  depends_on = [
    google_compute_subnetwork.private,
    google_compute_router_nat.nat,
  ]
}

resource "google_compute_instance" "caller" {
  name         = "vm-caller"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = "10.0.1.20"
  }

  metadata_startup_script = file("${path.module}/../scripts/setup-caller.sh")

  depends_on = [
    google_compute_subnetwork.private,
    google_compute_router_nat.nat,
  ]
}

resource "google_compute_instance" "inference" {
  name         = "vm-inference"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 40 # Gemma model caching requires additional filesystem space
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = "10.0.1.30"
  }

  metadata_startup_script = file("${path.module}/../scripts/setup-inference.sh")

  depends_on = [
    google_compute_subnetwork.private,
    google_compute_router_nat.nat,
  ]
}
