# ============================================================
# Sync-Dev-Code-To-Deployed.ps1
#
# PURPOSE
# After a successful DEV deployment:
#
#   1. Read the exact commit used by the Classic Release artifact
#   2. Find the application repository from Build.BuildId
#   3. Clone the application repo temporarily
#   4. Unlock Dev_Code
#   5. Move Dev_Code directly to the deployed commit
#   6. Verify Dev_Code == deployed commit
#   7. Lock Dev_Code again
#   8. Clean up the temporary clone
#
# IMPORTANT
# This is NOT a merge.
#
# Supports:
#   - normal forward deployment
#   - older artifact deployment / rollback
#
# develop is NOT used or modified.
# ============================================================

$ErrorActionPreference = "Stop"


# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$Org = "WTFC-DataManagement"
$Project = "CODE-MuleSoftESB"

$TargetBranch = "Dev_Code"
$EnvironmentName = "DEV"


# ------------------------------------------------------------
# CLASSIC RELEASE VARIABLES
# ------------------------------------------------------------

# Build that generated the single artifact being deployed
$BuildId = "$(Build.BuildId)"

# Exact Git commit used to build that artifact
$DeployedSHA = "$(Build.SourceVersion)"

# Azure DevOps agent temporary directory
$AgentTemp = "$(Agent.TempDirectory)"

# OAuth token supplied to the Classic Release job
$Token = $env:SYSTEM_ACCESSTOKEN


# ------------------------------------------------------------
# VALIDATE VARIABLES
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw @"
SYSTEM_ACCESSTOKEN is empty.

Verify that the Classic Release Agent Job allows
scripts to access the OAuth token.
"@
}

if (
    [string]::IsNullOrWhiteSpace($BuildId) -or
    $BuildId -match '^\$\('
) {
    throw "Build.BuildId was not resolved."
}

if (
    [string]::IsNullOrWhiteSpace($DeployedSHA) -or
    $DeployedSHA -match '^\$\('
) {
    throw "Build.SourceVersion was not resolved."
}

if (
    [string]::IsNullOrWhiteSpace($AgentTemp) -or
    $AgentTemp -match '^\$\('
) {
    throw "Agent.TempDirectory was not resolved."
}


# ------------------------------------------------------------
# AUTHENTICATION
# ------------------------------------------------------------

$Auth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$Token")
)

$Headers = @{
    Authorization  = "Basic $Auth"
    "Content-Type" = "application/json"
}


Write-Host ""
Write-Host "======================================================"
Write-Host " $EnvironmentName -> $TargetBranch EXACT SYNCHRONIZATION"
Write-Host "======================================================"
Write-Host "Build ID            : $BuildId"
Write-Host "Deployed Source SHA : $DeployedSHA"
Write-Host "Target Branch       : $TargetBranch"
Write-Host ""


# ============================================================
# STEP 1
# FIND APPLICATION REPOSITORY FROM BUILD
# ============================================================

Write-Host "STEP 1 - Getting application repository from build..."

$BuildApi = `
    "https://dev.azure.com/$Org/$Project/_apis/build/builds/$BuildId?api-version=7.1"

try {

    $BuildInfo = Invoke-RestMethod `
        -Uri $BuildApi `
        -Method GET `
        -Headers $Headers
}
catch {

    throw @"
Unable to retrieve build information.

Build ID:
$BuildId

Error:
$($_.Exception.Message)
"@
}


$RepoName = $BuildInfo.repository.name
$RepoId   = $BuildInfo.repository.id
$RepoType = $BuildInfo.repository.type


if ([string]::IsNullOrWhiteSpace($RepoName)) {
    throw "Repository name could not be determined from build $BuildId."
}

if ([string]::IsNullOrWhiteSpace($RepoId)) {
    throw "Repository ID could not be determined from build $BuildId."
}

if ($RepoType -ne "TfsGit") {
    throw "Unexpected repository type: $RepoType. Expected TfsGit."
}


Write-Host "Repository Name : $RepoName"
Write-Host "Repository ID   : $RepoId"
Write-Host ""


# ------------------------------------------------------------
# REPOSITORY URL
# ------------------------------------------------------------

