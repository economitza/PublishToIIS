$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$modulePath = Join-Path $here 'src\PublishToIIS.psm1'

if (Test-Path $modulePath) {
    . $modulePath
}
else {
    throw "Module implementation not found at $modulePath. Run setup or restore the file."
}