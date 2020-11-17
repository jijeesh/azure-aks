resource random_string password {
  length                       = 12
  upper                        = true
  lower                        = true
  number                       = true
  special                      = true
# override_special             = "!@#$%&*()-_=+[]{}<>:?" # default
# Avoid characters that may cause shell scripts to break
  override_special             = "." 
}

resource random_string suffix {
  length                       = 4
  upper                        = false
  lower                        = true
  number                       = false
  special                      = false
}

locals {
# Making sure all character classes are represented, as random does not guarantee that  
  password                     = ".Az9${random_string.password.result}"
# suffix                       = random_string.suffix.result
  suffix                       = var.resource_suffix != "" ? lower(var.resource_suffix) : random_string.suffix.result
  environment                  = var.resource_environment != "" ? lower(var.resource_environment) : terraform.workspace
  resource_group               = "${lower(var.resource_prefix)}-${lower(local.environment)}-${lower(local.suffix)}"

  create_service_principal     = (var.aks_sp_application_id == "" || var.aks_sp_object_id == "" || var.aks_sp_application_secret == "") ? true : false
  # aks_sp_application_id        = local.create_service_principal ? module.service_principal.0.application_id : var.aks_sp_application_id
  # aks_sp_object_id             = local.create_service_principal ? module.service_principal.0.object_id : var.aks_sp_object_id
  # aks_sp_application_secret    = local.create_service_principal ? module.service_principal.0.secret : var.aks_sp_application_secret
  aks_sp_application_id        = var.aks_sp_application_id
  aks_sp_object_id             = var.aks_sp_object_id
  aks_sp_application_secret    = var.aks_sp_application_secret

  tags                         = map(
      "application",             "Kubernetes",
      "provisioner",             "terraform",
      "environment",             terraform.workspace,
      "shutdown",                "true",
      "suffix",                  local.suffix,
      "workspace",               terraform.workspace,
  )
}

# Usage: https://www.terraform.io/docs/providers/azurerm/d/client_config.html
data azurerm_client_config current {}
data azurerm_subscription primary {}

data http localpublicip {
# Get public IP address of the machine running this terraform template
  url                          = "https://ipinfo.io/ip"
}

resource azurerm_resource_group rg {
  name                         = local.resource_group
  location                     = var.location

  tags                         = local.tags
}

# resource "azurerm_key_vault" "ttconfig" {
#   name                         = "${lower(var.resource_prefix)}config${local.suffix}"
#   location                     = "${var.location}"
#   resource_group_name          = "${azurerm_resource_group.rg.name}"
#   enabled_for_disk_encryption  = true
#   tenant_id                    = "${data.azurerm_client_config.current.tenant_id}"

#   sku {
#     name                       = "standard"
#   }

#   access_policy {
#     tenant_id                  = "${data.azurerm_client_config.current.tenant_id}"
#     object_id                  = "${data.azuread_service_principal.tfidentity.object_id}"

#     certificate_permissions    = [
#       "create",
#       "delete",
#       "get",
#       "import",
#     ]

#     key_permissions            = [
#       "delete",
#       "get",
#     ]

#     secret_permissions         = [
#       "delete",
#       "get",
#     ]
#   }

#   access_policy {
#     tenant_id                  = "${data.azurerm_client_config.current.tenant_id}"
# # Microsoft.Azure.WebSites RP SPN (appId: abfa0a7c-a6b6-4736-8310-5855508787cd, objectId: f8daea97-62e7-4026-becf-13c2ea98e8b4) requires access to Key Vault
#     object_id                  = "f8daea97-62e7-4026-becf-13c2ea98e8b4"

#     certificate_permissions    = [
#       "get",
#     ]

#     key_permissions            = [
#       "get",
#     ]

#     secret_permissions         = [
#       "get",
#     ]
#   }

#   network_acls {
#     default_action             = "Deny"
#     bypass                     = "AzureServices"
#     ip_rules                   = [
#       "${var.admin_ips}",
#       "${chomp(data.http.localpublicip.body)}/32"
#     ]
#   }
  
#   tags                         = "${local.tags}"
# }

resource azurerm_container_registry acr {
  name                         = "${lower(var.resource_prefix)}reg${local.suffix}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  sku                          = "Basic"
  admin_enabled                = true
# georeplication_locations     = ["East US", "West Europe"]
 
  tags                         = local.tags
}

resource azurerm_log_analytics_workspace log_analytics {
  name                         = "${lower(var.resource_prefix)}alaworkspace${local.suffix}"
  # Doesn't deploy in all regions e.g. South India
  location                     = var.workspace_location
  resource_group_name          = azurerm_resource_group.rg.name
  sku                          = "Standalone"
  retention_in_days            = 90 
  
  tags                         = local.tags
}

module aks {
  source                       = "./modules/aks"
  name                         = "aks-${terraform.workspace}-${local.suffix}"

  sp_application_id            = local.aks_sp_application_id
  sp_application_secret        = local.aks_sp_application_secret
  sp_object_id                 = local.aks_sp_object_id
  admin_username               = "aksadmin"
  dns_prefix                   = "ew-aks"
  log_analytics_workspace_id   = azurerm_log_analytics_workspace.log_analytics.id
  node_subnet_id               = module.network.subnet_ids["nodes"]
  resource_group_name          = azurerm_resource_group.rg.name
  ssh_public_key_file          = var.ssh_public_key_file
}

module k8s {
  source                       = "./modules/kubernetes"

  kubernetes_client_certificate= module.aks.kubernetes_client_certificate
  kubernetes_client_key        = module.aks.kubernetes_client_key
  kubernetes_cluster_ca_certificate= module.aks.kubernetes_cluster_ca_certificate
  kubernetes_host              = module.aks.kubernetes_host

  depends_on                   = [module.aks]
}

module network {
  source                       = "./modules/network"
  resource_group_name          = azurerm_resource_group.rg.name
  subnets                      = [
    "nodes"
  ]
}

# module service_principal {
#   source                       = "./modules/app-registration"
#   name                         = "aks-${terraform.workspace}-${local.suffix}"

#   count                        = local.create_service_principal ? 1 : 0
# }