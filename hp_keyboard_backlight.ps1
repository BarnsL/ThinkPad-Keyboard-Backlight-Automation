# hp_keyboard_backlight.ps1
#
# Best-effort keyboard backlight persistence for HP EliteBook systems.
#
# This script does not use undocumented kernel IOCTLs. Instead it uses HP's
# documented BIOS automation surfaces (HP CMSL cmdlets, with a WMI fallback)
# to keep keyboard backlight timeout/enable settings configured.

param(
    [ValidateRange(0, 2)]
    [int]$Level = 1,

    [ValidateRange(0, 30)]
    [int]$InitialDelaySeconds = 2,

    [switch]$EnsureMonitor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $scriptDir "keyboard_backlight.log"

if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 262144)) {
    Move-Item $logPath "$logPath.1" -Force
}

function Write-BacklightLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logPath -Value "$timestamp [hp] $Message" -Encoding UTF8
}

function Get-ObjectStringProperty {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $Object.PSObject.Properties[$propertyName]
        if ($null -ne $property) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return $null
}

function Get-ObjectStringArrayProperty {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $Object.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $null -eq $property.Value) {
            continue
        }

        $rawValue = $property.Value
        if ($rawValue -is [System.Array]) {
            $values = @($rawValue | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($values.Count -gt 0) {
                return $values
            }
        }

        $single = [string]$rawValue
        if (-not [string]::IsNullOrWhiteSpace($single)) {
            $split = @($single -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($split.Count -gt 0) {
                return $split
            }
        }
    }

    return @()
}

function Resolve-DesiredCandidate {
    param(
        [int]$RequestedLevel,
        [string[]]$CandidateValues
    )

    if ($RequestedLevel -le 0) {
        $offMatch = $CandidateValues | Where-Object { $_ -match '^(off|disabled|0)$' } | Select-Object -First 1
        if ($offMatch) {
            return $offMatch
        }
    }

    $preferred = @(
        'Never',
        'Always On',
        'Always',
        'On',
        'Enabled',
        '5 Minutes',
        '10 Minutes',
        '15 Minutes',
        '30 Seconds',
        '60 Seconds',
        '1 Minute'
    )

    foreach ($pattern in $preferred) {
        $match = $CandidateValues | Where-Object { $_ -match [regex]::Escape($pattern) } | Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    if ($CandidateValues.Count -gt 0) {
        return $CandidateValues[0]
    }

    if ($RequestedLevel -le 0) {
        return 'Disabled'
    }

    return 'Never'
}

function Invoke-HpCmslSettingAttempt {
    param([int]$TargetLevel)

    if (-not (Get-Command Get-HPBIOSSettingsList -ErrorAction SilentlyContinue)) {
        Write-BacklightLog 'HP CMSL cmdlets not found in this session'
        return $false
    }

    $settings = @(Get-HPBIOSSettingsList)
    if ($settings.Count -eq 0) {
        Write-BacklightLog 'HP CMSL returned an empty BIOS settings list'
        return $false
    }

    $matched = @()
    foreach ($setting in $settings) {
        $name = Get-ObjectStringProperty -Object $setting -PropertyNames @('Name', 'SettingName', 'Attribute')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if ($name -match '(?i)keyboard' -and $name -match '(?i)backlight') {
            $matched += [pscustomobject]@{
                Name = $name
                Values = @(Get-ObjectStringArrayProperty -Object $setting -PropertyNames @('PossibleValues', 'Values', 'ValueList', 'Options'))
            }
        }
    }

    if ($matched.Count -eq 0) {
        Write-BacklightLog 'HP CMSL found no BIOS setting matching keyboard+backlight'
        return $false
    }

    foreach ($item in $matched) {
        $desiredValue = Resolve-DesiredCandidate -RequestedLevel $TargetLevel -CandidateValues $item.Values
        try {
            Set-HPBIOSSettingValue -Name $item.Name -Value $desiredValue -ErrorAction Stop | Out-Null
            Write-BacklightLog "hp-cmsl set setting='$($item.Name)' value='$desiredValue'"
            return $true
        } catch {
            Write-BacklightLog "hp-cmsl failed setting='$($item.Name)' value='$desiredValue' error=$($_.Exception.Message)"
        }
    }

    return $false
}

function Invoke-HpWmiFallbackAttempt {
    param([int]$TargetLevel)

    try {
        $enumItems = @(Get-CimInstance -Namespace 'root\HP\InstrumentedBIOS' -ClassName 'HP_BIOSEnumeration' -ErrorAction Stop)
    } catch {
        Write-BacklightLog "hp-wmi enumeration unavailable error=$($_.Exception.Message)"
        return $false
    }

    $targets = @($enumItems | Where-Object { $_.Name -match '(?i)keyboard' -and $_.Name -match '(?i)backlight' })
    if ($targets.Count -eq 0) {
        Write-BacklightLog 'hp-wmi found no BIOS enumeration entry matching keyboard+backlight'
        return $false
    }

    $iface = Get-CimInstance -Namespace 'root\HP\InstrumentedBIOS' -ClassName 'HP_BIOSSettingInterface' -ErrorAction SilentlyContinue
    if ($null -eq $iface) {
        Write-BacklightLog 'hp-wmi HP_BIOSSettingInterface not available'
        return $false
    }

    foreach ($target in $targets) {
        $candidateValues = @($target.PossibleValues -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $desiredValue = Resolve-DesiredCandidate -RequestedLevel $TargetLevel -CandidateValues $candidateValues
        try {
            $result = Invoke-CimMethod -InputObject $iface -MethodName SetBIOSSetting -Arguments @{ Name = [string]$target.Name; Value = $desiredValue; Password = '' } -ErrorAction Stop
            $returnCode = if ($null -ne $result -and $result.PSObject.Properties['Return']) { $result.Return } else { 'unknown' }
            Write-BacklightLog "hp-wmi set setting='$($target.Name)' value='$desiredValue' return=$returnCode"
            if ($returnCode -eq 0 -or $returnCode -eq '0' -or $returnCode -eq 'unknown') {
                return $true
            }
        } catch {
            Write-BacklightLog "hp-wmi failed setting='$($target.Name)' value='$desiredValue' error=$($_.Exception.Message)"
        }
    }

    return $false
}

function Invoke-HpBacklightAction {
    param([int]$TargetLevel)

    Write-BacklightLog "start level=$TargetLevel ensureMonitor=$EnsureMonitor"

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    $model = (Get-CimInstance Win32_ComputerSystem).Model
    Write-BacklightLog "system manufacturer='$manufacturer' model='$model'"

    if (-not ($manufacturer -match '(?i)HP|Hewlett-Packard')) {
        Write-BacklightLog 'system is not HP; skipping HP routine'
        return 1
    }

    if (Invoke-HpCmslSettingAttempt -TargetLevel $TargetLevel) {
        Write-BacklightLog 'success via hp-cmsl'
        return 0
    }

    if (Invoke-HpWmiFallbackAttempt -TargetLevel $TargetLevel) {
        Write-BacklightLog 'success via hp-wmi-fallback'
        return 0
    }

    Write-BacklightLog 'failed: no HP keyboard backlight setting was changed; check BIOS lock/password and CMSL install'
    return 1
}

exit (Invoke-HpBacklightAction -TargetLevel $Level)
