<#
.SYNOPSIS
    PowerShell module providing 7-Zip wrapper functions for use in TekEdge RMM scripts.

.DESCRIPTION
    Wraps 7za.exe (standalone 7-Zip) to provide compress, expand, test, and list
    operations on .7z archives, with optional password/encryption support.
    Designed to be imported by other TekEdge helper and RMM scripts.

    Requires $env:TekEdgeRoot to be set (e.g. C:\ProgramData\TekEdgeTools).
    Expects 7za.exe at: $env:TekEdgeRoot\_tools\_utilities\7za.exe

    Functions exported:
      Compress-7z    - Create or add to a .7z archive
      Expand-7z      - Extract files from a .7z archive
      Test-7zArchive - Test integrity of a .7z archive
      Get-7zArchive  - List contents of a .7z archive

.NOTES
    Author: TekEdge Consulting, with assistance from Claude

    Changelog:
      v1.0.0 - 05/21/2025 - Initial release
#>

Set-StrictMode -Version Latest

#######################################################################
#                            MODULE INIT                              #
#######################################################################

# Resolve 7za.exe path from environment variable at import time
$script:TekEdgeRootDir        = $env:TekEdgeRoot
$script:TekEdgeTools          = $null
$script:TekEdgeToolsUtilities = $null
$script:7zaExe                = $null
$script:7zaAvailable          = $false

if ([string]::IsNullOrEmpty($script:TekEdgeRootDir)) {
    Write-Warning "[ WARN ] TekEdge-7zip module - `$env:TekEdgeRoot is not set. 7-Zip functions will not work until it is defined."
} else {
    $script:TekEdgeTools          = Join-Path $script:TekEdgeRootDir '_tools'
    $script:TekEdgeToolsUtilities = Join-Path $script:TekEdgeTools   '_utilities'
    $script:7zaExe                = Join-Path $script:TekEdgeToolsUtilities '7za.exe'

    if (Test-Path -PathType Leaf $script:7zaExe) {
        $script:7zaAvailable = $true
    } else {
        Write-Warning "[ WARN ] TekEdge-7zip module - 7za.exe not found at: $($script:7zaExe). 7-Zip functions will not work until it is present."
    }
}

#######################################################################
#                          HELPER FUNCTIONS                           #
#######################################################################

<#
.SYNOPSIS
    Writes a consistently formatted status line to the console.

.PARAMETER Message
    The message text to display.

.PARAMETER Level
    The severity level. Accepted values: OK, WARN, ERROR, INFO (default).
#>
function Write-Status {
    param(
        [string]$Message,
        [string]$Level
    )

    switch ($Level) {
        "OK"    { Write-Host "[  OK  ] $Message" }
        "WARN"  { Write-Host "[ WARN ] $Message" }
        "ERROR" { Write-Host "[ FAIL ] $Message" }
        default { Write-Host "[ INFO ] $Message" }
    }
}

<#
.SYNOPSIS
    Internal function. Invokes 7za.exe with the specified arguments and returns output lines.

.PARAMETER ArgumentList
    Array of arguments to pass to 7za.exe.

.PARAMETER RedactPassword
    If $true, replaces the password value in logged argument output with (supplied).

.OUTPUTS
    [string[]] Lines of output from 7za.exe.
    Returns $null and writes an error status if 7za.exe is unavailable or the process fails.
#>
function Invoke-7za {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [switch]$RedactPassword
    )

    if (-not $script:7zaAvailable) {
        Write-Status -Level ERROR -Message "ERROR - 7za.exe is not available. Check that `$env:TekEdgeRoot is set and 7za.exe is installed."
        return $null
    }

    # Build a display-safe version of the argument list for logging
    if ($RedactPassword) {
        $displayArgs = @()
        $skipNext = $false
        foreach ($arg in $ArgumentList) {
            if ($skipNext) {
                $displayArgs += '(supplied)'
                $skipNext = $false
            } elseif ($arg -match '^-p') {
                # Password is appended directly: -pSECRET or as separate arg -p SECRET
                if ($arg -eq '-p') {
                    $displayArgs += '-p'
                    $skipNext = $true
                } else {
                    $displayArgs += '-p(supplied)'
                }
            } else {
                $displayArgs += $arg
            }
        }
    } else {
        $displayArgs = $ArgumentList
    }

    Write-Status -Level INFO -Message "7za.exe $($displayArgs -join ' ')"

    try {
        $output = & $script:7zaExe @ArgumentList 2>&1
        return $output
    } catch {
        Write-Status -Level ERROR -Message "ERROR - Failed to invoke 7za.exe: $($_.Exception.Message)"
        return $null
    }
}

#######################################################################
#                         EXPORTED FUNCTIONS                          #
#######################################################################

<#
.SYNOPSIS
    Creates a .7z archive from one or more source paths.

.DESCRIPTION
    Uses 7za.exe to compress files or directories into a .7z archive.
    Supports optional AES-256 password encryption (encrypts file data and headers).
    If the archive already exists it will be updated (files added or replaced).

