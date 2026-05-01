# unlockBranch.ps1

# Variables (update these to match your environment)
$Pat = "FRDrgyj11QhV5T3T3TfTgsMeARbaJHuqQCYk9skkQpjccAXQzDeKJQQ399CAACAAAAAA4tnsGAAAsAZDAAxx4"
$EncodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$RepoList = "repo-list.txt"
$Org = "MTFC-DataManagement"
$Project = "CODE-MulesoftESB"
$BranchName = "release/mule-4.9.4"
$ApiVersion = "7.1-preview.1"

###AUTH Header
$EncodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$Headers = @{
    Authorization = "Basic $EncodedPat"
    "Content-Type" = "application/json"
}

# Function to extract repo name from URL
function Get-RepoNameFromUrl($url) {
    $url = $url.Trim()
    if([string]::IsNullOrWhiteSpace($url)){return $null}
    
    if ($url -match "/_git/(([^/]*[^/])$)"){
        return $Matches[1]
    }
    
    return $url
}

# Function to get branch reference
function Get-BranchRef($repoId) {
    $refName = "heads/$BranchName"
    $refFilter = [uri]::EscapeDataString($refName)
    $uri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$repoId/refs?filter=$refFilter&api-version=$ApiVersion"
    $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
    if ($resp.value -and $resp.value.Count -gt 0){
        return $resp.value[0]
    }
    return $null
}

# Function to unlock branch
function Unlock-Branch($repoId, $oldObjectId){
    $refName = "heads/$BranchName"
    $refFilter = [uri]::EscapeDataString($refName)
    $uri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$repoId/refs?filter=$refFilter&api-version=$ApiVersion"
    
    $bodyObj = @{
        isLocked = $false
    }
    $body = $bodyObj | ConvertTo-Json -Depth 5
    
    Invoke-RestMethod -Method Patch -Uri $uri -Headers $Headers -ContentType "application/json" -Body $body | Out-Null
}

####Main Logic
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $RepoList)) {
    Write-Error "Repo list file not found"
    exit 1
}

$RepoNames = Get-Content $RepoList |
    Where-Object { $_ -and $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") } |
    ForEach-Object { Get-RepoNameFromUrl $_ } |
    Where-Object { $_ } |
    Select-Object -Unique

Write-Host "RepoNames Loaded: $($RepoNames -join ' ')"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoUri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories?api-version=$ApiVersion"
$allRepos = (Invoke-RestMethod -Uri $repoUri -Headers $Headers).value
Write-Host "Azure Repos returned: $($allRepos.Count)"

$repos = $allRepos | Where-Object {$RepoNames -contains $_.name}
Write-Host "Repos matched from repo-list.txt: $($repos.Count)"
Write-Host "Azure Repos:"
$repos | ForEach-Object { Write-Host " -$($_.name)"}

$Results = @()

foreach ($repo in $repos) {
    try{
        $ref = Get-BranchRef $repo.id
        
        if(-not $ref) {
            Write-Warning "Skip (branch missing): $($repo.name)"
            $Results += [pscustomobject]@{ Repo=$repo.name; Status="SKIP"; Reason="Branch not Found"}
            continue
        }
        
        if ($ref.isLocked -eq $true) {
            Unlock-Branch $repo.id $ref.objectId
            Write-Host "Unlocked: $($repo.name)"
            $Results += [pscustomobject]@{ Repo=$repo.name; Status="UNLOCKED"; Reason=""}
        } else {
            Write-Host "Already unlocked: $($repo.name)"
            $Results += [pscustomobject]@{ Repo=$repo.name; Status="OK"; Reason="Already Unlocked"}
        }
        
    }
    catch{
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message){
            $msg += " | Details: $($_.ErrorDetails.Message)"
        }
        Write-Warning "Failed: $($repo.name) -$msg"
        $Results += [pscustomobject]@{Repo=$repo.name; Status="FAILED"; Reason=$msg}
    }
}

$Report = "unlock-release-4.9.4-results.csv"
$Results | Export-Csv -NoTypeInformation -Path $Report
Write-Host "------------------------------------------------------------"
Write-Host "Done. Report: $Report"
