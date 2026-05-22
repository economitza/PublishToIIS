param(
    [string]$Output = 'PublishToIIS.zip'
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $root
if (Test-Path $Output) { Remove-Item $Output -Force }
Compress-Archive -Path src,config,PublishToIIS.psd1 -DestinationPath $Output -Force
Pop-Location
Write-Host "Created $Output"
