# ============================================================
# Resolve User Identifiers to Object IDs in Entra ID
# Uses Microsoft Graph PowerShell SDK to check both live users and deleted users recycle bin
# Authors: Charles So (@charles-so)
# ============================================================

$emailsToResolve = @(
    "john.smith@example.com",
    "john.smith@onmicrosoft.example.com"
)

Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"

foreach ($email in $emailsToResolve) {
    try {
        $user = Get-MgUser -UserId $email -ErrorAction Stop
        Write-Host "[OK] $email -> $($user.Id)" -ForegroundColor Green
    }
    catch {
        try {
            $deleted = Get-MgDirectoryDeletedItemAsUser -DirectoryObjectId $email -ErrorAction Stop
            Write-Host "[DELETED] $email -> $($deleted.Id)" -ForegroundColor Yellow
        }
        catch {
            Write-Host "[FAILED] Could not resolve: $email" -ForegroundColor Red
        }
    }
}