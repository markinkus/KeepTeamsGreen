# Pure rules shared by the desktop app and the regression checks.
function Test-LocalWindow {
    param([datetime]$Now, [string]$Days, [string]$From, [string]$To)
    $start = [TimeSpan]::ParseExact($From, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $end = [TimeSpan]::ParseExact($To, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $day = [int]$Now.DayOfWeek
    if ($start -gt $end -and $Now.TimeOfDay -lt $end) { $day = ([int]$Now.AddDays(-1).DayOfWeek) }
    $allowed = switch ($Days) {
        'Weekdays' { $day -ge 1 -and $day -le 5 }
        'Weekend' { $day -eq 0 -or $day -eq 6 }
        default { $true }
    }
    if (-not $allowed) { return $false }
    if ($start -eq $end) { return $true }
    if ($start -lt $end) { return ($Now.TimeOfDay -ge $start -and $Now.TimeOfDay -lt $end) }
    return ($Now.TimeOfDay -ge $start -or $Now.TimeOfDay -lt $end)
}

function Test-LocalTime {
    param([string]$Text)
    return $Text -match '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$'
}

function New-ContactRuntime {
    return @{
        State = 'Unknown'; Candidate = $null; CandidateAt = $null
        LastSeen = $null; LastAlert = $null; Detail = 'In attesa'
    }
}

function Update-ContactObservation {
    param($Runtime, [string]$State, [datetime]$Now, [string]$Rule, [int]$StaleSeconds, [int]$CooldownSeconds)
    if ($State -notin @('Available', 'Away', 'Busy', 'Dnd', 'Offline')) {
        $Runtime.Candidate = $null
        $Runtime.CandidateAt = $null
        $Runtime.State = 'Unknown'
        return $false
    }
    if ($null -ne $Runtime.LastSeen -and ($Now - $Runtime.LastSeen).TotalSeconds -gt $StaleSeconds) {
        $Runtime.State = 'Unknown'
        $Runtime.Candidate = $null
    }
    $Runtime.LastSeen = $Now
    if ($Runtime.State -eq $State) {
        $Runtime.Candidate = $null
        return $false
    }
    if ($Runtime.Candidate -ne $State) {
        $Runtime.Candidate = $State
        $Runtime.CandidateAt = $Now
        return $false
    }
    if (($Now - $Runtime.CandidateAt).TotalSeconds -lt 3) { return $false }
    $previous = $Runtime.State
    $Runtime.State = $State
    $Runtime.Candidate = $null
    $cooldownExpired = $null -eq $Runtime.LastAlert -or ($Now - $Runtime.LastAlert).TotalSeconds -ge $CooldownSeconds
    $matches = $Rule -eq 'Available' -and $State -eq 'Available'
    if ($Rule -eq 'Change') { $matches = $previous -ne 'Unknown' }
    if ($matches -and $cooldownExpired) {
        $Runtime.LastAlert = $Now
        return $true
    }
    return $false
}
