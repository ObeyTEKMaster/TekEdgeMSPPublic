<#
.SYNOPSIS
    PowerShell module providing 7-Zip wrapper functions for use in TekEdge RMM scripts.

.DESCRIPTION
    Wraps 7za.exe (standalone 7-Zip) to provide compress, expand, test, and list
    operations on .7z archives, with optional password/encryption support.
    Designed to be imported by other TekEdge helper and RMM scripts.

    This is NOT a standalone script. It must be imported by a calling script
    using Import-Module. See TekEdge-7zip.md for full usage instructions.

    Requires $env:TekEdgeRoot to be set (e.g. C:\ProgramData\TekEdgeTools).
    Expects 7za.exe at: $env:TekEdgeRoot\_tools\_utilities\7za.exe

    Functions exported by this module:
      Write-Status   - Writes a formatted [  OK  ] / [ WARN ] / [ FAIL ] / [ INFO ] status line
      Compress-7z    - Create or add to a .7z archive
      Expand-7z      - Extract files from a .7z archive
      Test-7zArchive - Test integrity of a .7z archive
      Get-7zArchive  - List contents of a .7z archive (returns objects)

.NOTES
    Author: TekEdge Consulting, with assistance from Claude

    Changelog:
      v1.0.0 - 05/21/2025 - Initial release

    See TekEdge-7zip.md for full documentation, parameter tables, and usage examples.
#>

# Set-StrictMode -Version Latest tells PowerShell to be strict about coding rules.
# It will throw errors for things like using uninitialized variables or calling
# functions with wrong syntax, instead of silently continuing. This helps catch
# bugs early. "Latest" means use the strictest rules available in this PS version.
Set-StrictMode -Version Latest


#######################################################################
#                            MODULE INIT                              #
#######################################################################
#
# This block runs once, automatically, when the module is imported by a
# calling script (Import-Module). It figures out where 7za.exe lives and
# sets a module-level flag ($script:7zaAvailable) that every function
# checks before trying to run 7za.exe.
#
# The $script: prefix means these variables belong to the module's own
# scope and won't collide with variables in the calling script.
#######################################################################

# Read the TekEdge root path from the system environment variable.
# This variable is set once by the TekEdge install script.
# Example value: C:\ProgramData\TekEdgeTools
$script:TekEdgeRootDir        = $env:TekEdgeRoot

# Pre-declare the path variables as $null so they exist even if we never
# populate them (required by Set-StrictMode - you can't use a variable
# that was never declared).
$script:TekEdgeTools          = $null
$script:TekEdgeToolsUtilities = $null
$script:7zaExe                = $null

# This flag is checked by every function before calling 7za.exe.
# Starts as $false; only set to $true if 7za.exe is actually found.
$script:7zaAvailable          = $false

# Check that the environment variable was actually set before we try to
# build paths from it. IsNullOrEmpty catches both $null and "" (empty string).
if ([string]::IsNullOrEmpty($script:TekEdgeRootDir)) {
    # Module still loads, but all 7-Zip functions will fail gracefully when called.
    Write-Warning "[ WARN ] TekEdge-7zip module - `$env:TekEdgeRoot is not set. 7-Zip functions will not work until it is defined."
} else {
    # Build the path to 7za.exe by joining folder names step by step.
    # Join-Path handles the backslashes for us cleanly.
    # Result: C:\ProgramData\TekEdgeTools\_tools\_utilities\7za.exe
    $script:TekEdgeTools          = Join-Path $script:TekEdgeRootDir '_tools'
    $script:TekEdgeToolsUtilities = Join-Path $script:TekEdgeTools   '_utilities'
    $script:7zaExe                = Join-Path $script:TekEdgeToolsUtilities '7za.exe'

    # -PathType Leaf means "this must be a file, not a folder".
    # Confirms 7za.exe actually exists at the expected location.
    if (Test-Path -PathType Leaf $script:7zaExe) {
        $script:7zaAvailable = $true
    } else {
        # Module still loads, but all functions will fail gracefully when called.
        Write-Warning "[ WARN ] TekEdge-7zip module - 7za.exe not found at: $($script:7zaExe). 7-Zip functions will not work until it is present."
    }
}


