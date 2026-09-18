<#
.SYNOPSIS
    Stops an AKS cluster using the Automation Account's managed identity.

.DESCRIPTION
    Intended to run as an Azure Automation PowerShell runbook on a daily schedule.
    Authenticates with the Automation Account managed identity (system-assigned by
    default, or a user-assigned identity when ManagedIdentityClientId is supplied),
    then stops the target AKS cluster if it is not already stopped.

.NOTES
    Required modules in the Automation Account: Az.Accounts, Az.Aks.
    Required role for the identity: Azure Kubernetes Service Contributor Role
    (or Contributor) on the cluster or its resource group.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $ClusterName,

    [Parameter(Mandatory = $false)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $ManagedIdentityClientId
)

$ErrorActionPreference = 'Stop'

# Automation sandboxes share a disk-backed context by default; keep it in-process.
Disable-AzContextAutosave -Scope Process | Out-Null

Write-Output "Authenticating with managed identity..."
if ([string]::IsNullOrWhiteSpace($ManagedIdentityClientId)) {
    $connection = Connect-AzAccount -Identity
}
else {
    $connection = Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}

$context = Get-AzContext
Write-Output "Authenticated as '$($connection.Context.Account.Id)' on subscription '$($context.Subscription.Id)'."

$cluster = Get-AzAksCluster -ResourceGroupName $ResourceGroupName -Name $ClusterName

if ($cluster.PowerState.Code -eq 'Stopped') {
    Write-Output "Cluster '$ClusterName' is already stopped. Nothing to do."
    return
}

Write-Output "Stopping cluster '$ClusterName' in resource group '$ResourceGroupName'..."
Stop-AzAksCluster -ResourceGroupName $ResourceGroupName -Name $ClusterName | Out-Null

$cluster = Get-AzAksCluster -ResourceGroupName $ResourceGroupName -Name $ClusterName
Write-Output "Cluster '$ClusterName' power state is now '$($cluster.PowerState.Code)'."
