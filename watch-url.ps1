[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$RunOnce,

    [switch]$SendTestEmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:RunFailed = $false

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[$([DateTime]::UtcNow.ToString('u'))] $Message"
}

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $PathValue))
}

function ConvertTo-Hashtable {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }

    $result = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $property.Value

        if ($value -is [System.Management.Automation.PSCustomObject]) {
            $result[$property.Name] = ConvertTo-Hashtable -InputObject $value
            continue
        }

        if ($value -is [System.Array]) {
            $items = @()
            foreach ($item in $value) {
                if ($item -is [System.Management.Automation.PSCustomObject]) {
                    $items += ,(ConvertTo-Hashtable -InputObject $item)
                }
                else {
                    $items += ,$item
                }
            }

            $result[$property.Name] = $items
            continue
        }

        $result[$property.Name] = $value
    }

    return $result
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $directory = Split-Path -Path $FilePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Get-StringHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Normalize-Content {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [bool]$IgnoreWhitespace = $true
    )

    $normalized = $Value.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($IgnoreWhitespace) {
        $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, "\s+", " ").Trim()
    }

    return $normalized
}

function Get-ResolvedStringValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [string]$EnvPropertyName,

        [string]$DefaultEnvName,

        [string]$DefaultValue = "",

        [switch]$Required
    )

    $directValue = [string](Get-ConfigValue -Object $Object -PropertyName $PropertyName -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($directValue)) {
        return $directValue
    }

    $envNameFromConfig = ""
    if (-not [string]::IsNullOrWhiteSpace($EnvPropertyName)) {
        $envNameFromConfig = [string](Get-ConfigValue -Object $Object -PropertyName $EnvPropertyName -DefaultValue "")
    }

    if (-not [string]::IsNullOrWhiteSpace($envNameFromConfig)) {
        $envValue = [Environment]::GetEnvironmentVariable($envNameFromConfig)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            return $envValue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultEnvName)) {
        $defaultEnvValue = [Environment]::GetEnvironmentVariable($DefaultEnvName)
        if (-not [string]::IsNullOrWhiteSpace($defaultEnvValue)) {
            return $defaultEnvValue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        return $DefaultValue
    }

    if ($Required) {
        if (-not [string]::IsNullOrWhiteSpace($envNameFromConfig)) {
            throw "La cle '$PropertyName' est absente et la variable d'environnement '$envNameFromConfig' est vide."
        }

        if (-not [string]::IsNullOrWhiteSpace($DefaultEnvName)) {
            throw "La cle '$PropertyName' est absente et la variable d'environnement '$DefaultEnvName' est vide."
        }

        throw "La cle '$PropertyName' est obligatoire."
    }

    return ""
}

function Get-ResolvedIntValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [int]$DefaultValue
    )

    $value = Get-ConfigValue -Object $Object -PropertyName $PropertyName
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return $DefaultValue
    }

    return [int]$value
}

function Get-ResolvedBoolValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [bool]$DefaultValue
    )

    $value = Get-ConfigValue -Object $Object -PropertyName $PropertyName
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return $DefaultValue
    }

    return [bool]$value
}

function Get-RecipientList {
    param(
        [Parameter(Mandatory = $true)]
        $SmtpConfig
    )

    $directRecipients = Get-ConfigValue -Object $SmtpConfig -PropertyName "to"
    $recipientItems = @()

    if ($null -ne $directRecipients) {
        if ($directRecipients -is [System.Array] -or ($directRecipients -is [System.Collections.IEnumerable] -and $directRecipients -isnot [string])) {
            foreach ($item in $directRecipients) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                    $recipientItems += [string]$item
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$directRecipients)) {
            $recipientItems += [string]$directRecipients
        }
    }

    if ($recipientItems.Count -gt 0) {
        return $recipientItems
    }

    $recipientsRaw = Get-ResolvedStringValue -Object $SmtpConfig -PropertyName "to" -EnvPropertyName "toEnv" -DefaultEnvName "URL_WATCH_SMTP_TO" -Required
    return $recipientsRaw.Split(@(",", ";", "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Get-SmtpPassword {
    param(
        [Parameter(Mandatory = $true)]
        $SmtpConfig
    )

    $password = [string](Get-ConfigValue -Object $SmtpConfig -PropertyName "password" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($password)) {
        return $password
    }

    $passwordEnv = [string](Get-ConfigValue -Object $SmtpConfig -PropertyName "passwordEnv" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($passwordEnv)) {
        $envValue = [Environment]::GetEnvironmentVariable($passwordEnv)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            return $envValue
        }

        throw "La variable d'environnement '$passwordEnv' est introuvable ou vide."
    }

    $defaultPassword = [Environment]::GetEnvironmentVariable("URL_WATCH_SMTP_PASSWORD")
    if (-not [string]::IsNullOrWhiteSpace($defaultPassword)) {
        return $defaultPassword
    }

    throw "Aucun mot de passe SMTP n'est configure."
}

