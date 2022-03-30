resource "random_string" "number" {
  length  = 16
  upper   = false
  lower   = false
  number  = true
  special = false
}

provider "azurerm" {
  features {}
}

data "terraform_remote_state" "rg" {
  backend = "remote"

  config = {
    organization = "greensugarcake"
    workspaces = {
      name = var.resource-groups-workspace
    }
  }
}

data "terraform_remote_state" "aks" {
  backend = "remote"

  config = {
    organization = "greensugarcake"
    workspaces = {
      name = var.aks-cluster-workspace
    }
  }
}

module "key-vault" {
  source  = "kumarvna/key-vault/azurerm"
  version = "2.2.0"

  # By default, this module will not create a resource group and expect to provide 
  # a existing RG name to use an existing resource group. Location will be same as existing RG. 
  # set the argument to `create_resource_group = true` to create new resrouce.
  resource_group_name        = data.terraform_remote_state.rg.outputs.resource_group_kube_name
  key_vault_name             = "keyvault-${random_string.number.result}"
  key_vault_sku_pricing_tier = "premium"

  # Once `Purge Protection` has been Enabled it's not possible to Disable it
  # Deleting the Key Vault with `Purge Protection` enabled will schedule the Key Vault to be deleted
  # The default retention period is 90 days, possible values are from 7 to 90 days
  # use `soft_delete_retention_days` to set the retention period
  enable_purge_protection = false
  # soft_delete_retention_days = 90

  # Access policies for users, you can provide list of Azure AD users and set permissions.
  # Make sure to use list of user principal names of Azure AD users.
  access_policies = [
    {
      azure_ad_user_principal_names = [var.keyvault_admin]
      key_permissions               = ["get", "list"]
      secret_permissions            = ["get", "list"]
      certificate_permissions       = ["get", "import", "list"]
      storage_permissions           = ["backup", "get", "list", "recover"]
    },

    # Access policies for AD Groups
    # to enable this feature, provide a list of Azure AD groups and set permissions as required.
    #{
    #  azure_ad_group_names    = ["ADGroupName1", "ADGroupName2"]
    #  key_permissions         = ["get", "list"]
    #  secret_permissions      = ["get", "list"]
    #  certificate_permissions = ["get", "import", "list"]
    #  storage_permissions     = ["backup", "get", "list", "recover"]
    #},

    # Access policies for Azure AD Service Principlas
    # To enable this feature, provide a list of Azure AD SPN and set permissions as required.
    {
      azure_ad_service_principal_names = [data.terraform_remote_state.aks.outputs.aks_identity_name]
      key_permissions                  = ["get", "list"]
      secret_permissions               = ["get", "list"]
      certificate_permissions          = ["get", "import", "list"]
      storage_permissions              = ["backup", "get", "list", "recover"]
    }
  ]

  # Create a required Secrets as per your need.
  # When you Add `usernames` with empty password this module creates a strong random password
  # use .tfvars file to manage the secrets as variables to avoid security issues.
  secrets = {
    "secret1" = var.sample_secret
  }

  keys = {
    "key1" = var.sample_public_key
  }

  # Creating Private Endpoint requires, VNet name and address prefix to create a subnet
  # By default this will create a `privatelink.vaultcore.azure.net` DNS zone. 
  # To use existing private DNS zone specify `existing_private_dns_zone` with valid zone name
  enable_private_endpoint = true
  existing_vnet_id        = data.terraform_remote_state.aks.outputs.kube_vnet_id
  existing_subnet_id      = data.azurerm_subnet.example.id
  # existing_private_dns_zone     = "demo.example.com"

  log_analytics_workspace_id = data.terraform_remote_state.aks.outputs.azurerm_log_analytics_workspace_id
}

#
# Reference DNS Zone for ACR
#
data "azurerm_private_dns_zone" "dnszone1" {
  count               = 1
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.terraform_remote_state.rg.outputs.resource_group_kube_name
  depends_on          = [module.key-vault]
}

# Create PDNSZ VNet link to kube vnet
resource "azurerm_private_dns_zone_virtual_network_link" "pdns-vnet-link" {
  name                  = "vnet-link-${data.terraform_remote_state.aks.outputs.kube_vnet_name}"
  resource_group_name   = data.terraform_remote_state.rg.outputs.resource_group_kube_name
  private_dns_zone_name = data.azurerm_private_dns_zone.dnszone1[0].name
  virtual_network_id    = data.terraform_remote_state.aks.outputs.hub_vnet_id
  registration_enabled  = true
}
