# Run from an ordinary PowerShell window. Does not submit orders or enable trading.
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\Administrator\Project'
$backend = Join-Path $root 'backend'
if (!(Test-Path (Join-Path $backend 'app\main.py'))) { throw "Backend missing: $backend" }
Set-Location $root
Write-Host 'Checking repository state...'
git status --short
if ($LASTEXITCODE -ne 0) { throw 'Git repository unavailable' }
$changes = @(git status --porcelain)
if ($changes.Count -gt 0) { throw 'Local changes found. Back them up or commit before updating; nothing overwritten.' }
Write-Host 'Pulling main branch...'
git pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { throw 'Git pull failed; no server restart attempted' }
Set-Location $backend
Write-Host 'Checking Python syntax and dependencies...'
python -m py_compile app\main.py
if ($LASTEXITCODE -ne 0) { throw 'Backend Python syntax check failed' }
python -c "import fastapi, uvicorn, MetaTrader5, pydantic; print('Dependencies available; Pydantic:', pydantic.VERSION)"
if ($LASTEXITCODE -ne 0) { throw 'Missing dependencies; run python -m pip install -r requirements.txt' }
$envPath = Join-Path $backend '.env'
if (!(Test-Path $envPath)) { throw 'Missing backend .env: keep your existing private account configuration' }
# Never overwrite .env or echo secrets. Explicitly leave trading disabled during deployment.
Write-Host 'Code updated. Do NOT start two servers on port 8765.'
Write-Host 'Stop the old Uvicorn window with Ctrl+C, then start in this window:'
Write-Host '  uvicorn app.main:app --host 127.0.0.1 --port 8765'
Write-Host 'Check /health and authenticated /trading/status after restart.'
Write-Host 'Live trading remains controlled by your private .env settings; this script does not change them.'