#######################################################################
#                          HELPER FUNCTIONS                           #
#######################################################################
#
# These functions are used internally by this module. Write-Status is
# also exported so calling scripts can use the same formatting.
# Invoke-7za is internal only - calling scripts should never call it
# directly.
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

    # Each level maps to a fixed prefix tag so RMM output is easy to scan.
    # The default (INFO) catches any Level value not explicitly listed.
    switch ($Level) {
        "OK"    { Write-Host "[  OK  ] $Message" }
        "WARN"  { Write-Host "[ WARN ] $Message" }
        "ERROR" { Write-Host "[ FAIL ] $Message" }
        default { Write-Host "[ INFO ] $Message" }
    }
}


<#
.SYNOPSIS
    Internal function. Invokes 7za.exe with the specified arguments and
    returns its output as an array of strings.

.DESCRIPTION
    All exported functions call this instead of calling 7za.exe directly.
    Centralizes availability checking, safe argument logging (password
    redaction), error handling, and output capture in one place.

    This function is NOT exported. Calling scripts should never call it.

.PARAMETER ArgumentList
    Array of command-line arguments to pass to 7za.exe.
    Example: @('a', '-t7z', '-mx=5', 'C:\backup.7z', 'C:\Logs')

.PARAMETER RedactPassword
    Switch. When present, scans the argument list before logging and
    replaces any password value with "(supplied)" so it never appears
    in console output or RMM logs.

.OUTPUTS
    [string[]] Lines of text output from 7za.exe, or $null on failure.
#>
function Invoke-7za {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [switch]$RedactPassword
    )

    # Safety check - if 7za.exe was not found during module init, fail
    # immediately with a clear message rather than a confusing file-not-found error.
    if (-not $script:7zaAvailable) {
        Write-Status -Level ERROR -Message "ERROR - 7za.exe is not available. Check that `$env:TekEdgeRoot is set and 7za.exe is installed."
        return $null
    }

    # Build a safe copy of the argument list for display/logging purposes.
    # We never want a password appearing in RMM console output or log files.
    if ($RedactPassword) {
        $displayArgs = @()    # Will hold the sanitized argument list
        $skipNext    = $false # Tracks if the NEXT argument is a password value

        foreach ($arg in $ArgumentList) {
            if ($skipNext) {
                # The previous argument was a bare "-p", so this arg IS the password.
                # Replace it with a placeholder.
                $displayArgs += '(supplied)'
                $skipNext     = $false
            } elseif ($arg -match '^-p') {
                # 7za.exe accepts passwords two ways:
                #   -pMYPASSWORD  (password glued directly onto the flag)
                #   -p MYPASSWORD (password as a separate argument after -p)
                if ($arg -eq '-p') {
                    # Bare "-p" flag - the actual password is the next argument.
                    # Add the flag itself but flag that we need to redact the next arg.
                    $displayArgs += '-p'
                    $skipNext     = $true
                } else {
                    # Password is glued on: replace everything after "-p" with placeholder.
                    $displayArgs += '-p(supplied)'
                }
            } else {
                # Not a password argument - safe to log as-is.
                $displayArgs += $arg
            }
        }
    } else {
        # No password in this call - use the argument list as-is for display.
        $displayArgs = $ArgumentList
    }

    # Log the command we are about to run. The -join ' ' converts the array
    # to a readable space-separated string: "a -t7z -mx=5 C:\backup.7z C:\Logs"
    Write-Status -Level INFO -Message "7za.exe $($displayArgs -join ' ')"

    try {
        # The & operator calls an external executable stored in a variable.
        # @ArgumentList "splatting" passes the array as individual arguments,
        # which is safer than building a single string and using Invoke-Expression.
        # 2>&1 redirects stderr (stream 2) into stdout (stream 1) so we capture
        # any error text that 7za.exe writes to stderr as well.
        $output = & $script:7zaExe @ArgumentList 2>&1
        return $output
    } catch {
        # $_.Exception.Message gives the actual .NET exception text.
        Write-Status -Level ERROR -Message "ERROR - Failed to invoke 7za.exe: $($_.Exception.Message)"
        return $null
    }
}


#######################################################################
#                         EXPORTED FUNCTIONS                          #
#######################################################################
#
# These are the functions that calling scripts use. Each one:
#  1. Validates inputs
#  2. Builds the 7za.exe argument list
#  3. Calls Invoke-7za
#  4. Parses the output to determine success or failure
#  5. Returns $true/$false (or objects for Get-7zArchive)
#
# See TekEdge-7zip.md for full parameter tables and usage examples.
#######################################################################

<#
.SYNOPSIS
    Creates a .7z archive from one or more source paths.

