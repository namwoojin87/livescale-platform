variable "kubeconfig_path" {
  description = "Absolute path to a kubeconfig for the LiveScale k3s cluster."
  type        = string
  sensitive   = true
}

variable "namespace" {
  description = "Kubernetes namespace for LiveScale resources."
  type        = string
  default     = "livescale"
}

variable "image" {
  description = "Preloaded container image used by the API Deployment."
  type        = string
  default     = "livescale-api:0.1.0"
}

variable "ingress_host" {
  description = "Host header routed to the LiveScale API by Traefik."
  type        = string
  default     = "livescale.local"
}

variable "initial_replicas" {
  description = "Initial Deployment replica count."
  type        = number
  default     = 2

  validation {
    condition     = var.initial_replicas >= 2 && var.initial_replicas <= 8
    error_message = "initial_replicas must be between 2 and 8."
  }
}

variable "min_replicas" {
  description = "Minimum HPA replica count."
  type        = number
  default     = 2

  validation {
    condition     = var.min_replicas >= 2
    error_message = "min_replicas must be at least 2."
  }
}

variable "max_replicas" {
  description = "Maximum HPA replica count."
  type        = number
  default     = 8

  validation {
    condition     = var.max_replicas >= 2 && var.max_replicas <= 20
    error_message = "max_replicas must be between 2 and 20."
  }
}

variable "cpu_target_percent" {
  description = "Target average CPU utilization for the HPA."
  type        = number
  default     = 60

  validation {
    condition     = var.cpu_target_percent >= 10 && var.cpu_target_percent <= 100
    error_message = "cpu_target_percent must be between 10 and 100."
  }
}

variable "watch_work_iterations" {
  description = "Bounded hash iterations performed by each watch request."
  type        = number
  default     = 5000

  validation {
    condition = (
      var.watch_work_iterations >= 1 &&
      var.watch_work_iterations <= 1000000 &&
      floor(var.watch_work_iterations) == var.watch_work_iterations
    )
    error_message = "watch_work_iterations must be an integer between 1 and 1000000."
  }
}
