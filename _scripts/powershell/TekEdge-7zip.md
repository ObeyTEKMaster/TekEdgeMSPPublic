# TekEdge-7zip.psm1 - Documentation

## Overview

`TekEdge-7zip.psm1` is a PowerShell module (PS 5.1 compatible) that wraps
`7za.exe` (standalone 7-Zip) to provide archive operations for use in TekEdge
RMM helper scripts. It is not a standalone script - it is a library intended
to be imported by other scripts in the TekEdge suite.

Exported functions:

- `Write-Status`   - Consistent status line formatting (shared across all TekEdge scripts)
- `Compress-7z`    - Create or update a .7z archive
- `Expand-7z`      - Extract files from a .7z archive
- `Test-7zArchive` - Verify archive integrity
- `Get-7zArchive`  - List archive contents, returns structured objects

---

## Requirements

### Environment Variable

`$env:TekEdgeRoot` must be set as a **system-level persistent environment
variable** before this module will function. This is handled by the TekEdge
install script.

Expected value example: `C:\ProgramData\TekEdgeTools`

The module constructs the path to `7za.exe` at import time as:

```
$env:TekEdgeRoot\_tools\_utilities\7za.exe
```

If `$env:TekEdgeRoot` is not set, or `7za.exe` is not found at the expected
path, the module will load with a warning but all functions will return `$false`
and write an error status to the console.

### 7za.exe

7za.exe is the standalone command-line build of 7-Zip. It must be placed at:

```
$env:TekEdgeRoot\_tools\_utilities\7za.exe
```

Download from: https://www.7-zip.org/download.html
Look for: "7-Zip Extra: standalone console version, 7z DLL, Plugin for Far Manager"
File needed: `7za.exe` from the archive.

---

## File Location

Place the module at:

```
$env:TekEdgeRoot\_scripts\powershell\TekEdge-7zip.psm1
```

Which resolves to (default install):

```
C:\ProgramData\TekEdgeTools\_scripts\powershell\TekEdge-7zip.psm1
```

---

## Importing the Module in a Calling Script

Add the following block near the top of any script that needs 7-Zip functions,
after your Parameters section:

```powershell
#==============================================
# Import TekEdge-7zip Module
#==============================================
$TekEdgeRootDir   = $env:TekEdgeRoot
$TekEdgeScripts   = Join-Path $TekEdgeRootDir '_scripts'
$TekEdgeScriptsPs = Join-Path $TekEdgeScripts  'powershell'
$7zipModule       = Join-Path $TekEdgeScriptsPs 'TekEdge-7zip.psm1'

if (Test-Path $7zipModule) {
    Import-Module $7zipModule -Force
} else {
    Write-Host "[ FAIL ] FATAL ERROR - TekEdge-7zip module not found at: $7zipModule"
    exit 1001
}
```

The `-Force` flag ensures the latest version is loaded even if the module was
previously imported in the same session.

---

## Write-Status

Writes a consistently formatted one-line status message to the console.
Exported so calling scripts do not need to redefine it.

```
Write-Status [-Message] <string> [[-Level] <string>]
```

| Parameter | Type   | Required | Description |
|-----------|--------|----------|-------------|
| Message   | string | Yes      | The text to display |
| Level     | string | No       | OK, WARN, ERROR, or INFO (default) |

Output format:

```
[  OK  ] Message text here
[ WARN ] Message text here
[ FAIL ] Message text here
[ INFO ] Message text here
```

Examples:

```powershell
Write-Status -Message "Archive created successfully" -Level OK
Write-Status -Message "No files matched the filter" -Level WARN
Write-Status -Message "ERROR - Archive not found: C:\backup.7z" -Level ERROR
Write-Status -Message "Starting compression job" -Level INFO
Write-Status -Message "Processing..."          # Defaults to INFO
```

---

## Compress-7z

Creates a new .7z archive or updates an existing one. If the archive already
exists, files are added or replaced (existing unmatched files in the archive
are left intact).