.DESCRIPTION
    Uses 7za.exe to compress files or directories into a .7z archive.
    Supports optional AES-256 password encryption. Encrypts file data
    AND file headers (-mhe=on), meaning even file names are hidden
    from anyone without the password.
    If the archive already exists, files are added or replaced (other
    existing files in the archive are left intact).

.PARAMETER ArchivePath
    Full path to the .7z archive to create or update.

.PARAMETER SourcePath
    One or more file or directory paths to add to the archive.
    Wildcards are supported (e.g. 'C:\Logs\*.log').

.PARAMETER Password
    Optional. Password to encrypt the archive with AES-256.
    Never logged to console or RMM output.

.PARAMETER Recurse
    If specified, includes all subdirectories recursively.

.PARAMETER CompressionLevel
    Compression level 0-9. Default is 5 (balanced).
    0 = store only, no compression (fastest, largest file).
    9 = maximum compression (slowest, smallest file).

.EXAMPLE
    Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs'

.EXAMPLE
    Compress-7z -ArchivePath 'C:\Backups\logs.7z' -SourcePath 'C:\Logs\*.log' -Recurse -Password 'S3cr3t!'

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

        # ValidateRange ensures callers can't accidentally pass 10 or -1
        [ValidateRange(0, 9)]
        [int]$CompressionLevel = 5
    )

    # Determine once whether a password was supplied. Used in multiple places below.
    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # Build the 7za.exe argument array piece by piece.
    # Each element becomes a separate command-line argument.
    #
    #  'a'                  = Add (create or update archive)
    #  '-t7z'               = Archive type: 7z format
    #  "-mx=$CompressionLevel" = Compression level (e.g. -mx=5)
    #  '-bd'                = Disable progress percentage display (cleaner RMM output)
    #  '-y'                 = Yes to all prompts (non-interactive / unattended)
    $args7z = @('a', '-t7z', "-mx=$CompressionLevel", '-bd', '-y')

    # Add recursion flag if requested (-r tells 7za to include all subdirectories)
    if ($Recurse) { $args7z += '-r' }

    if ($hasPassword) {
        # -pPASSWORD sets the encryption password (AES-256).
        # Note: password is glued directly onto "-p" with no space - that is
        # the format 7za.exe requires. Example: -pMySecret123
        $args7z += "-p$Password"

        # -mhe=on = encrypt archive Headers. Without this, file names inside
        # the archive are visible even without the password. With it, the entire
        # archive contents are hidden.
        $args7z += '-mhe=on'
    }

    # Archive path and source path(s) go at the end of the argument list.
    # += on an array appends the value(s).
    $args7z += $ArchivePath
    $args7z += $SourcePath  # May be a single path or an array of paths

    # Call 7za.exe. Pass RedactPassword so the password never appears in output.
    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    # Invoke-7za returns $null if 7za.exe could not be called at all.
    if ($null -eq $output) {
        return $false
    }

    # Join all output lines into one string for easier pattern matching.
    # 7za.exe prints "Everything is Ok" on the last line if the operation succeeded.
    $outputStr = $output -join "`n"

    if ($outputStr -match 'Everything is Ok') {
        Write-Status -Level OK -Message "Archive created/updated: $ArchivePath"
        return $true
    } else {
        Write-Status -Level ERROR -Message "ERROR - Compress-7z failed for: $ArchivePath"
        # Print each line of 7za output to help diagnose the failure.
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}


<#
.SYNOPSIS
    Extracts files from a .7z archive.

.DESCRIPTION
    Uses 7za.exe to extract files from an existing .7z archive.
    Preserves the directory structure stored inside the archive.
    The destination directory is created automatically if it does not exist.
    By default, files that already exist at the destination are skipped.
    Use -Force to overwrite them instead.

.PARAMETER ArchivePath
    Full path to the .7z archive to extract.

.PARAMETER Destination
    Directory path to extract files into. Defaults to current directory.
    Created automatically if it does not exist.

.PARAMETER Password
    Optional. Password for encrypted archives.
    Never logged to console or RMM output.

.PARAMETER Force
    If specified, existing files at the destination are overwritten.
    Default behavior (without -Force) is to skip existing files.

.PARAMETER IncludeFilter
    Optional. One or more filename patterns to selectively extract.
    Example: @('*.log', '*.txt') extracts only .log and .txt files.
    If omitted, all files are extracted.

.EXAMPLE
    Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore'