function Send-NotificationEmail {
    param(
        [Parameter(Mandatory = $true)]
        $SmtpConfig,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $from = Get-ResolvedStringValue -Object $SmtpConfig -PropertyName "from" -EnvPropertyName "fromEnv" -DefaultEnvName "URL_WATCH_SMTP_FROM" -Required
    $toList = Get-RecipientList -SmtpConfig $SmtpConfig
    $hostName = Get-ResolvedStringValue -Object $SmtpConfig -PropertyName "host" -EnvPropertyName "hostEnv" -DefaultEnvName "URL_WATCH_SMTP_HOST" -DefaultValue "smtp.gmail.com" -Required
    $port = Get-ResolvedIntValue -Object $SmtpConfig -PropertyName "port" -DefaultValue 587
    $username = Get-ResolvedStringValue -Object $SmtpConfig -PropertyName "username" -EnvPropertyName "usernameEnv" -DefaultEnvName "URL_WATCH_SMTP_USERNAME"
    $useSsl = Get-ResolvedBoolValue -Object $SmtpConfig -PropertyName "useSsl" -DefaultValue $true

    if ($toList.Count -eq 0) {
        throw "smtp.to doit contenir au moins un destinataire."
    }

    $message = New-Object System.Net.Mail.MailMessage
    $message.From = $from
    foreach ($recipient in $toList) {
        [void]$message.To.Add($recipient)
    }

    $message.Subject = $Subject
    $message.Body = $Body
    $message.IsBodyHtml = $false

    $client = New-Object System.Net.Mail.SmtpClient($hostName, $port)
    $client.EnableSsl = $useSsl

    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $password = Get-SmtpPassword -SmtpConfig $SmtpConfig
        $client.Credentials = New-Object System.Net.NetworkCredential($username, $password)
    }

    try {
        $client.Send($message)
    }
    finally {
        $message.Dispose()
        $client.Dispose()
    }
}

function Get-HttpHeaders {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $headersObject = Get-ConfigValue -Object $Config -PropertyName "headers"
    if ($null -eq $headersObject) {
        return $null
    }

    return ConvertTo-Hashtable -InputObject $headersObject
}

function Invoke-TrackedWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $timeoutSeconds = Get-ResolvedIntValue -Object $Config -PropertyName "requestTimeoutSeconds" -DefaultValue 30
    $retryCount = Get-ResolvedIntValue -Object $Config -PropertyName "httpRetryCount" -DefaultValue 3
    $retryDelaySeconds = Get-ResolvedIntValue -Object $Config -PropertyName "httpRetryDelaySeconds" -DefaultValue 3
    $headers = Get-HttpHeaders -Config $Config

    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
        $requestParams = @{
            Uri         = $Uri
            TimeoutSec  = $timeoutSeconds
            ErrorAction = "Stop"
        }

        if ($null -ne $headers -and $headers.Count -gt 0) {
            $requestParams["Headers"] = $headers
        }

        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $requestParams["UseBasicParsing"] = $true
        }

        try {
            Write-Log "HTTP tentative $attempt/$retryCount"
            $response = Invoke-WebRequest @requestParams

            if ($null -eq $response) {
                throw "La reponse HTTP est vide."
            }

            $content = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($content)) {
                throw "Le contenu HTTP est vide."
            }

            return $response
        }
        catch {
            $message = $_.Exception.Message
            if ($attempt -ge $retryCount) {
                throw "Echec HTTP apres $retryCount tentative(s): $message"
            }

            Write-Warning "Tentative HTTP $attempt echouee: $message"
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    throw "Echec HTTP inattendu."
}

