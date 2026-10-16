param(
  [string]$Scope = 'UsbIpProtocolTest,UsbArcDevicePolicyTest,LocalNetworkAddressesTest'
)

$studioBin = [Environment]::GetEnvironmentVariable('DevEco Studio')
if ([string]::IsNullOrWhiteSpace($studioBin)) {
  throw 'DevEco Studio installation was not found in the DevEco Studio environment variable.'
}

$studioRoot = Split-Path -Parent $studioBin
$hvigorw = Join-Path $studioRoot 'tools\hvigor\bin\hvigorw.bat'
$sdkHome = Join-Path $studioRoot 'sdk'
if (-not (Test-Path -LiteralPath $hvigorw)) {
  throw "Local Test runner was not found at $hvigorw"
}
if (-not (Test-Path -LiteralPath $sdkHome)) {
  throw "DevEco SDK was not found at $sdkHome"
}

$previousSdkHome = $env:DEVECO_SDK_HOME
$env:DEVECO_SDK_HOME = $sdkHome
Push-Location (Join-Path $PSScriptRoot '..\..')
try {
  & $hvigorw test -p module=entry -p coverage=false "-p" "scope=$Scope"
  exit $LASTEXITCODE
} finally {
  Pop-Location
  $env:DEVECO_SDK_HOME = $previousSdkHome
}