.EXAMPLE
    Expand-7z -ArchivePath 'C:\Backups\logs.7z' -Destination 'C:\Restore' -Password 'S3cr3t!' -Force

.OUTPUTS
    [bool] $true on success, $false on failure.
#>
function Expand-7z {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        # Default '.' means "current working directory" if no destination given
        [string]$Destination = '.',

        [string]$Password,

        [switch]$Force,

        # Empty array default means "no filter applied = extract everything"
        [string[]]$IncludeFilter = @()
    )

    # Verify the archive file actually exists before we try to extract it.
    # -PathType Leaf = must be a file (not a folder).
    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $false
    }

    # Create the destination directory if it doesn't already exist.
    if (-not (Test-Path $Destination)) {
        try {
            # -Force here means "create any missing parent directories too"
            # (e.g. if C:\Restore\SubFolder doesn't exist, create both).
            # | Out-Null suppresses the directory object that New-Item returns.
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        } catch {
            Write-Status -Level ERROR -Message "ERROR - Could not create destination directory '$Destination': $($_.Exception.Message)"
            return $false
        }
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # Build the 7za.exe argument array.
    #
    #  'x'   = eXtract with full paths (preserves folder structure from archive).
    #          (Use 'e' instead if you want all files dumped flat into one folder.)
    #  '-bd' = Disable progress percentage (cleaner RMM output)
    #  '-y'  = Yes to all prompts (non-interactive)
    $args7z = @('x', '-bd', '-y')

    # Overwrite behavior flag:
    #  -aoa = Overwrite All  (used when -Force is specified)
    #  -aos = Skip existing  (default - safer, won't clobber existing files)
    if ($Force) { $args7z += '-aoa' } else { $args7z += '-aos' }

    # Append password if provided. Glued directly: -pMYPASSWORD
    if ($hasPassword) { $args7z += "-p$Password" }

    # -o sets the output/destination directory. Glued directly: -oC:\Restore
    # (no space between -o and the path - that is 7za.exe's required format)
    $args7z += "-o$Destination"
    $args7z += $ArchivePath

    # If the caller only wants specific files extracted, append those patterns.
    # 7za.exe treats trailing arguments after the archive path as file filters.
    if ($IncludeFilter.Count -gt 0) {
        $args7z += $IncludeFilter
    }

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    # Invoke-7za returns $null if 7za.exe could not be called at all.
    if ($null -eq $output) {
        return $false
    }

    $outputStr = $output -join "`n"

    if ($outputStr -match 'Everything is Ok') {
        Write-Status -Level OK -Message "Archive extracted to: $Destination"

        # When -Force was NOT used, 7za.exe prints "Skipping  filename" for each
        # file it skips. Surface these as warnings so the caller is aware.
        $skipped = $output | Where-Object { $_ -match '^Skipping' }
        if ($skipped) {
            Write-Status -Level WARN -Message "Skipped $($skipped.Count) existing file(s) (use -Force to overwrite)"
            $skipped | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        }
        return $true
    } else {
        Write-Status -Level ERROR -Message "ERROR - Expand-7z failed for: $ArchivePath"
        # Print all 7za output lines to help diagnose what went wrong.
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}


<#
.SYNOPSIS
    Tests the integrity of a .7z archive.

.DESCRIPTION
    Uses 7za.exe to verify every file in the archive passes its stored
    checksum. No files are extracted. Useful for verifying a backup
    archive is intact before relying on it.

.PARAMETER ArchivePath
    Full path to the .7z archive to test.

.PARAMETER Password
    Optional. Required for encrypted archives - without it the test
    will fail because 7za.exe cannot read the encrypted content.

.EXAMPLE
    Test-7zArchive -ArchivePath 'C:\Backups\logs.7z'

.EXAMPLE
    Test-7zArchive -ArchivePath 'C:\Backups\logs.7z' -Password 'S3cr3t!'

.OUTPUTS
    [bool] $true if archive is intact (or empty), $false on any error.
#>
function Test-7zArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [string]$Password
    )

    # Verify the archive exists before passing it to 7za.exe.
    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $false
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # Build the 7za.exe argument array.
    #
    #  't'   = Test archive integrity
    #  '-bd' = Disable progress percentage
    #  '-y'  = Yes to all prompts
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
        # Archive exists and opened successfully, it just has nothing in it.
        # That's not an error - return true with a warning.
        Write-Status -Level WARN -Message "Archive is empty: $ArchivePath"
        return $true
    } else {
        # Any other result from 7za.exe means the test failed (corruption,
        # wrong password, unsupported format, etc.).
        Write-Status -Level ERROR -Message "ERROR - Archive integrity test FAILED: $ArchivePath"
        $output | ForEach-Object { Write-Status -Level INFO -Message "- $_" }
        return $false
    }
}


