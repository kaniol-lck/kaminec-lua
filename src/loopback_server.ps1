param(
    [int]$Port,
    [string]$OutFile,
    [int]$TimeoutMs = 180000
)

# Keep this script ASCII-only: Windows PowerShell 5.1 reads .ps1 files as ANSI
# when there is no BOM, so Chinese text lives in callback.html (read as UTF-8).
$ErrorActionPreference = "Stop"

try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Set-Content -Path $OutFile -Value ("ERROR " + $_.Exception.Message) -Encoding utf8
    exit 1
}

$task = $listener.AcceptTcpClientAsync()
if (-not $task.Wait($TimeoutMs)) {
    $listener.Stop()
    exit 2
}

$client = $task.Result
try {
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    $requestLine = $reader.ReadLine()
    while ($true) {
        $line = $reader.ReadLine()
        if ($line -eq $null -or $line -eq "") { break }
    }

    $path = "/"
    if ($requestLine) {
        $parts = $requestLine.Split(" ")
        if ($parts.Length -ge 2) { $path = $parts[1] }
    }
    Set-Content -Path $OutFile -Value $path -Encoding utf8

    $query = ""
    $q = $path.IndexOf("?")
    if ($q -ge 0) {
        $query = $path.Substring($q + 1)
        $path = $path.Substring(0, $q)
    }

    $params = @{}
    foreach ($pair in $query.Split("&")) {
        if (-not $pair) { continue }
        $i = $pair.IndexOf("=")
        if ($i -lt 0) {
            $k = $pair
            $v = ""
        } else {
            $k = $pair.Substring(0, $i)
            $v = $pair.Substring($i + 1)
        }
        $k = [System.Uri]::UnescapeDataString($k)
        $v = [System.Uri]::UnescapeDataString($v)
        if ($k) { $params[$k] = $v }
    }

    $state = "success"
    $detail = ""
    $detailClass = ""
    $errorCode = $params["error"]
    $errorDescription = $params["error_description"]

    if ($errorCode) {
        $state = "error"
        $parts = @()
        if ($errorCode) { $parts += $errorCode }
        if ($errorDescription) { $parts += $errorDescription }
        $detail = $parts -join ": "
        $detailClass = "show"
    } elseif (-not $params.ContainsKey("code")) {
        $state = "error"
        $detail = "callback did not contain an authorization code"
        $detailClass = "show"
    }

    Add-Type -AssemblyName System.Web
    $detail = [System.Web.HttpUtility]::HtmlEncode($detail)
    $templatePath = Join-Path $PSScriptRoot "callback.html"
    $template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
    $html = $template.Replace("{{STATE}}", $state).Replace("{{DETAIL}}", $detail).Replace("{{DETAIL_CLASS}}", $detailClass)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb, 0, $hb.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $client.Close()
} finally {
    $listener.Stop()
}
