# ============================================================
# Find Flows Referencing Target Identifiers - Perosn Partial name, Email, ObjectId, Connection IDs
# Note: You need to run it as a Power Platform admin to have visibility into all flows and connections across environments
# Usage: Fill in $targetObjectIds, $targetEmails, and $targetPartialStrings with known identifiers related to the user
# This script will scan ALL flows in ALL environments for references to these identifiers.
# This is a brute-force search and may take time, but it's the most comprehensive way to find any possible reference.
#
# Steps:
# 1. Collect all known identifiers (Object IDs, Emails, Connection IDs, Partial Strings)
# 2. Get all flows from all environments with pagination
# 3. For each flow, fetch the full definition and convert to JSON string
# 4. Search the JSON string for any occurrence of the identifiers
# 5. If a match is found, log the flow details and which identifier matched
# 6. Export results to CSV for further analysis
#
# **However it does not cover any runtime-only references such as:
# 1. Name/email stored in SharePoint or Dataverse, looked up at runtime
# 2. Approvals assigned to her dynamically from a lookup
# 3. HTTP actions passing her details as runtime variables
# ============================================================

Add-PowerAppsAccount

$token = Get-JwtToken -Audience "https://service.flow.microsoft.com/"

# ============================================================
# ONLY CHANGE THESE
# ============================================================

# You can resolve Object IDs from emails using ResolveUserToOjectID.ps1 script in this repo, or from Azure AD portal
$targetObjectIds = @(
    "4c8eaa83-b80d-42cc-bfad-eb6dka1kbbdd",
    "26098856-ae64-478f-b970-98eb87e1ba23"
)

# Known email addresses to search for (including old/alternate emails)
$targetEmails = @(
    "john.smith@example.com",
    "john.smith@example.com"
)

# Known partial strings to search for (e.g. just first name or last name, which may catch more references but also produce more false positives)
$targetPartialStrings = @(
    "John",
    "Smith"
)
# ============================================================

# Build environment lookup for friendly names in output
$allEnvironments = Get-AdminPowerAppEnvironment
$envLookup = @{}
foreach ($env in $allEnvironments) {
    $envLookup[$env.EnvironmentName] = $env.DisplayName
}

function Resolve-EnvName($envId) {
    return $envLookup[$envId]
}

# Get connection IDs created by the target user across all environments, to include in the search list
# This is important because many flows reference users indirectly through connections, and the connection itself may be the only place where the user's Object ID is mentioned. By finding all connection IDs created by the user, we can then search for those connection IDs in flow definitions to find any flow that might be using a connection associated with the user.
Write-Host "Step 1: Collecting connection IDs across all environments..." -ForegroundColor Cyan

$targetConnectionIds = @()