<#
.SYNOPSIS
    Lists the contents of a .7z archive and returns structured objects.

.DESCRIPTION
    Uses 7za.exe with the -slt (technical listing) flag to get detailed
    file information in a reliable key=value format, then parses that
    output into PowerShell objects the calling script can work with.

    Returns one PSCustomObject per file/directory entry, with properties:
      Name       [string]   - File path as stored inside the archive
      DateTime   [DateTime] - Last modified timestamp of the file
      Size       [long]     - Uncompressed size in bytes
      Compressed [long]     - Compressed size in bytes
      Mode       [string]   - Attribute flags (e.g. "....A" = Archive,
                              "D...." = Directory)

    See TekEdge-7zip.md - Get-7zArchive section for filtering examples.

.PARAMETER ArchivePath
    Full path to the .7z archive to list.

.PARAMETER Password
    Optional. Required for encrypted archives.

.EXAMPLE
    Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'

.EXAMPLE
    $files = Get-7zArchive -ArchivePath 'C:\Backups\logs.7z'
    $files | ForEach-Object { Write-Host "$($_.Name) - $($_.Size) bytes" }

.OUTPUTS
    [PSCustomObject[]] Array of file entry objects. Empty array on failure
    (never returns $null, so callers can safely use .Count without null checks).
#>
function Get-7zArchive {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [string]$Password
    )

    # Define a reusable empty array to return on any failure path.
    # Returning @() instead of $null means callers can safely do
    # $files.Count without getting a null reference error.
    $emptyResult = @()

    if (-not (Test-Path -PathType Leaf $ArchivePath)) {
        Write-Status -Level ERROR -Message "ERROR - Archive not found: $ArchivePath"
        return $emptyResult
    }

    $hasPassword = -not [string]::IsNullOrEmpty($Password)

    # Build the 7za.exe argument array.
    #
    #  'l'    = List archive contents
    #  '-bd'  = Disable progress percentage
    #  '-slt' = Show Technical Listing - outputs key = value pairs instead of
    #           a formatted table. Much easier and safer to parse than fixed-
    #           width columns. See TekEdge-7zip.md for example output format.
    $args7z = @('l', '-bd', '-slt')

    if ($hasPassword) { $args7z += "-p$Password" }

    $args7z += $ArchivePath

    $output = Invoke-7za -ArgumentList $args7z -RedactPassword:$hasPassword

    if ($null -eq $output) {
        return $emptyResult
    }

    # Join output lines for a quick string check before we start parsing.
    $outputStr = $output -join "`n"

    # If the archive is encrypted and no password was given, 7za.exe will print
    # this specific message. Catch it early with a helpful error.
    if ($outputStr -match 'Cannot open encrypted archive') {
        Write-Status -Level ERROR -Message "ERROR - Archive is encrypted. Supply -Password to list contents."
        return $emptyResult
    }

    # -----------------------------------------------------------------------
    # Parse the -slt output into objects.
    #
    # The -slt output looks like this (simplified):
    #
    #   7-Zip 22.01 ...header lines...
    #   --                          <- separator line (5+ dashes)
    #   Path = folder\file.log      <- file entry block starts
    #   Modified = 2025-01-15 09:30:00
    #   Attributes = ....A
    #   Size = 4096
    #   Packed Size = 1024
    #                               <- blank line = end of this entry
    #   Path = folder\other.log     <- next entry starts
    #   ...
    #
    # We walk each line, wait for the separator, then collect key=value
    # pairs into an object until we hit a blank line.
    # -----------------------------------------------------------------------

    # ArrayList is used because we can .Add() to it in a loop. A regular
    # PowerShell array (@()) would create a new copy every time we += to it,
    # which is slow for large archives.
    $entries   = New-Object System.Collections.ArrayList

    # $current holds the object we are currently building from a file entry block.
    # $null means we are not inside an entry block yet.
    $current   = $null

    # Flag - stays $false until we see the separator line.
    # Lines before the separator are header/summary info we do not need.
    $inEntries = $false

    foreach ($line in $output) {

        # Check for the separator line that marks the start of file entries.
        # '^-{5,}' matches a line starting with 5 or more dashes.
        if ($line -match '^-{5,}') {
            $inEntries = $true
            continue    # Skip the separator line itself
        }

        # Skip all lines before the separator
        if (-not $inEntries) { continue }

        # A blank line signals the end of a file entry block.
        if ([string]::IsNullOrWhiteSpace($line)) {
            # If we were building an entry and it has a name, save it.
            if ($null -ne $current -and -not [string]::IsNullOrEmpty($current.Name)) {
                # [void] suppresses the return value from .Add() (an index number)
                # so it doesn't pollute the function's output stream.
                [void]$entries.Add($current)
            }
            # Reset for the next entry block
            $current = $null
            continue
        }

        # Try to match a "Key = Value" line.
        # Regex breakdown:
        #   ^           = start of line
        #   ([^=]+?)    = capture group 1: one or more chars that are NOT "=", lazy
        #   \s*=\s*     = equals sign with optional whitespace on either side
        #   (.*)$       = capture group 2: everything after the equals sign
        if ($line -match '^([^=]+?)\s*=\s*(.*)$') {
            $key   = $Matches[1].Trim()   # e.g. "Path", "Modified", "Size"
            $value = $Matches[2].Trim()   # e.g. "folder\file.log", "2025-01-15 09:30:00"

            # If this is the first key=value line of a new entry, create the object.
            # Using New-Object instead of [PSCustomObject]@{} for PS 5.1 compatibility.
            if ($null -eq $current) {
                $current = New-Object PSObject -Property @{
                    Name       = ''
                    DateTime   = [DateTime]::MinValue   # Sentinel - means "not parsed yet"
                    Size       = [long]0
                    Compressed = [long]0
                    Mode       = ''
                }
            }

            # Map the 7za.exe key names to our object property names.
            switch ($key) {
                'Path' {
                    $current.Name = $value
                }
                'Modified' {
                    # ParseExact is used instead of [DateTime]$value because
                    # it enforces the exact format 7za.exe outputs, regardless
                    # of the system's regional date/time settings.
                    # InvariantCulture means "don't use locale-specific formatting".
                    try {
                        $current.DateTime = [DateTime]::ParseExact(
                            $value,
                            'yyyy-MM-dd HH:mm:ss',
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                    } catch {
                        # If the date can't be parsed for any reason, leave as MinValue
                        # rather than throwing and aborting the whole listing.
                        $current.DateTime = [DateTime]::MinValue
                    }
                }
                'Size' {
                    # TryParse is safer than casting ([long]$value) because it
                    # won't throw if the value is empty or non-numeric (which can
                    # happen for directory entries in some archive types).
                    # [ref] passes $parsed by reference so TryParse can write into it.
                    $parsed = [long]0
                    if ([long]::TryParse($value, [ref]$parsed)) { $current.Size = $parsed }
                }
                'Packed Size' {
                    $parsed = [long]0
                    if ([long]::TryParse($value, [ref]$parsed)) { $current.Compressed = $parsed }
                }
                'Attributes' {
                    # Example values: "....A" (file), "D...." (directory)
                    $current.Mode = $value
                }
                # Any other keys (CRC, Method, Block, etc.) are intentionally
                # ignored - we only surface the properties callers need.
            }
        }
    }

    # Edge case: if the output did not end with a blank line, the last entry
    # will not have been saved by the blank-line handler above. Save it now.
    if ($null -ne $current -and -not [string]::IsNullOrEmpty($current.Name)) {
        [void]$entries.Add($current)
    }

    if ($entries.Count -gt 0) {
        Write-Status -Level OK -Message "Listed $($entries.Count) item(s) in: $ArchivePath"
    } else {
        Write-Status -Level WARN -Message "No files found in archive: $ArchivePath"
    }

    # .ToArray() converts the ArrayList to a standard PowerShell array.
    # This is the expected return type and works cleanly with pipelines
    # and foreach loops in the calling script.
    return $entries.ToArray()
}


#######################################################################
#                            MODULE EXPORTS                           #
#######################################################################
#
# Export-ModuleMember controls which functions are visible to scripts
# that import this module. Functions NOT listed here are private to
# this module (e.g. Invoke-7za - callers should never call it directly).
#
# Write-Status is exported so calling scripts get the same consistent
# output formatting without having to define their own copy.
#######################################################################

Export-ModuleMember -Function @(
    'Write-Status',
    'Compress-7z',
    'Expand-7z',
    'Test-7zArchive',
    'Get-7zArchive'
)
