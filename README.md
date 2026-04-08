# Find User References in Power Automate Flows

A set of PowerShell scripts to find all references to a user across Power Automate flows in your organisation. Useful for offboarding or auditing purposes.

Depending on your permissions, you can scan flows across all environments in your tenant.

## What it finds
- Flows owned or created by the user
- Flows where the user's email is hardcoded
- Flows referencing the user's connection instances
- Flows where the user's name appears anywhere in the flow definition

## Known limitations
The scripts perform static analysis on flow definitions and cannot detect references where the user's details are resolved at runtime, including:
- Name or email stored in SharePoint or Dataverse and looked up dynamically
- Approval assignments resolved from a dynamic lookup
- HTTP actions passing the user's details as runtime variables

## Usage

**Step 1 — Resolve the user's Object ID**
```powershell
.\ResolveUserToObjectID.ps1
```
Run this first if you only have the user's email address. Outputs the Object ID needed for the next script.

**Step 2 — Find all flow references**
```powershell
.\FindAllFlowsReference.ps1
```
Scans all environments and exports a CSV of all flows referencing the target user, with a `MatchType` column indicating why each flow was flagged.
