param(
  [Parameter(Mandatory = $true)]
  [string]$ServerHost,
  [int]$Port = 3240
)

$numericAddress = $null
$isNumeric = [System.Net.IPAddress]::TryParse($ServerHost, [ref]$numericAddress)
$client = if ($isNumeric) {
  [System.Net.Sockets.TcpClient]::new($numericAddress.AddressFamily)
} else {
  [System.Net.Sockets.TcpClient]::new()
}
$client.ReceiveTimeout = 4000
$client.SendTimeout = 4000
try {
  $connect = $client.ConnectAsync($ServerHost, $Port)
  if (-not $connect.Wait(5000)) { throw 'DEVLIST connection timed out.' }
  $connect.GetAwaiter().GetResult()
  $stream = $client.GetStream()
  $first = [byte[]](0x01, 0x11, 0x80)
  $rest = [byte[]](0x05, 0x00, 0x00, 0x00, 0x00)
  $stream.Write($first, 0, $first.Length)
  $stream.Flush()
  Start-Sleep -Milliseconds 250
  $stream.Write($rest, 0, $rest.Length)
  $stream.Flush()

  $reply = [byte[]]::new(12)
  $received = 0
  while ($received -lt $reply.Length) {
    $count = $stream.Read($reply, $received, $reply.Length - $received)
    if ($count -le 0) { break }
    $received += $count
  }

  $expectedHeader = [byte[]](0x01, 0x11, 0x00, 0x05, 0, 0, 0, 0)
  if ($received -ne $reply.Length) {
    throw "Expected a 12-byte DEVLIST header, received $received byte(s)."
  }
  for ($index = 0; $index -lt $expectedHeader.Length; $index++) {
    if ($reply[$index] -ne $expectedHeader[$index]) {
      throw "Unexpected DEVLIST reply byte at offset $index."
    }
  }
  $deviceCount = ([uint64]$reply[8] * 16777216) + ([uint64]$reply[9] * 65536) +
    ([uint64]$reply[10] * 256) + [uint64]$reply[11]
  "PASS: fragmented DEVLIST header from ${ServerHost}:$Port; devices=$deviceCount. Device records and USB I/O were not tested."
} finally {
  $client.Dispose()
}