Supports optional AES-256 encryption with header encryption, meaning the file
names inside the archive are also hidden from anyone without the password.

```
Compress-7z [-ArchivePath] <string> [-SourcePath] <string[]>
            [-Password <string>] [-Recurse] [-CompressionLevel <int>]
```

| Parameter        | Type     | Required | Default | Description |
|------------------|----------|----------|---------|-------------|
| ArchivePath      | string   | Yes      | -       | Full path to the .7z archive to create or update |
| SourcePath       | string[] | Yes      | -       | One or more file/directory paths to compress. Wildcards supported (e.g. `C:\Logs\*.log`) |
| Password         | string   | No       | -       | Encrypts archive with AES-256. File headers are also encrypted (-mhe=on). Never logged to console |
| Recurse          | switch   | No       | Off     | Include subdirectories recursively |
| CompressionLevel | int 0-9  | No       | 5       | 0 = store only (fastest, largest). 9 = maximum compression (slowest, smallest) |

Returns: `[bool]` - `$true` on success, `$false` on failure.

Examples:

```powershell
# Basic compression of a directory
Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs'

# Compress specific file types recursively
Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs\*.log' -Recurse

# Compress with encryption
Compress-7z -ArchivePath 'C:\Backups\secure.7z' -SourcePath 'C:\Sensitive' -Password 'S3cr3t!'

# Multiple source paths, store only (no compression), check result
$ok = Compress-7z -ArchivePath 'C:\Backups\mixed.7z' `
                  -SourcePath @('C:\Logs', 'C:\Reports\*.csv') `
                  -CompressionLevel 0 `
                  -Recurse
if (-not $ok) {
    Write-Status -Message "ERROR - Compression failed" -Level ERROR
}
```

---

## Expand-7z

Extracts files from an existing .7z archive to a destination directory.
Preserves directory structure from within the archive. Destination directory
is created automatically if it does not exist.

By default, existing files at the destination are skipped. Use `-Force` to
overwrite them.

```
Expand-7z [-ArchivePath] <string> [-Destination <string>]
          [-Password <string>] [-Force] [-IncludeFilter <string[]>]
```

| Parameter     | Type     | Required | Default | Description |
|---------------|----------|----------|---------|-------------|
| ArchivePath   | string   | Yes      | -       | Full path to the .7z archive to extract |
| Destination   | string   | No       | `.`     | Directory to extract files into. Created if it does not exist |
| Password      | string   | No       | -       | Password for encrypted archives. Never logged to console |
| Force         | switch   | No       | Off     | Overwrite existing files. Default behavior skips existing files |
| IncludeFilter | string[] | No       | (all)   | One or more filename patterns to extract (e.g. `'*.log'`). If omitted, all files are extracted |

Returns: `[bool]` - `$true` on success, `$false` on failure.

Skipped files (when not using `-Force`) are reported individually as `[ WARN ]`
lines in the console output.

Examples:

```powershell
# Extract all files
Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore'

# Extract and overwrite existing files
Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore' -Force

# Extract from an encrypted archive
Expand-7z -ArchivePath 'C:\Backups\secure.7z' -Destination 'C:\Restore' -Password 'S3cr3t!'

# Extract only specific file types
Expand-7z -ArchivePath 'C:\Backups\mixed.7z' `
          -Destination 'C:\Restore' `
          -IncludeFilter @('*.log', '*.csv')

# Check result
$ok = Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore'
if (-not $ok) {
    Write-Status -Message "ERROR - Extraction failed" -Level ERROR
}
```

---

## Test-7zArchive

Tests the integrity of a .7z archive by verifying that all files can be read
and pass their internal checksums. Does not extract any files.

```
Test-7zArchive [-ArchivePath] <string> [-Password <string>]
```

| Parameter   | Type   | Required | Description |
|-------------|--------|----------|-------------|
| ArchivePath | string | Yes      | Full path to the .7z archive to test |
| Password    | string | No       | Password for encrypted archives. Never logged to console |

Returns: `[bool]` - `$true` if archive is intact or empty, `$false` if errors
are found or the archive cannot be opened.

Examples:

```powershell
# Basic integrity test
Test-7zArchive -ArchivePath 'C:\Backups\logs.7z'