$RepoUrl = `
    "https://dev.azure.com/$Org/$Project/_git/$RepoName"


# ------------------------------------------------------------
# LOCK / UNLOCK API FOR Dev_Code
# ------------------------------------------------------------

$LockApi = `
    "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$RepoId/refs?filter=heads/$TargetBranch&api-version=7.1"


# ------------------------------------------------------------
# TEMPORARY CLONE LOCATION
# ------------------------------------------------------------

$SafeRepoName = $RepoName -replace '[^a-zA-Z0-9._-]', '_'

$TempFolder = Join-Path `
    $AgentTemp `
    "DevCodeSync_$SafeRepoName_$([guid]::NewGuid().ToString('N'))"


Write-Host "Temporary clone:"
Write-Host "  $TempFolder"
Write-Host ""


$LocationChanged = $false
$BranchUnlocked = $false


try {

    # ========================================================
    # STEP 2
    # CLONE APPLICATION REPOSITORY
    # ========================================================

    Write-Host "------------------------------------------------------"
    Write-Host "STEP 2 - Clone application repository"
    Write-Host "------------------------------------------------------"

    git `
        -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
        clone `
        --quiet `
        --no-checkout `
        $RepoUrl `
        $TempFolder

    if ($LASTEXITCODE -ne 0) {
        throw "Repository clone failed for $RepoName."
    }


    Push-Location $TempFolder
    $LocationChanged = $true


    # ========================================================
    # STEP 3
    # FETCH REFS AND TAGS
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 3 - Fetch refs and tags"
    Write-Host "------------------------------------------------------"

    git `
        -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
        fetch `
        origin `
        --prune `
        --tags `
        --force `
        --quiet

    if ($LASTEXITCODE -ne 0) {
        throw "Git fetch failed."
    }


    # ========================================================
    # STEP 4
    # VERIFY Dev_Code EXISTS
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 4 - Verify $TargetBranch exists"
    Write-Host "------------------------------------------------------"

    git rev-parse `
        --verify `
        "refs/remotes/origin/$TargetBranch" *> $null

    if ($LASTEXITCODE -ne 0) {
        throw @"
Remote branch does not exist:

$TargetBranch

Create $TargetBranch before running this synchronization.
"@
    }

    Write-Host "$TargetBranch exists."


    # ========================================================
    # STEP 5
    # VERIFY DEPLOYED COMMIT EXISTS
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 5 - Verify deployed commit"
    Write-Host "------------------------------------------------------"

    git cat-file `
        -e `
        "$DeployedSHA^{commit}" 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Host "Deployed commit not available locally."
        Write-Host "Trying direct fetch of deployed SHA..."

        git `
            -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
            fetch `
            origin `
            $DeployedSHA `
            --quiet

        if ($LASTEXITCODE -ne 0) {
            throw @"
Unable to fetch the exact deployed commit.

Commit:
$DeployedSHA

Repository:
$RepoName
"@
        }

        git cat-file `
            -e `
            "$DeployedSHA^{commit}" 2>$null

        if ($LASTEXITCODE -ne 0) {
            throw "The deployed SHA is not available as a Git commit."
        }
    }


    $DeployedFullSHA = (
        git rev-parse "$DeployedSHA^{commit}"
    ).Trim()


    Write-Host "Exact deployed SHA:"
    Write-Host "  $DeployedFullSHA"


    # ========================================================
    # STEP 6
    # READ CURRENT Dev_Code SHA
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 6 - Read current $TargetBranch"
    Write-Host "------------------------------------------------------"

    $CurrentBranchSHA = (
        git rev-parse "refs/remotes/origin/$TargetBranch"
    ).Trim()


    Write-Host "Current $TargetBranch : $CurrentBranchSHA"
    Write-Host "Deployed DEV commit   : $DeployedFullSHA"


    # ========================================================
    # STEP 7
    # ALREADY SYNCHRONIZED?
    # ========================================================

    if ($CurrentBranchSHA -eq $DeployedFullSHA) {

        Write-Host ""
        Write-Host "======================================================"
        Write-Host " NO CHANGE REQUIRED"
        Write-Host "======================================================"
        Write-Host "$TargetBranch already exactly matches deployed DEV."
        Write-Host ""

        return
    }


    # ========================================================
    # STEP 8
    # DETERMINE DIRECTION
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 8 - Determine synchronization direction"
    Write-Host "------------------------------------------------------"

    git merge-base `
        --is-ancestor `
        $CurrentBranchSHA `
        $DeployedFullSHA

    if ($LASTEXITCODE -eq 0) {

        Write-Host "Direction: FORWARD"

    }
    else {

        git merge-base `
            --is-ancestor `
            $DeployedFullSHA `
            $CurrentBranchSHA

        if ($LASTEXITCODE -eq 0) {

            Write-Host "Direction: ROLLBACK / OLDER DEPLOYMENT"

        }
        else {

            Write-Host "Direction: DIVERGED HISTORY"
            Write-Host "$TargetBranch will still be synchronized exactly to DEV."
        }
    }


    # ========================================================
    # STEP 9
    # UNLOCK Dev_Code
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 9 - Unlock $TargetBranch"
    Write-Host "------------------------------------------------------"

    $UnlockBody = @{
        isLocked = $false
    } | ConvertTo-Json

    try {

        $UnlockResult = Invoke-RestMethod `
            -Uri $LockApi `
            -Method PATCH `
            -Headers $Headers `
            -Body $UnlockBody
    }
    catch {

        throw @"
Unable to unlock $TargetBranch.

Check Build Service permissions.

Error:
$($_.Exception.Message)
"@
    }


    if ($UnlockResult.isLocked -eq $true) {
        throw "$TargetBranch still reports as locked."
    }


    $BranchUnlocked = $true

    Write-Host "$TargetBranch unlocked."


    # ========================================================
    # STEP 10
    # REFRESH Dev_Code IMMEDIATELY BEFORE PUSH
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 10 - Refresh $TargetBranch"
    Write-Host "------------------------------------------------------"

    git `
        -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
        fetch `
        origin `
        "+refs/heads/$TargetBranch:refs/remotes/origin/$TargetBranch" `
        --quiet

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to refresh $TargetBranch."
    }


    $CurrentBranchSHA = (
        git rev-parse "refs/remotes/origin/$TargetBranch"
    ).Trim()


    Write-Host "$TargetBranch immediately before sync:"
    Write-Host "  $CurrentBranchSHA"


    # ========================================================
    # STEP 11
    # MOVE Dev_Code DIRECTLY TO DEPLOYED SHA
    #
    # NO MERGE
    # NO REBASE
    # NO CHERRY-PICK
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 11 - Synchronize $TargetBranch"
    Write-Host "------------------------------------------------------"

    Write-Host "Current branch SHA:"
    Write-Host "  $CurrentBranchSHA"

    Write-Host "Deployed DEV SHA:"
    Write-Host "  $DeployedFullSHA"


    git `
        -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
        push `
        "--force-with-lease=refs/heads/$TargetBranch:$CurrentBranchSHA" `
        origin `
        "${DeployedFullSHA}:refs/heads/$TargetBranch"


    if ($LASTEXITCODE -ne 0) {

        throw @"
$TargetBranch synchronization FAILED.

Possible causes:

1. Build Service does not have Force push permission.
2. Build Service does not have Bypass policies when pushing.
3. $TargetBranch changed after the final fetch.
4. Branch could not actually be unlocked.
5. Authentication failed.
"@
    }


    # ========================================================
    # STEP 12
    # VERIFY REMOTE Dev_Code
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 12 - Verify remote $TargetBranch"
    Write-Host "------------------------------------------------------"

    $RemoteBranchLine = git `
        -c "http.extraheader=AUTHORIZATION: Basic $Auth" `
        ls-remote `
        --heads `
        origin `
        "refs/heads/$TargetBranch"


    if ([string]::IsNullOrWhiteSpace($RemoteBranchLine)) {
        throw "Unable to retrieve remote $TargetBranch."
    }


    $RemoteBranchSHA = (
        $RemoteBranchLine -split '\s+'
    )[0].Trim()


    Write-Host "Deployed DEV SHA  : $DeployedFullSHA"
    Write-Host "$TargetBranch SHA : $RemoteBranchSHA"


    if ($RemoteBranchSHA -ne $DeployedFullSHA) {

        throw @"
CRITICAL VERIFICATION FAILURE.

$TargetBranch does not match deployed DEV.

DEV:
$DeployedFullSHA

$TargetBranch:
$RemoteBranchSHA
"@
    }


    # ========================================================
    # STEP 13
    # VERIFY TREE
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 13 - Verify exact repository snapshot"
    Write-Host "------------------------------------------------------"

    $DeployedTreeSHA = (
        git rev-parse "$DeployedFullSHA^{tree}"
    ).Trim()


    $BranchTreeSHA = (
        git rev-parse "$RemoteBranchSHA^{tree}"
    ).Trim()


    Write-Host "Deployed tree      : $DeployedTreeSHA"
    Write-Host "$TargetBranch tree : $BranchTreeSHA"


    if ($DeployedTreeSHA -ne $BranchTreeSHA) {
        throw "$TargetBranch tree does not match deployed DEV tree."
    }


    Write-Host "Commit verification : PASSED"
    Write-Host "Tree verification   : PASSED"


    # ========================================================
    # STEP 14
    # LOCK Dev_Code AGAIN
    # ========================================================

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "STEP 14 - Lock $TargetBranch"
    Write-Host "------------------------------------------------------"

    $LockBody = @{
        isLocked = $true
    } | ConvertTo-Json


    try {

        $LockResult = Invoke-RestMethod `
            -Uri $LockApi `
            -Method PATCH `
            -Headers $Headers `
            -Body $LockBody
    }
    catch {

        throw @"
Synchronization succeeded, but $TargetBranch
could not be locked again.

Repository:
$RepoName

SHA:
$RemoteBranchSHA

Error:
$($_.Exception.Message)
"@
    }


    if ($LockResult.isLocked -ne $true) {
        throw "Azure DevOps did not confirm that $TargetBranch was locked."
    }


    $BranchUnlocked = $false


    # ========================================================
    # SUCCESS
    # ========================================================

    Write-Host ""
    Write-Host "======================================================"
    Write-Host " SUCCESS"
    Write-Host "======================================================"

    Write-Host "Repository          : $RepoName"
    Write-Host "Environment         : $EnvironmentName"
    Write-Host "Deployed commit     : $DeployedFullSHA"
    Write-Host "$TargetBranch commit: $RemoteBranchSHA"
    Write-Host ""

    Write-Host "VERIFIED:"
    Write-Host "  $TargetBranch SHA  == deployed DEV SHA"
    Write-Host "  $TargetBranch tree == deployed DEV tree"
    Write-Host "  $TargetBranch is locked"
    Write-Host ""
}
catch {

    Write-Host ""
    Write-Host "======================================================"
    Write-Host " ERROR"
    Write-Host "======================================================"

    Write-Host $_.Exception.Message


    # ========================================================
    # EMERGENCY RE-LOCK
    # ========================================================

    if ($BranchUnlocked) {

        Write-Host ""
        Write-Host "Attempting emergency re-lock of $TargetBranch..."

        try {

            $EmergencyLockBody = @{
                isLocked = $true
            } | ConvertTo-Json


            $EmergencyResult = Invoke-RestMethod `
                -Uri $LockApi `
                -Method PATCH `
                -Headers $Headers `
                -Body $EmergencyLockBody


            if ($EmergencyResult.isLocked -eq $true) {

                $BranchUnlocked = $false

                Write-Host "Emergency re-lock succeeded."
            }
            else {

                Write-Host "WARNING: Azure DevOps did not confirm branch lock."
            }
        }
        catch {

            Write-Host ""
            Write-Host "******************************************************"
            Write-Host "CRITICAL WARNING"
            Write-Host "******************************************************"
            Write-Host "$TargetBranch could not be automatically re-locked."
            Write-Host "Repository: $RepoName"
            Write-Host "Manual intervention is required."
            Write-Host "******************************************************"
        }
    }


    exit 1
}
finally {

    # ========================================================
    # LEAVE TEMP REPOSITORY
    # ========================================================

    if ($LocationChanged) {

        try {
            Pop-Location
        }
        catch {
        }
    }


    # ========================================================
    # REMOVE TEMP APPLICATION CLONE
    # ========================================================

    if (
        -not [string]::IsNullOrWhiteSpace($TempFolder) -and
        (Test-Path $TempFolder)
    ) {

        Write-Host ""
        Write-Host "Cleaning temporary application clone:"
        Write-Host "  $TempFolder"


        Remove-Item `
            $TempFolder `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
