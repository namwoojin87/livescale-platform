locals {
  app_name = "livescale-api"
  selector_labels = {
    "app.kubernetes.io/name" = "livescale-api"
  }
  common_labels = merge(local.selector_labels, {
    "app.kubernetes.io/part-of"    = "livescale"
    "app.kubernetes.io/managed-by" = "terraform"
  })
}

resource "kubernetes_namespace_v1" "livescale" {
  metadata {
    name   = var.namespace
    labels = local.common_labels
  }
}

resource "kubernetes_deployment_v1" "api" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.livescale.metadata[0].name
    labels    = local.common_labels
  }

  wait_for_rollout = true

  spec {
    replicas = var.initial_replicas

    selector {
      match_labels = local.selector_labels
    }

    strategy {
      type = "RollingUpdate"

      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = local.common_labels
      }

      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = local.selector_labels
          }
        }

        container {
          name              = local.app_name
          image             = var.image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "WATCH_WORK_ITERATIONS"
            value = tostring(var.watch_work_iterations)
          }

          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            initial_delay_seconds = 2
            period_seconds        = 5
            timeout_seconds       = 2
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 10001
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "api" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.livescale.metadata[0].name
    labels    = local.common_labels
  }

  spec {
    selector = local.selector_labels
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "api" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.livescale.metadata[0].name
    labels    = local.common_labels
  }

  wait_for_load_balancer = false

  spec {
    ingress_class_name = "traefik"

    rule {
      host = var.ingress_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.api.metadata[0].name

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "api" {
  metadata {
    name      = local.app_name
    namespace = kubernetes_namespace_v1.livescale.metadata[0].name
    labels    = local.common_labels
  }

  spec {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.api.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = var.cpu_target_percent
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }

        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
      }

      scale_down {
        stabilization_window_seconds = 60
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }
      }
    }
  }
}
