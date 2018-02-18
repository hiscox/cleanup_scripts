<#
.SYNOPSIS
  Azure automation script to scan all Bitbucket repositories for the given team
  and remove any webhooks and deploy keys for a deleted virtual machine.
  Designed to be triggered by Azure event grid on a resource delete event.
  The webhooks and deploy keys must have a description and label that matches
  the VM name. An automation credential called 'bitbucket' is required to access
  the API.
.PARAMETER WebhookData
  Post request from event grid on VM deletion event
.PARAMETER BitbucketTeam
  Name of the Bitbucket team to clean up
#>

param(
  [parameter(Mandatory = $false)]
  [object]$WebhookData,
  [parameter(Mandatory = $false)]
  [string]$BitbucketTeam
)
$ErrorActionPreference = "Stop"

$RequestBody = $WebhookData.RequestBody | ConvertFrom-Json
$Data = $RequestBody.data

function Get-Auth {
  $credential = Get-AutomationPSCredential -Name "bitbucket"
  $credPair = "$($credential.UserName):$($credential.GetNetworkCredential().Password)"
  $encodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($credPair))
  @{ Authorization = "Basic $encodedCredentials" }
}

function Get-PaginatedValues($page, $headers) {
  $start = $page
  Write-Output $start.values
  while ($start.PSObject.Properties.Match("next") -ne $null) {
    $start = Invoke-RestMethod -Method Get -Uri $start.next -Headers $headers -UseBasicParsing
    Write-Output $start.values
  }
}

function Get-AllRepositories([string]$team, $headers) {
  $reporesult = Invoke-RestMethod -Method Get -Uri "https://api.bitbucket.org/2.0/repositories/$team" -Headers $headers -UseBasicParsing
  Get-PaginatedValues -page $reporesult -headers $headers
}

function Get-Hooks([string]$team, [string]$reposlug, $headers) {
  $hookresult = Invoke-RestMethod -Method Get -Uri "https://api.bitbucket.org/2.0/repositories/$team/$reposlug/hooks" -Headers $headers -UseBasicParsing
  Get-PaginatedValues -page $hookresult -headers $headers
}

function Remove-Hook([string]$team, [string]$reposlug, [string]$uid, $headers) {
  Invoke-RestMethod -Method Delete -Uri "https://api.bitbucket.org/2.0/repositories/$team/$reposlug/hooks/$uid" -Headers $headers -UseBasicParsing
}

function Get-DeployKeys([string]$team, [string]$reposlug, $headers) {
  $result = Invoke-RestMethod -Method Get -Uri "https://api.bitbucket.org/1.0/repositories/$team/$reposlug/deploy-keys" -Headers $headers -UseBasicParsing
  Write-Output $result
}

function Remove-DeployKey([string]$team, [string]$reposlug, [string]$uid, $headers) {
  Invoke-RestMethod -Method Delete -Uri "https://api.bitbucket.org/1.0/repositories/$team/$reposlug/deploy-keys/$uid" -Headers $headers -UseBasicParsing
}

if ($Data.operationName -match "Microsoft.Compute/virtualMachines/delete" -and $Data.status -match "Succeeded" -and $Data.resourceUri.Contains("puppet")) {
  $vmname = $Data.resourceUri.split('/') | Select-Object -Last 1
  $auth = Get-Auth
  $repos = Get-AllRepositories -team $BitbucketTeam -headers $auth
  foreach ($repo in $repos) {
    Write-Output "Checking $($repo.slug)"
    Get-Hooks -team $BitbucketTeam -reposlug $repo.slug -headers $auth | ForEach-Object {
      if ($_.description -like $vmname) {
        Write-Output "----Deleting hook $($_.description)"
        Remove-Hook -team $BitbucketTeam -reposlug $repo.slug -uid $_.uuid -headers $auth
      }
    }
    Get-DeployKeys -team $BitbucketTeam -reposlug $repo.slug -headers $auth | ForEach-Object {
      if ($_.label -like $vmname) {
        Write-Output "----Deleting key $($_.label)"
        Remove-DeployKey -team $BitbucketTeam -reposlug $repo.slug -uid $_.pk -headers $auth
      }
    }
  }
}