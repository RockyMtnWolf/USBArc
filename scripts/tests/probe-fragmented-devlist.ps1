param(
  [Parameter(Mandatory = $true)]
  [string]$ServerHost,
  [int]$Port = 3240
)

$client = [System.Net.Sockets.TcpClient]::new()
$client.ReceiveTimeout = 4000
$client.SendTimeout = 4000
try {
  $client.Connect($ServerHost, $Port)
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

  $expected = [byte[]](0x01, 0x11, 0x00, 0x05, 0, 0, 0, 0, 0, 0, 0, 0)
  if ($received -ne $expected.Length) {
    throw "Expected a 12-byte empty DEVLIST reply, received $received byte(s)."
  }
  for ($index = 0; $index -lt $expected.Length; $index++) {
    if ($reply[$index] -ne $expected[$index]) {
      throw "Unexpected DEVLIST reply byte at offset $index."
    }
  }
  'PASS: server stayed responsive across a delayed, fragmented DEVLIST request and returned an empty device list.'
} finally {
  $client.Dispose()
}
