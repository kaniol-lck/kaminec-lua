param(
    [string]$HostName = "127.0.0.1",
    [int]$Port = 25575,
    [string]$Password = "",
    [string]$Command = "list"
)

$ErrorActionPreference = "Stop"
$client = New-Object System.Net.Sockets.TcpClient($HostName, $Port)
$stream = $client.GetStream()

function Write-Packet([int]$RequestId, [int]$Type, [string]$Body) {
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $length = 4 + 4 + $bodyBytes.Length + 2
    $buffer = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($buffer)
    $writer.Write([int]$length)
    $writer.Write([int]$RequestId)
    $writer.Write([int]$Type)
    $writer.Write($bodyBytes)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Flush()
    $bytes = $buffer.ToArray()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Read-Packet {
    $lenBytes = New-Object byte[] 4
    $read = 0
    while ($read -lt 4) {
        $n = $stream.Read($lenBytes, $read, 4 - $read)
        if ($n -le 0) { throw "connection closed" }
        $read += $n
    }
    $length = [BitConverter]::ToInt32($lenBytes, 0)
    $data = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
        $n = $stream.Read($data, $read, $length - $read)
        if ($n -le 0) { throw "connection closed" }
        $read += $n
    }
    $requestId = [BitConverter]::ToInt32($data, 0)
    $type = [BitConverter]::ToInt32($data, 4)
    $body = [System.Text.Encoding]::UTF8.GetString($data, 8, $length - 10)
    return @{ Id = $requestId; Type = $type; Body = $body }
}

try {
    Write-Packet 1 3 $Password
    $auth = Read-Packet
    if ($auth.Id -eq -1) { throw "RCON authentication failed" }
    Write-Packet 2 2 $Command
    $response = Read-Packet
    Write-Output -NoEnumerate $response.Body
} finally {
    $stream.Close()
    $client.Close()
}