foreach ($env in $allEnvironments) {
    foreach ($objId in $targetObjectIds) {
        $conns = Get-AdminPowerAppConnection `
            -EnvironmentName $env.EnvironmentName `
            -CreatedBy $objId `
            -ErrorAction SilentlyContinue

        if ($conns) {
            foreach ($conn in $conns) {
                $targetConnectionIds += $conn.ConnectionName
                Write-Host "  [CONNECTION] $($conn.ConnectorName) -> $($conn.ConnectionName) in $(Resolve-EnvName $env.EnvironmentName)" -ForegroundColor Gray
            }
        }
    }
}

$targetConnectionIds = $targetConnectionIds | Sort-Object -Unique
Write-Host "Found $($targetConnectionIds.Count) unique connection ID(s).`n" -ForegroundColor Cyan

# Construct our search list by combining all identifiers
# We search for Object IDs, Emails, Connection IDs, and any partial strings to maximize our chances of finding references. The more identifiers we have, the better coverage we get, but it may also increase false positives, especially with common partial strings.
$allIdentifiers = $targetObjectIds + $targetEmails + $targetConnectionIds + $targetPartialStrings

Write-Host "Searching for $($allIdentifiers.Count) identifier(s):" -ForegroundColor Cyan
$allIdentifiers | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

# Get flows from all environments and search for any reference to our identifiers
Write-Host "`nStep 2: Scanning all $($allEnvironments.Count) environment(s)..." -ForegroundColor Cyan

$matchedFlows = @()

foreach ($env in $allEnvironments) {
    Write-Host "`n  Scanning: $(Resolve-EnvName $env.EnvironmentName)" -ForegroundColor Cyan

    # Get all flows with pagination
    $allFlows = @()
    $uri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/" + $env.EnvironmentName + "/v2/flows?api-version=2016-11-01&`$top=250"

    do {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
            Authorization = "Bearer $token"
        } -ErrorAction SilentlyContinue

        if ($response.value) {
            $allFlows += $response.value
        }

        $uri = $response.nextLink

    } while ($uri)

    if ($allFlows.Count -eq 0) {
        Write-Host "  No flows found." -ForegroundColor Gray
        continue
    }

    Write-Host "  Total flows: $($allFlows.Count)" -ForegroundColor Gray

    # Fetch each flow definition and search
    $flowCount = 0
    foreach ($flow in $allFlows) {
        $flowCount++
        Write-Host "  Checking $flowCount/$($allFlows.Count): $($flow.properties.displayName)" -ForegroundColor Gray

        $flowUri = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/" + $env.EnvironmentName + "/flows/" + $flow.name + "?`$expand=definition&api-version=2016-11-01"

        $flowResponse = Invoke-RestMethod -Method Get -Uri $flowUri -Headers @{
            Authorization = "Bearer $token"
        } -ErrorAction SilentlyContinue

        if ($flowResponse) {
            # Convert the definition to JSON string for easier searching (could be large, but we only need to check if it contains the identifiers)
            # Depth 100 is very generous to ensure we capture deeply nested references, but be aware it may consume more memory for very complex flows. We only need to find if the identifier exists anywhere in the definition, so we don't need to parse the structure in detail.
            $flowJson = $flowResponse | ConvertTo-Json -Depth 100

            foreach ($identifier in $allIdentifiers) {
                # We use -like with wildcards to find any occurrence of the identifier in the flow definition. This is a simple string search and may produce false positives, especially for common partial strings, but it ensures we don't miss any references. For more precise matching, we could implement additional logic to check the context of the match (e.g. is it within a connection reference, an action property, etc.), but that would require more complex parsing of the flow definition.
                if ($flowJson -like "*$identifier*") {
                    Write-Host "  [MATCH] $($flow.properties.displayName) -> $identifier" -ForegroundColor Green

                    # Determine match type
                    $matchType = switch -Wildcard ($identifier) {
                        { $targetConnectionIds -contains $_ } { "Connection" }
                        { $targetObjectIds     -contains $_ } { "ObjectId" }
                        { $targetEmails        -contains $_ } { "Email" }
                        default                               { "Partial String" }
                    }

                    $matchedFlows += [PSCustomObject]@{
                        DisplayName  = $flow.properties.displayName
                        FlowName     = $flow.name
                        Environment  = Resolve-EnvName $env.EnvironmentName
                        MatchedOn    = $identifier
                        MatchType    = $matchType
                        State        = $flow.properties.state
                    }
                    break
                }
            }
        }

        # Sleep briefly to avoid throttling
        Start-Sleep -Milliseconds 200
    }
}

# --- Results ---
Write-Host "`n=== RESULTS ===" -ForegroundColor Cyan
if ($matchedFlows.Count -eq 0) {
    Write-Host "No flows found referencing target identifiers." -ForegroundColor Yellow
} else {
    Write-Host "Found $($matchedFlows.Count) flow(s):" -ForegroundColor Green
    $matchedFlows | Format-Table -AutoSize
}

# --- Export ---
if ($matchedFlows.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $matchedFlows | Export-Csv "flow_references_$timestamp.csv" -NoTypeInformation
    Write-Host "Exported to flow_references_$timestamp.csv" -ForegroundColor Green
}