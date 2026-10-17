param([int]$BackendPort = 8001, [int]$FrontendPort = 3000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root '.data'
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$python = Join-Path $backend '.venv\Scripts\python.exe'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$env:HF_HOME = Join-Path $data 'huggingface'
$systemProxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($systemProxy.ProxyEnable -eq 1 -and $systemProxy.ProxyServer -match '^[^=;]+:\d+$') {
    $env:HTTPS_PROXY = "http://$($systemProxy.ProxyServer)"
    $env:HTTP_PROXY = $env:HTTPS_PROXY
    $env:NO_PROXY = '127.0.0.1,localhost,::1'
}
Push-Location $root
try {
    & docker compose up -d postgres etcd minio milvus
    if ($LASTEXITCODE -ne 0) { throw 'Docker services failed. Start Docker Desktop and retry.' }
    $databaseReady = $false
    for ($i = 0; $i -lt 60; $i++) {
        & docker compose exec -T postgres pg_isready -U devflow -d devflow 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $databaseReady = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $databaseReady) { throw 'PostgreSQL did not become ready.' }
    if (-not (Get-NetTCPConnection -LocalPort $BackendPort -State Listen -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','app.main:app','--host','127.0.0.1','--port',"$BackendPort") -WorkingDirectory $backend -WindowStyle Hidden -RedirectStandardOutput (Join-Path $data 'backend.out.log') -RedirectStandardError (Join-Path $data 'backend.err.log') | Out-Null
    }
    $env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$BackendPort"
    if (-not (Get-NetTCPConnection -LocalPort $FrontendPort -State Listen -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'npm.cmd' -ArgumentList @('run','dev','--','--hostname','127.0.0.1','--port',"$FrontendPort") -WorkingDirectory $frontend -WindowStyle Hidden -RedirectStandardOutput (Join-Path $data 'frontend.out.log') -RedirectStandardError (Join-Path $data 'frontend.err.log') | Out-Null
    }
    foreach ($url in @("http://127.0.0.1:$BackendPort/health", "http://127.0.0.1:$FrontendPort")) {
        $ready = $false
        for ($i = 0; $i -lt 90; $i++) {
            try {
                if ($url.EndsWith('/health')) {
                    $health = Invoke-RestMethod -Uri $url -TimeoutSec 3
                    if ($health.status -ne 'ok' -or $health.app -ne 'DevFlow AI') { throw 'Unexpected service on backend port.' }
                } else { Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3 | Out-Null }
                $ready = $true; break
            }
            catch { Start-Sleep -Seconds 1 }
        }
        if (-not $ready) { throw "Service did not become ready: $url. See $data logs." }
    }
    Write-Host "Frontend: http://127.0.0.1:$FrontendPort"
    Write-Host "API docs: http://127.0.0.1:$BackendPort/docs"
}
finally { Pop-Location }
