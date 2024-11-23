resource "azurerm_resource_group" "rg_app_gateway" {
  name     = "rg-app-gateway-${var.prefix}"
  location = "northeurope"
}

resource "azurerm_virtual_network" "public" {
  name                = "vnet-${var.prefix}"
  address_space = ["10.0.0.0/24"]
  location            = azurerm_resource_group.rg_app_gateway.location
  resource_group_name = azurerm_resource_group.rg_app_gateway.name
}

resource "azurerm_service_plan" "service_plan" {
  name                = "asp-dev-qa-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg_app_gateway.name
  location            = azurerm_resource_group.rg_app_gateway.location
  sku_name            = "B2"
  os_type             = "Windows"
}

resource "azurerm_windows_web_app" "app_service_dev" {
  for_each            = local.app_services
  name                = "ase-${each.key}-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg_app_gateway.name
  location            = azurerm_service_plan.service_plan.location
  service_plan_id     = azurerm_service_plan.service_plan.id

  site_config {}
}

resource "azurerm_public_ip" "app_gateway_front_ip" {
  name                = "pip-agwy-front-ip-${var.prefix}"
  location            = azurerm_resource_group.rg_app_gateway.location
  resource_group_name = azurerm_resource_group.rg_app_gateway.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_subnet" "app_gateway_subnet" {
  name                 = "subnet-agwy-${var.prefix}"
  resource_group_name  = azurerm_resource_group.rg_app_gateway.name
  virtual_network_name = azurerm_virtual_network.public.name
  address_prefixes = ["10.0.0.128/26"]
}

resource "azurerm_application_gateway" "main" {
  name                = "agwy-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg_app_gateway.name
  location            = azurerm_resource_group.rg_app_gateway.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "agwy-ipc-${var.prefix}"
    subnet_id = azurerm_subnet.app_gateway_subnet.id
  }

  frontend_port {
    name = local.frontend_port_name
    port = 443
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.app_gateway_front_ip.id
  }

  dynamic "backend_address_pool" {
    for_each = local.routing_settings
    content {
      name = backend_address_pool.value.backend_address_pool_name
      fqdns = [backend_address_pool.value.default_host_name]
    }
  }

  backend_http_settings {
    name                  = local.backend_http_settings_name
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 300
  }

  dynamic "http_listener" {
    for_each = local.routing_settings
    content {
      name                           = http_listener.value.http_listener_name
      frontend_ip_configuration_name = local.frontend_ip_configuration_name
      frontend_port_name             = local.frontend_port_name
      protocol                       = "Https"
      ssl_certificate_name           = local.ssl_certificate_name
      host_name                      = http_listener.value.host_name
    }
  }

  ssl_certificate {
    name     = local.ssl_certificate_name
    data = filebase64("${path.module}/${local.ssl_certificate_name}")
    password = var.ssl_certificate_password
  }

  dynamic "request_routing_rule" {
    for_each = local.routing_settings
    content {
      name                       = request_routing_rule.value.request_routing_rule_name
      rule_type                  = request_routing_rule.value.rule_type
      http_listener_name         = request_routing_rule.value.http_listener_name
      backend_address_pool_name  = request_routing_rule.value.backend_address_pool_name
      backend_http_settings_name = local.backend_http_settings_name
      priority                   = request_routing_rule.value.priority
    }
  }

  dynamic "probe" {
    for_each = local.routing_settings
    content {
      name                                      = "probe-${probe.value.environment}"
      protocol                                  = "Https"
      path                                      = "/"
      interval                                  = 30
      timeout                                   = 30
      unhealthy_threshold                       = 3
      host                                      = probe.value.default_host_name
      pick_host_name_from_backend_http_settings = false
      match {
        status_code = [200, 399]
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "example_assoc" {
  subnet_id                 = azurerm_subnet.app_gateway_subnet.id
  network_security_group_id = azurerm_network_security_group.public.id
}