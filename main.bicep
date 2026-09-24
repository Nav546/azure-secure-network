// Secured Azure network: storage reachable ONLY through a private endpoint.
targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short prefix used in resource names')
@maxLength(8)
param prefix string = 'secnet'

@description('Size of the small test VM')
param vmSize string = 'Standard_B1s'

@description('Admin username for the test VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the test VM (password login is disabled)')
param adminSshPublicKey string

var vnetName = '${prefix}-vnet'
var appSubnetPrefix = '10.0.1.0/24'
var peSubnetPrefix = '10.0.2.0/24'
var storageName = toLower('${prefix}${uniqueString(resourceGroup().id)}')

// ---------- Network security groups ----------

// App subnet: explicitly deny anything from the internet.
resource appNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-app-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Endpoint subnet: only the app subnet may reach the private endpoint, only on HTTPS.
resource peNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-pe-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-App-HTTPS'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-Other-VNet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------- Virtual network ----------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: {
            id: appNsg.id
          }
        }
      }
      {
        name: 'snet-endpoints'
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: {
            id: peNsg.id
          }
          // Makes the NSG above actually apply to private endpoints.
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// ---------- Storage account (public door locked) ----------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

// ---------- Private DNS + private endpoint ----------

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

// Without this link, the VNet would still resolve storage to its PUBLIC address.
resource blobDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource blobPe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${prefix}-blob-pe'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// Auto-creates the A record (storagename -> 10.0.2.x) in the private zone.
resource blobPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: blobPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobDnsZone.id
        }
      }
    ]
  }
}

// ---------- Test VM (no public IP) ----------

resource vmNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${prefix}-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: '${prefix}-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${prefix}-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// ---------- Outputs used by the pipeline tests ----------

output storageAccountName string = storage.name
output blobHost string = '${storage.name}.blob.${environment().suffixes.storage}'
output vmName string = vm.name
