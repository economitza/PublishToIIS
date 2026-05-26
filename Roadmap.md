Hay que incluir:

```ps1
@"
{
  "branch":"$(git rev-parse --abbrev-ref HEAD)",
  "commit":"$(git rev-parse --short HEAD)",
  "buildDate":"$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
}
"@ | Out-File version.json -Encoding utf8
```

Mejor si es en función aparte. Actualmente está relativamente acoplado el código del "publicador".
Creo que seria mejor pasar el parametro de carpeta origen del repo y que lo cree allá.
