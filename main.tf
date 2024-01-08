locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace     = join("-", [local.project_name, local.environment_name])
  domain_suffix = coalesce(var.infrastructure.domain_suffix, "cluster.local")
  network_id    = coalesce(var.infrastructure.network_id, "local-walrus")

  labels = {
    "walrus.seal.io/catalog-name"     = "terraform-docker-redis"
    "walrus.seal.io/project-id"       = local.project_id
    "walrus.seal.io/environment-id"   = local.environment_id
    "walrus.seal.io/resource-id"      = local.resource_id
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }

  master_name = format("%s-master", local.resource_name)

  architecture = coalesce(var.architecture, "standalone")
}

#
# Ensure
#

data "docker_network" "network" {
  name = local.network_id

  lifecycle {
    postcondition {
      condition     = self.driver == "bridge"
      error_message = "Docker network driver must be bridge"
    }
  }
}

locals {
  volume_refer_database_data = {
    schema = "docker:localvolumeclaim"
    params = {
      name = format("%s-%s", local.namespace, local.resource_name)
    }
  }

  password = coalesce(var.password, substr(md5(local.resource_name), 0, 16))
}

module "master" {
  source = "github.com/walrus-catalog/terraform-docker-containerservice?ref=v0.2.1&depth=1"

  context = {
    project = {
      name = local.project_name
      id   = local.project_id
    }
    environment = {
      name = local.environment_name
      id   = local.environment_id
    }
    resource = {
      name = local.master_name
      id   = local.resource_id
    }
  }

  infrastructure = {
    domain_suffix = local.domain_suffix
    network_id    = data.docker_network.network.id
  }

  containers = [
    {
      image     = join(":", ["bitnami/redis", var.engine_version])
      resources = var.resources
      envs = [
        {
          name  = "REDIS_PASSWORD"
          value = local.password
        },
        {
          name  = "REDIS_REPLICATION_MODE"
          value = "master"
        },
      ]
      mounts = [
        {
          path         = "/bitnami/redis/data"
          volume_refer = local.volume_refer_database_data # persistent
        },
      ]
      ports = [
        {
          internal = 6379
          protocol = "tcp"
        }
      ]
    }
  ]
}

module "slave" {
  count = local.architecture == "replication" ? var.replication_readonly_replicas : 0

  source = "github.com/walrus-catalog/terraform-docker-containerservice?ref=v0.2.1&depth=1"

  context = {
    project = {
      name = local.project_name
      id   = local.project_id
    }
    environment = {
      name = local.environment_name
      id   = local.environment_id
    }
    resource = {
      name = format("%s-slave-%d", local.resource_name, count.index)
      id   = local.resource_id
    }
  }

  infrastructure = {
    network_id = data.docker_network.network.id
  }

  containers = [
    {
      image     = join(":", ["bitnami/redis", var.engine_version])
      resources = var.resources
      envs = [
        {
          name  = "REDIS_REPLICATION_MODE"
          value = "slave"
        },
        {
          name  = "REDIS_PASSWORD"
          value = local.password
        },
        {
          name  = "REDIS_MASTER_PASSWORD"
          value = local.password
        },
        {
          name  = "REDIS_MASTER_HOST"
          value = format("%s.%s.svc.%s", local.master_name, local.namespace, local.domain_suffix)

        },
      ]
      ports = [
        {
          internal = 6379
          protocol = "tcp"
        }
      ]
    }
  ]
}