# Test an encrypted archive
Test-7zArchive -ArchivePath 'C:\Backups\secure.7z' -Password 'S3cr3t!'

# Use result in a backup verification workflow
if (Test-7zArchive -ArchivePath 'C:\Backups\logs.7z') {
    Write-Status -Message "Backup verified OK" -Level OK
} else {
    Write-Status -Message "ERROR - Backup verification failed" -Level ERROR
    exit 1001
}
```

---

## Get-7zArchive

Lists the contents of a .7z archive and returns structured objects, one per
file entry. The calling script can use these objects to inspect file names,
sizes, dates, and attributes without extracting anything.

```
Get-7zArchive [-ArchivePath] <string> [-Password <string>]
```

| Parameter   | Type   | Required | Description |
|-------------|--------|----------|-------------|
| ArchivePath | string | Yes      | Full path to the .7z archive to list |
| Password    | string | No       | Password for encrypted archives. Never logged to console |

Returns: `[PSCustomObject[]]` - Array of file entry objects. Returns an empty
array on failure (never returns `$null`). Each object has these properties:

| Property   | Type     | Description |
|------------|----------|-------------|
| Name       | string   | File path as stored inside the archive |
| DateTime   | DateTime | Last modified timestamp of the file |
| Size       | long     | Uncompressed file size in bytes |
| Compressed | long     | Compressed size in bytes (may be 0 for solid archives) |
| Mode       | string   | Attribute flags as reported by 7za (e.g. `....A`, `D....`) |

Note: Entries where `Mode` starts with `D` are directories. Filter these out
if you only want files.

Examples:

```powershell
# List all contents and print to console
$files = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
$files | ForEach-Object {
    Write-Status -Message "- $($_.Name) ($($_.Size) bytes)" -Level INFO
}

# List an encrypted archive
$files = Get-7zArchive -ArchivePath 'C:\Backups\secure.7z' -Password 'S3cr3t!'

# Check if a specific file exists inside the archive before extracting
$files = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
$target = $files | Where-Object { $_.Name -eq 'app\error.log' }
if ($target) {
    Write-Status -Message "Found error.log ($($target.Size) bytes)" -Level INFO
    Expand-7z -ArchivePath 'C:\Backups\logs.7z' `
              -Destination 'C:\Restore' `
              -IncludeFilter 'error.log'
} else {
    Write-Status -Message "error.log not found in archive" -Level WARN
}

# Count files only (exclude directory entries)
$files = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
$fileCount = ($files | Where-Object { $_.Mode -notmatch '^D' }).Count
Write-Status -Message "Archive contains $fileCount file(s)" -Level INFO