.PARAMETER ArchivePath
    Full path to the .7z archive to create or update.

.PARAMETER SourcePath
    One or more file or directory paths to add to the archive.
    Wildcards are supported (e.g. 'C:\Logs\*.log').

.PARAMETER Password
    Optional. Password to encrypt the archive with AES-256.
    File headers are also encrypted (-mhe=on).

.PARAMETER Recurse
    If specified, includes subdirectories recursively.

.PARAMETER CompressionLevel
    Compression level 0-9. Default is 5.
    0 = store only (fastest), 9 = maximum compression (slowest).

.EXAMPLE
    Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs'
    Compresses the C:\Logs directory into logs.7z.

.EXAMPLE
    Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs\*.log' -Recurse -Password 'S3cr3t!'
    Compresses all .log files recursively with AES-256 encryption.

.OUTPUTS
    [bool] $true on success, $false on failure.
#>
function Compress-7z {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string[]]$SourcePath,

        [string]$Password,

        [switch]$Recurse,

        [ValidateRange(0, 9)]
        [int]$CompressionLevel = 5
    )

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # Build argument list
    $args7z = @('a', '-t7z', "-mx=$CompressionLevel", '-bd', '-y')

    if ($Recurse)      { $args7z += '-r'       }
    if ($hasPassword)  { $args7z += "-p$Password"; $args7z += '-mhe=on' }

    $args7z += $ArchivePath
    $args7z += $SourcePath

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    if ($null -eq $output) {
        return $false
    }

    $outputStr = $output -join "`n"

    if ($outputStr -match 'Everything is Ok') {
        Write-Status -Level OK -Message "Archive created/updated: $ArchivePath"
        return $true
    } else {
        Write-Status -Level ERROR -Message "ERROR - Compress-7z failed for: $ArchivePath"
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}

<#
.SYNOPSIS
    Extracts files from a .7z archive.

.DESCRIPTION
    Uses 7za.exe to extract files from an existing .7z archive to a specified destination.
    By default skips files that already exist at the destination. Use -Force to overwrite.

.PARAMETER ArchivePath
    Full path to the .7z archive to extract.

.PARAMETER Destination
    Directory to extract files into. Defaults to the current directory.
    Created automatically if it does not exist.

.PARAMETER Password
    Optional. Password for encrypted archives.

.PARAMETER Force
    If specified, overwrites existing files at the destination.
    Default behavior is to skip existing files.

.PARAMETER IncludeFilter
    Optional. One or more file name patterns to extract (e.g. '*.log').
    If omitted, all files are extracted.

.EXAMPLE
    Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore'
    Extracts all files from logs.7z into C:\Restore.

.EXAMPLE
    Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore' -Password 'S3cr3t!' -Force
    Extracts an encrypted archive, overwriting any existing files.

.OUTPUTS
    [bool] $true on success, $false on failure.
#>
function Expand-7z {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [string]$Destination = '.',

        [string]$Password,

        [switch]$Force,

        [string[]]$IncludeFilter = @()
    )

    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $false
    }

    # Create destination if needed
    if (-not (Test-Path $Destination)) {
        try {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        } catch {
            Write-Status -Level ERROR -Message "ERROR - Could not create destination directory '$Destination': $($_.Exception.Message)"
            return $false
        }
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # e = extract flat (no paths); x = extract with full paths
    # Using x to preserve directory structure
    $args7z = @('x', '-bd', '-y')

    if ($Force) { $args7z += '-aoa' } else { $args7z += '-aos' }
    if ($hasPassword) { $args7z += "-p$Password" }

    $args7z += "-o$Destination"
    $args7z += $ArchivePath

    if ($IncludeFilter.Count -gt 0) {
        $args7z += $IncludeFilter
    }

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    if ($null -eq $output) {
        return $false
    }

    $outputStr = $output -join "`n"

    if ($outputStr -match 'Everything is Ok') {
        Write-Status -Level OK -Message "Archive extracted to: $Destination"

        # Report any skipped files
        $skipped = $output | Where-Object { $_ -match '^Skipping' }
        if ($skipped) {
            Write-Status -Level WARN -Message "Skipped $($skipped.Count) existing file(s) (use -Force to overwrite)"
            $skipped | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        }
        return $true
    } else {
        Write-Status -Level ERROR -Message "ERROR - Expand-7z failed for: $ArchivePath"
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}

<#
.SYNOPSIS
    Tests the integrity of a .7z archive.

.DESCRIPTION
    Uses 7za.exe to verify that all files in a .7z archive are intact and readable.
    Optionally tests an encrypted archive by supplying the password.

.PARAMETER ArchivePath
    Full path to the .7z archive to test.

.PARAMETER Password
    Optional. Password for encrypted archives.

.EXAMPLE
    Test-7zArchive -ArchivePath 'C:\Backups\logs.7z'
    Tests the integrity of logs.7z.

.EXAMPLE
    Test-7zArchive -ArchivePath 'C:\Backups\logs.7z' -Password 'S3cr3t!'
    Tests an encrypted archive.

.OUTPUTS
    [bool] $true if archive is OK, $false if errors were found or archive not found.
#>
function Test-7zArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [string]$Password
    )

    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $false
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    $args7z = @('t', '-bd', '-y')

    if ($hasPassword) { $args7z += "-p$Password" }

    $args7z += $ArchivePath

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    if ($null -eq $output) {
        return $false
    }

    $outputStr = $output -join "`n"

    if ($outputStr -match 'Everything is Ok') {
        Write-Status -Level OK -Message "Archive integrity OK: $ArchivePath"
        return $true
    } elseif ($outputStr -match 'No files to process') {
        Write-Status -Level WARN -Message "Archive is empty: $ArchivePath"
        return $true
    } else {
        Write-Status -Level ERROR -Message "ERROR - Archive integrity test FAILED: $ArchivePath"
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}