function Get-WatchedPayload {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $url = Get-ResolvedStringValue -Object $Config -PropertyName "url" -EnvPropertyName "urlEnv" -DefaultEnvName "URL_WATCH_URL" -Required
    $response = Invoke-TrackedWebRequest -Config $Config -Uri $url
    $content = [string]$response.Content

    $matchPattern = Get-ConfigValue -Object $Config -PropertyName "matchPattern"
    if (-not [string]::IsNullOrWhiteSpace([string]$matchPattern)) {
        $matches = [System.Text.RegularExpressions.Regex]::Matches(
            $content,
            [string]$matchPattern,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        if ($matches.Count -eq 0) {
            throw "Le motif regex configure n'a rien trouve dans la reponse."
        }

        $parts = foreach ($match in $matches) { $match.Value }
        $content = ($parts -join "`n")
    }

    $ignoreWhitespace = Get-ResolvedBoolValue -Object $Config -PropertyName "ignoreWhitespace" -DefaultValue $true
    $normalized = Normalize-Content -Value $content -IgnoreWhitespace $ignoreWhitespace

    return [PSCustomObject]@{
        Url              = $url
        StatusCode       = [int]$response.StatusCode
        RawContentLength = $response.RawContentLength
        Payload          = $normalized
        PayloadLength    = $normalized.Length
        Hash             = Get-StringHash -Value $normalized
        CheckedAtUtc     = [DateTime]::UtcNow.ToString("o")
    }
}

function Convert-HtmlToText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $text = $Html
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, "<br\s*/?>", "`n", "IgnoreCase")
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, "</(p|div|blockquote|li|ul|ol|article|section|h[1-6])>", "`n", "IgnoreCase")
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, "<[^>]+>", " ")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text.Replace([char]0xA0, " ")
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, "[ \t]+", " ")
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, "(\n\s*){2,}", "`n")
    return $text.Trim()
}