# Get total uncompressed size
$files  = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
$totalBytes = ($files | Measure-Object -Property Size -Sum).Sum
Write-Status -Message "Total uncompressed size: $totalBytes bytes" -Level INFO
```

---

## Maintainer Notes

### Adding New Functions

- Follow the same param/output pattern as existing functions.
- Always check `$script:7zaAvailable` at the start and return early with
  `$false` or an empty array if it is `$false`.
- Use `Invoke-7za` for all calls to 7za.exe. Do not call `7za.exe` directly
  from exported functions.
- Add `-RedactPassword:$hasPassword` to any `Invoke-7za` call that passes a
  password argument.
- Export the new function in the `Export-ModuleMember` block at the bottom
  of the module.
- Add a changelog entry in the `.NOTES` header block.

### Changing the 7za.exe Path

The path is constructed once at module import time in the MODULE INIT section
near the top of the file. The relevant lines are:

```powershell
$script:TekEdgeTools          = Join-Path $script:TekEdgeRootDir '_tools'
$script:TekEdgeToolsUtilities = Join-Path $script:TekEdgeTools   '_utilities'
$script:7zaExe                = Join-Path $script:TekEdgeToolsUtilities '7za.exe'
```

Update these if the TekEdge folder structure changes. Do not hardcode
`C:\ProgramData\TekEdgeTools` anywhere - always derive from `$env:TekEdgeRoot`.

### Changing the Root Environment Variable Name

The module reads `$env:TekEdgeRoot` in one place only, at the top of the
MODULE INIT section:

```powershell
$script:TekEdgeRootDir = $env:TekEdgeRoot
```

If the environment variable name changes suite-wide, update it here.

### Password Security

Passwords are passed to 7za.exe inline as `-pPASSWORD` (no space). This is
the format 7za.exe requires. The `Invoke-7za` function's `RedactPassword`
switch ensures the password is never written to the console or logs. Never
pass a password via `Write-Host`, `Write-Status`, or any logging call.

### PS 5.1 Compatibility

- Use `New-Object PSObject -Property @{}` instead of `[PSCustomObject]@{}`.
  (Both work in PS 5.1 but the explicit form avoids edge cases in strict mode.)
- Use `New-Object System.Collections.ArrayList` instead of typed generic lists.
- Avoid `::new()` constructors - use `New-Object` instead.
- `[long]::TryParse()` is available in PS 5.1 (.NET 4.x) and is used for
  safe numeric parsing of 7za output.

### Changelog

Add a line to the `.NOTES` header block for every version:

```
v1.0.0 - 05/21/2025 - Initial release
v1.0.1 - MM/DD/YYYY - Brief description of change
```

---

## Inline Comment Reference

The script is heavily commented throughout. The sections below point to the
areas that have the most detailed inline explanations, so you know where to
look when reading the code.

### Set-StrictMode (line ~36)

Explains what strict mode does and why it is enabled. Short read — worth
understanding before making any changes.

### MODULE INIT section (lines ~39-89)

Explains:
- What the `$script:` variable prefix means and why it matters
- Why variables are pre-declared as `$null` (strict mode requirement)
- Why `$script:7zaAvailable` exists and how it is used by every function
- How `Join-Path` builds the path to `7za.exe` step by step

### Invoke-7za — password redaction loop (lines ~168-200)

The most complex logic in the module. The inline comments walk through both
forms of the 7za.exe password argument (`-pPASSWORD` glued vs. `-p PASSWORD`
separated) and explain how the `$skipNext` flag handles the two-argument form.

### Compress-7z — argument array comments (lines ~220-245)

Each 7za.exe flag (`a`, `-t7z`, `-mx=`, `-bd`, `-y`, `-r`, `-mhe=on`) is
explained inline. Good reference if you need to understand or extend the
argument list.

### Expand-7z — overwrite flags (lines ~315-320)

Explains the difference between `-aoa` (overwrite all) and `-aos` (skip
existing), and how `-Force` controls which is used.

### Expand-7z — `-o` output path flag (lines ~323-325)

Notes the unusual 7za.exe convention of gluing the path directly onto `-o`
with no space (e.g. `-oC:\Restore`).

### Get-7zArchive — `-slt` output parsing (lines ~653-775)

The most complex section in the module. The inline comments include:
- A sample of what `-slt` output looks like so you can understand what is
  being parsed
- Why `ArrayList` is used instead of a regular array
- Why `$inEntries` is needed (skipping header lines)
- Why `[void]` is used when calling `.Add()`
- How the regex `'^([^=]+?)\s*=\s*(.*)$'` works, broken down piece by piece
- Why `[DateTime]::ParseExact` with `InvariantCulture` is used instead of a
  simple cast
- Why `[long]::TryParse` with `[ref]` is safer than `[long]$value`
- The edge case of the last entry not being followed by a blank line

### MODULE EXPORTS section (lines ~796-814)

Explains why `Export-ModuleMember` exists, what it controls, and why
`Invoke-7za` is intentionally left off the export list.
