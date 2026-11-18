<#
.SYNOPSIS
  ติดตั้งระบบตรวจ switch รายวันบน Windows (รันครั้งเดียว ใน PowerShell แบบ Run as Administrator)

  ทำ 4 อย่าง:
   1. ติดตั้ง module Posh-SSH
   2. เก็บ username/password ของ switch แบบเข้ารหัส (DPAPI ถอดได้เฉพาะ user นี้บนเครื่องนี้)
   3. สร้าง baseline.csv จากสถานะปัจจุบัน
   4. ตั้ง Task Scheduler ให้รัน Check-Switch.ps1 ทุกวัน
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoPath,
    [string] $SwitchIP = '192.168.1.254',
    [string] $Time     = '07:13'
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE '.aiswitch'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$check = Join-Path $RepoPath 'AI switch\scripts\Check-Switch.ps1'

Write-Host '1) ติดตั้ง Posh-SSH' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable Posh-SSH)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module Posh-SSH -Scope CurrentUser -Force
}

Write-Host "2) ใส่ username/password สำหรับ SSH เข้า switch $SwitchIP" -ForegroundColor Cyan
Get-Credential -Message "Cisco switch $SwitchIP (SSH login)" | Export-Clixml (Join-Path $dir 'cred.xml')
if ((Read-Host 'ต้องใช้ enable secret ไหม? (y/N)') -eq 'y') {
    Get-Credential -UserName 'enable' -Message 'ใส่ enable secret ในช่อง password' | Export-Clixml (Join-Path $dir 'enable.xml')
}

Write-Host '3) สร้าง baseline (ทำตอนมั่นใจว่าเครือข่ายตอนนี้ไม่มีของแปลกปลอม)' -ForegroundColor Cyan
& $check -RepoPath $RepoPath -SwitchIP $SwitchIP -CreateBaseline
Write-Host "   >> เปิด '$RepoPath\AI switch\baseline.csv' เติมชื่ออุปกรณ์ในคอลัมน์ Device แล้ว commit" -ForegroundColor Yellow

Write-Host "4) ตั้ง Task Scheduler รันทุกวันเวลา $Time" -ForegroundColor Cyan
$me = "$env:USERDOMAIN\$env:USERNAME"
$pw = (Get-Credential -UserName $me -Message 'รหัสผ่าน Windows ของคุณ (ให้ task รันได้แม้ไม่ได้ login)').GetNetworkCredential().Password
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$check`" -RepoPath `"$RepoPath`" -SwitchIP $SwitchIP"
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'AI switch daily check' -Action $action -Trigger $trigger -Settings $set `
    -User $me -Password $pw -RunLevel Highest -Force | Out-Null
Write-Host 'เสร็จแล้ว ทดสอบทันทีด้วย: Start-ScheduledTask "AI switch daily check"' -ForegroundColor Green