function Get-XenForoLatestPageUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html,

        [Parameter(Mandatory = $true)]
        [string]$CurrentUrl
    )

    $currentUri = [System.Uri]$CurrentUrl
    $pageTemplateMatch = [System.Text.RegularExpressions.Regex]::Match(
        $Html,
        'data-page-url="(?<template>[^"]*page-%page%[^"]*)"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $pageNumbers = [System.Text.RegularExpressions.Regex]::Matches($Html, 'page-(?<page>\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { [int]$_.Groups["page"].Value }
    $pageJumpMaxMatches = [System.Text.RegularExpressions.Regex]::Matches($Html, 'max="(?<page>\d+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { [int]$_.Groups["page"].Value }

    $allPages = @()
    if ($pageNumbers) { $allPages += $pageNumbers }
    if ($pageJumpMaxMatches) { $allPages += $pageJumpMaxMatches }

    $lastPage = 1
    if ($allPages.Count -gt 0) {
        $lastPage = ($allPages | Measure-Object -Maximum).Maximum
    }

    if ($lastPage -le 1) {
        return [PSCustomObject]@{
            LastPage  = 1
            LatestUrl = $CurrentUrl
        }
    }

    if ($pageTemplateMatch.Success) {
        $template = [System.Net.WebUtility]::HtmlDecode($pageTemplateMatch.Groups["template"].Value)
        $relativeUrl = $template.Replace("%page%", [string]$lastPage)
        $latestUri = [System.Uri]::new($currentUri, $relativeUrl)
        return [PSCustomObject]@{
            LastPage  = $lastPage
            LatestUrl = $latestUri.AbsoluteUri
        }
    }

    $fallbackUrl = [System.Text.RegularExpressions.Regex]::Replace($CurrentUrl, '/page-\d+$', "")
    $fallbackUrl = $fallbackUrl.TrimEnd("/") + "/page-$lastPage"
    return [PSCustomObject]@{
        LastPage  = $lastPage
        LatestUrl = $fallbackUrl
    }
}

function Get-XenForoThreadPayload {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $url = Get-ResolvedStringValue -Object $Config -PropertyName "url" -EnvPropertyName "urlEnv" -DefaultEnvName "URL_WATCH_URL" -Required
    $initialResponse = Invoke-TrackedWebRequest -Config $Config -Uri $url
    $latestPageInfo = Get-XenForoLatestPageUrl -Html ([string]$initialResponse.Content) -CurrentUrl ([string]$initialResponse.BaseResponse.ResponseUri.AbsoluteUri)
    $latestUrl = $latestPageInfo.LatestUrl
    $lastPage = $latestPageInfo.LastPage
    $response = $initialResponse

    if ($latestUrl -ne $initialResponse.BaseResponse.ResponseUri.AbsoluteUri) {
        $response = Invoke-TrackedWebRequest -Config $Config -Uri $latestUrl
    }

    $html = [string]$response.Content
    $postPattern = '<article\b[^>]*class="[^"]*\bmessage--post\b[^"]*"[^>]*>[\s\S]*?<footer class="message-footer">[\s\S]*?</footer>[\s\S]*?</article>'
    $postMatches = [System.Text.RegularExpressions.Regex]::Matches(
        $html,
        $postPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($postMatches.Count -eq 0) {
        throw "Aucun message n'a pu etre extrait depuis la page du thread."
    }

    $posts = New-Object System.Collections.Generic.List[string]
    foreach ($match in $postMatches) {
        $postHtml = $match.Value
        $postIdMatch = [System.Text.RegularExpressions.Regex]::Match(
            $postHtml,
            'data-content="post-(?<id>\d+)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $authorMatch = [System.Text.RegularExpressions.Regex]::Match(
            $postHtml,
            'data-author="(?<author>[^"]+)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $postIdMatch.Success) {
            continue
        }

        $postId = $postIdMatch.Groups["id"].Value
        $author = if ($authorMatch.Success) { [System.Net.WebUtility]::HtmlDecode($authorMatch.Groups["author"].Value) } else { "" }

        $dateMatch = [System.Text.RegularExpressions.Regex]::Match(
            $postHtml,
            '<time\b[^>]*datetime="(?<dt>[^"]+)"',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $textMatch = [System.Text.RegularExpressions.Regex]::Match(
            $postHtml,
            '<div itemprop="text">(?<text>[\s\S]*?)</div>\s*<div class="js-selectToQuoteEnd">',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $textMatch.Success) {
            continue
        }

        $text = Convert-HtmlToText -Html $textMatch.Groups["text"].Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $postDate = if ($dateMatch.Success) { $dateMatch.Groups["dt"].Value } else { "" }
        $posts.Add("post=$postId`nauthor=$author`ndatetime=$postDate`ntext=$text")
    }

    if ($posts.Count -eq 0) {
        throw "Les blocs de messages ont ete trouves mais aucun contenu textuel exploitable n'a ete extrait."
    }

    $titleMatch = [System.Text.RegularExpressions.Regex]::Match(
        $html,
        '<h1 class="p-title-value">(?<title>[\s\S]*?)</h1>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $threadTitle = if ($titleMatch.Success) { Convert-HtmlToText -Html $titleMatch.Groups["title"].Value } else { "" }

    $payload = ($posts -join "`n---`n")

    return [PSCustomObject]@{
        Url              = $url
        StatusCode       = [int]$response.StatusCode
        RawContentLength = $response.RawContentLength
        Payload          = $payload
        PayloadLength    = $payload.Length
        Hash             = Get-StringHash -Value $payload
        CheckedAtUtc     = [DateTime]::UtcNow.ToString("o")
        EffectiveUrl     = $latestUrl
        LastPage         = $lastPage
        PostCount        = $posts.Count
        ThreadTitle      = $threadTitle
    }
}

function Load-State {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [PSCustomObject]@{}
    }

    $raw = Get-Content -LiteralPath $StatePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{}
    }

    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        throw "Le fichier d'etat '$StatePath' n'est pas un JSON valide."
    }
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        $State
    )

    Ensure-Directory -FilePath $StatePath
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatePath -Encoding utf8
}

function Compare-SnapshotToState {
    param(
        [Parameter(Mandatory = $true)]
        $State,

        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $previousHash = [string](Get-ConfigValue -Object $State -PropertyName "lastHash" -DefaultValue "")
    $isBaseline = [string]::IsNullOrWhiteSpace($previousHash)
    $changes = New-Object System.Collections.Generic.List[string]

    $previousPostCount = Get-ConfigValue -Object $State -PropertyName "lastPostCount"
    $previousCharacterCount = Get-ConfigValue -Object $State -PropertyName "lastPayloadLength"

    if (-not $isBaseline) {
        if ($Snapshot.PSObject.Properties["PostCount"] -and $null -ne $previousPostCount -and ([int]$previousPostCount -ne [int]$Snapshot.PostCount)) {
            $changes.Add("nombre de messages")
        }

        if ($null -ne $previousCharacterCount -and ([int]$previousCharacterCount -ne [int]$Snapshot.PayloadLength)) {
            $changes.Add("nombre de caracteres")
        }

        if ($previousHash -ne $Snapshot.Hash) {
            $changes.Add("contenu")
        }
    }

    return [PSCustomObject]@{
        IsBaseline            = $isBaseline
        HasChanged            = ($changes.Count -gt 0)
        ChangeReasons         = $changes
        PreviousHash          = $previousHash
        PreviousPostCount     = $previousPostCount
        PreviousCharacterCount = $previousCharacterCount
    }
}

function Build-ChangeEmailBody {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        $Comparison,

        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $name = Get-ConfigValue -Object $Config -PropertyName "name" -DefaultValue "Surveillance URL"
    $newPreview = $Snapshot.Payload
    if ($newPreview.Length -gt 800) {
        $newPreview = $newPreview.Substring(0, 800) + "..."
    }

    $reasonText = if ($Comparison.ChangeReasons.Count -gt 0) { $Comparison.ChangeReasons -join ", " } else { "inconnue" }

    return @"
Une modification a ete detectee.

Nom: $name
Date UTC: $($Snapshot.CheckedAtUtc)
URL surveillee: $($Snapshot.Url)
URL observee: $(if ($Snapshot.PSObject.Properties["EffectiveUrl"]) { $Snapshot.EffectiveUrl } else { $Snapshot.Url })
Raisons: $reasonText
Ancien nombre de messages: $(if ($null -ne $Comparison.PreviousPostCount) { $Comparison.PreviousPostCount } else { "n/a" })
Nouveau nombre de messages: $(if ($Snapshot.PSObject.Properties["PostCount"]) { $Snapshot.PostCount } else { "n/a" })
Ancien nombre de caracteres: $(if ($null -ne $Comparison.PreviousCharacterCount) { $Comparison.PreviousCharacterCount } else { "n/a" })
Nouveau nombre de caracteres: $($Snapshot.PayloadLength)
Ancien hash: $(if (-not [string]::IsNullOrWhiteSpace($Comparison.PreviousHash)) { $Comparison.PreviousHash } else { "n/a" })
Nouveau hash: $($Snapshot.Hash)
HTTP: $($Snapshot.StatusCode)

Apercu du contenu surveille:
$newPreview
"@
}

function Build-ErrorEmailBody {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    $name = Get-ConfigValue -Object $Config -PropertyName "name" -DefaultValue "Surveillance URL"
    $url = Get-ResolvedStringValue -Object $Config -PropertyName "url" -EnvPropertyName "urlEnv" -DefaultEnvName "URL_WATCH_URL" -Required

    return @"
Le bot de surveillance a rencontre une erreur.

Nom: $name
URL: $url
Date UTC: $([DateTime]::UtcNow.ToString("o"))

Erreur:
$ErrorMessage
"@
}

$resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Fichier de configuration introuvable: $resolvedConfigPath"
}

$configDirectory = Split-Path -Path $resolvedConfigPath -Parent
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$statePath = Resolve-AbsolutePath -PathValue (Get-ConfigValue -Object $config -PropertyName "stateFile" -DefaultValue ".\state\state.json") -BaseDirectory $configDirectory
$pollDelay = Get-ResolvedIntValue -Object $config -PropertyName "checkIntervalSeconds" -DefaultValue 300
$notifyOnErrors = Get-ResolvedBoolValue -Object $config -PropertyName "notifyOnErrors" -DefaultValue $true
$name = Get-ConfigValue -Object $config -PropertyName "name" -DefaultValue "Surveillance URL"
$mode = [string](Get-ConfigValue -Object $config -PropertyName "mode" -DefaultValue "raw")

Write-Log "Demarrage du watcher '$name' en mode '$mode'."

if ($SendTestEmail) {
    $subject = "[URL Watcher] Test e-mail - $name"
    $body = @"
Ceci est un e-mail de test.

Nom: $name
Mode: $mode
URL configuree: $(Get-ResolvedStringValue -Object $config -PropertyName "url" -EnvPropertyName "urlEnv" -DefaultEnvName "URL_WATCH_URL" -Required)
Date UTC: $([DateTime]::UtcNow.ToString("o"))

Si tu recois ce message, la configuration SMTP fonctionne.
"@

    Send-NotificationEmail -SmtpConfig $config.smtp -Subject $subject -Body $body
    Write-Log "E-mail de test envoye."
    exit 0
}

while ($true) {
    $state = Load-State -StatePath $statePath

    try {
        switch ($mode.ToLowerInvariant()) {
            "xenforo-thread" {
                $snapshot = Get-XenForoThreadPayload -Config $config
            }
            default {
                $snapshot = Get-WatchedPayload -Config $config
            }
        }

        if ($snapshot.PayloadLength -le 0) {
            throw "Le contenu observe est vide apres normalisation."
        }

        $comparison = Compare-SnapshotToState -State $state -Snapshot $snapshot
        Write-Log "Mesures actuelles: messages=$(if ($snapshot.PSObject.Properties['PostCount']) { $snapshot.PostCount } else { 'n/a' }), caracteres=$($snapshot.PayloadLength), page=$(if ($snapshot.PSObject.Properties['LastPage']) { $snapshot.LastPage } else { 'n/a' })."

        if ($comparison.HasChanged) {
            $subject = "[URL Watcher] Changement detecte - $name"
            $body = Build-ChangeEmailBody -Config $config -Comparison $comparison -Snapshot $snapshot
            Send-NotificationEmail -SmtpConfig $config.smtp -Subject $subject -Body $body
            Write-Log "Changement detecte. E-mail envoye."
        }
        elseif ($comparison.IsBaseline) {
            Write-Log "Premier lancement: baseline enregistree sans envoyer d'e-mail."
        }
        else {
            Write-Log "Aucun changement detecte."
        }

        # Le fichier d'etat ne contient aucune valeur sensible.
        $newState = [PSCustomObject]@{
            version              = 1
            lastStatus           = "ok"
            lastHash             = $snapshot.Hash
            lastPayloadLength    = $snapshot.PayloadLength
            lastStatusCode       = $snapshot.StatusCode
            lastPage             = if ($snapshot.PSObject.Properties["LastPage"]) { $snapshot.LastPage } else { $null }
            lastPostCount        = if ($snapshot.PSObject.Properties["PostCount"]) { $snapshot.PostCount } else { $null }
            baselineCapturedAt   = if ($comparison.IsBaseline) { $snapshot.CheckedAtUtc } else { (Get-ConfigValue -Object $state -PropertyName "baselineCapturedAt" -DefaultValue $snapshot.CheckedAtUtc) }
            lastChangeAtUtc      = if ($comparison.HasChanged) { $snapshot.CheckedAtUtc } else { (Get-ConfigValue -Object $state -PropertyName "lastChangeAtUtc") }
            lastErrorFingerprint = $null
            lastErrorAtUtc       = $null
        }

        Save-State -StatePath $statePath -State $newState
        Write-Log "Etat sauvegarde dans '$statePath'."
    }
    catch {
        $script:RunFailed = $true
        $errorMessage = $_.Exception.Message
        Write-Warning "Erreur de surveillance: $errorMessage"

        $errorFingerprint = Get-StringHash -Value $errorMessage
        $lastErrorFingerprint = Get-ConfigValue -Object $state -PropertyName "lastErrorFingerprint"
        $shouldNotifyError = $notifyOnErrors -and ($errorFingerprint -ne $lastErrorFingerprint)

        if ($shouldNotifyError) {
            $subject = "[URL Watcher] Erreur - $name"
            $body = Build-ErrorEmailBody -Config $config -ErrorMessage $errorMessage

            try {
                Send-NotificationEmail -SmtpConfig $config.smtp -Subject $subject -Body $body
                Write-Log "Erreur detectee. E-mail envoye."
            }
            catch {
                Write-Warning "Impossible d'envoyer l'e-mail d'erreur: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "Erreur repetee. Notification non renvoyee."
        }

        $failedState = [PSCustomObject]@{
            version              = 1
            lastStatus           = "error"
            lastHash             = Get-ConfigValue -Object $state -PropertyName "lastHash"
            lastPayloadLength    = Get-ConfigValue -Object $state -PropertyName "lastPayloadLength"
            lastStatusCode       = Get-ConfigValue -Object $state -PropertyName "lastStatusCode"
            lastPage             = Get-ConfigValue -Object $state -PropertyName "lastPage"
            lastPostCount        = Get-ConfigValue -Object $state -PropertyName "lastPostCount"
            baselineCapturedAt   = Get-ConfigValue -Object $state -PropertyName "baselineCapturedAt"
            lastChangeAtUtc      = Get-ConfigValue -Object $state -PropertyName "lastChangeAtUtc"
            lastErrorFingerprint = $errorFingerprint
            lastErrorAtUtc       = [DateTime]::UtcNow.ToString("o")
        }

        Save-State -StatePath $statePath -State $failedState
        Write-Log "Etat d'erreur sauvegarde dans '$statePath'."
    }

    if ($RunOnce) {
        break
    }

    Start-Sleep -Seconds $pollDelay
}

if ($RunOnce -and $script:RunFailed) {
    exit 1
}