<#
.SYNOPSIS
    Lists the contents of a .7z archive.

.DESCRIPTION
    Uses 7za.exe to enumerate files inside a .7z archive.
    Returns an array of PSCustomObjects, one per file, with properties:
      Name       [string]   - File path within the archive
      DateTime   [DateTime] - Last modified timestamp
      Size       [long]     - Uncompressed size in bytes
      Compressed [long]     - Compressed size in bytes
      Mode       [string]   - Attribute flags (e.g. ....A)

.PARAMETER ArchivePath
    Full path to the .7z archive to list.

.PARAMETER Password
    Optional. Password for encrypted archives.

.EXAMPLE
    Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
    Returns a list of file objects from the archive.

.EXAMPLE
    $files = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
    $files | ForEach-Object { Write-Host "- $($_.Name) ($($_.Size) bytes)" }

.OUTPUTS
    [PSCustomObject[]] Array of file entry objects. Returns empty array on failure.
#>
function Get-7zArchive {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [string]$Password
    )

    $emptyResult = @()

    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $emptyResult
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    $args7z = @('l', '-bd', '-slt')  # -slt = technical listing (machine-parseable)

    if ($hasPassword) { $args7z += "-p$Password" }

    $args7z += $ArchivePath

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    if ($null -eq $output) {
        return $emptyResult
    }

    $outputStr = $output -join "`n"

    if ($outputStr -match 'Cannot open encrypted archive') {
        Write-Status -Level ERROR -Message "ERROR - Archive is encrypted. Supply -Password to list contents."
        return $emptyResult
    }

    # Parse -slt technical output: blocks of key = value pairs separated by blank lines
    $entries   = New-Object System.Collections.ArrayList
    $current   = $null
    $inEntries = $false

    foreach ($line in $output) {
        # The file entry blocks begin after the "----------" separator line
        if ($line -match '^-{5,}') {
            $inEntries = $true
            continue
        }

        if (-not $inEntries) { continue }

        if ([string]::IsNullOrWhiteSpace($line)) {
            # Blank line = end of a block; save current entry if it has a name
            if ($null -ne $current -and -not [string]::IsNullOrEmpty($current.Name)) {
                [void]$entries.Add($current)
            }
            $current = $null
            continue
        }

        if ($line -match '^([^=]+?)\s*=\s*(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            if ($null -eq $current) {
                $current = New-Object PSObject -Property @{
                    Name       = ''
                    DateTime   = [DateTime]::MinValue
                    Size       = [long]0
                    Compressed = [long]0
                    Mode       = ''
                }
            }

            switch ($key) {
                'Path'     { $current.Name = $value }
                'Modified' {
                    try {
                        $current.DateTime = [DateTime]::ParseExact(
                            $value,
                            'yyyy-MM-dd HH:mm:ss',
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                    } catch {
                        $current.DateTime = [DateTime]::MinValue
                    }
                }
                'Size'     {
                    $parsed = [long]0
                    if ([long]::TryParse($value, [ref]$parsed)) { $current.Size = $parsed }
                }
                'Packed Size' {
                    $parsed = [long]0
                    if ([long]::TryParse($value, [ref]$parsed)) { $current.Compressed = $parsed }
                }
                'Attributes' { $current.Mode = $value }
            }
        }
    }

    # Capture last entry if output doesn't end with a blank line
    if ($null -ne $current -and -not [string]::IsNullOrEmpty($current.Name)) {
        [void]$entries.Add($current)
    }

    if ($entries.Count -gt 0) {
        Write-Status -Level OK -Message "Listed $($entries.Count) item(s) in: $ArchivePath"
    } else {
        Write-Status -Level WARN -Message "No files found in archive: $ArchivePath"
    }

    return $entries.ToArray()
}

#######################################################################
#                            MODULE EXPORTS                           #
#######################################################################

Export-ModuleMember -Function @(
    'Write-Status',
    'Compress-7z',
    'Expand-7z',
    'Test-7zArchive',
    'Get-7zArchive'
)
