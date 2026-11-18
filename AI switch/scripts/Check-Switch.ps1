<#
.SYNOPSIS
  ตรวจ Cisco switch และเครือข่าย 192.168.1.0/24 ทุก port หาอุปกรณ์/สิ่งแปลกปลอม
  แล้วเขียนรายงานเป็นตารางลงโฟลเดอร์ "AI switch" และ push ขึ้น GitHub

.DESCRIPTION
  1. SSH เข้า switch (Posh-SSH) อ่าน:
       show mac address-table / show interfaces status / show logging / show running-config
  2. Ping sweep ทั้งวง แล้วอ่าน ARP table ของ Windows
  3. เทียบกับ baseline.csv (อุปกรณ์ที่อนุญาต) และ config ครั้งก่อน
  4. เขียน report-YYYY-MM-DD.md แล้ว git commit + push

.PARAMETER RepoPath        โฟลเดอร์ที่ clone repo nextcloud-docker ไว้
.PARAMETER CreateBaseline  สร้าง baseline.csv จากสถานะปัจจุบัน (ใช้ครั้งแรก ตอนมั่นใจว่าเครือข่ายสะอาด)
.PARAMETER OfflineDataDir  อ่าน output ของ switch จากไฟล์แทน SSH (mac.txt, status.txt, logging.txt, config.txt)
.PARAMETER NoPush          ไม่ commit/push
.PARAMETER SkipScan        ไม่ ping sweep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoPath,
    [string] $SwitchIP   = '192.168.1.254',
    [string] $Subnet     = '192.168.1',
    [string] $Branch     = 'ccr-5a92b4e7-htpqjz',
    [string] $CredPath   = (Join-Path $env:USERPROFILE '.aiswitch\cred.xml'),
    [string] $EnablePath = (Join-Path $env:USERPROFILE '.aiswitch\enable.xml'),
    [switch] $CreateBaseline,
    [string] $OfflineDataDir,
    [switch] $NoPush,
    [switch] $SkipScan
)

$ErrorActionPreference = 'Stop'
$Folder       = Join-Path $RepoPath 'AI switch'
$BaselinePath = Join-Path $Folder 'baseline.csv'
$StateDir     = Join-Path $Folder 'state'
$Today        = Get-Date -Format 'yyyy-MM-dd'
$Now          = Get-Date -Format 'yyyy-MM-dd HH:mm'
$ReportPath   = Join-Path $Folder "report-$Today.md"
New-Item -ItemType Directory -Force -Path $Folder, $StateDir | Out-Null

# ---------------------------------------------------------------- helpers
function ConvertTo-CiscoMac([string]$mac) {
    $hex = ($mac -replace '[^0-9a-fA-F]', '').ToLower()
    if ($hex.Length -ne 12) { return $null }
    return '{0}.{1}.{2}' -f $hex.Substring(0,4), $hex.Substring(4,4), $hex.Substring(8,4)
}

function Get-MacTable([string]$text) {
    foreach ($line in $text -split "`r?`n") {
        if ($line -match '^\s*\*?\s*(\d+|All)\s+([0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4})\s+(\S+)\s+(?:\S+\s+){0,3}?(\S+/\S+|Po\d+|CPU|Router|Switch)\s*$') {
            if ($Matches[1] -eq 'All' -or $Matches[4] -in 'CPU','Router','Switch') { continue }
            [pscustomobject]@{ Vlan = $Matches[1]; MAC = $Matches[2].ToLower(); Type = $Matches[3]; Port = $Matches[4] }
        }
    }
}

function Get-PortStatus([string]$text) {
    $states = 'connected|notconnect|disabled|err-disabled|inactive|sfpAbsent|monitoring|xcvrAbsen'
    foreach ($line in $text -split "`r?`n") {
        if ($line -match "^(\S+)\s+(.*?)\s*\b($states)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$") {
            [pscustomobject]@{ Port = $Matches[1]; Name = $Matches[2].Trim(); Status = $Matches[3]; Vlan = $Matches[4] }
        }
    }
}

function Get-LogEvents([string]$text) {
    $rules = [ordered]@{
        'PSECURE_VIOLATION'      = 'Port-security violation (อุปกรณ์ไม่ได้รับอนุญาตเสียบ port)'
        'ERR_DISABLE'            = 'Port ถูกปิดอัตโนมัติ (err-disabled)'
        'LOGIN_FAILED'           = 'Login switch ไม่สำเร็จ'
        'SSH2_USERAUTH|AUTHFAIL' = 'SSH authentication ล้มเหลว'
        'CONFIG_I'               = 'มีการแก้ config'
        'DHCP_SNOOPING'          = 'DHCP snooping (อาจมี DHCP server แปลกปลอม)'
        'DUP_ADDR|DUPADDR'       = 'IP ซ้ำในเครือข่าย'
        'MACFLAP|MAC_MOVE'       = 'MAC ย้าย port ไปมา (loop / spoofing)'
        'STORM_CONTROL'          = 'Broadcast storm'
        'BPDUGUARD|BLOCK_BPDU'   = 'BPDU guard (มีคนต่อ switch เพิ่ม)'
    }
    foreach ($line in $text -split "`r?`n") {
        foreach ($k in $rules.Keys) {
            if ($line -match $k) {
                [pscustomobject]@{ Event = $rules[$k]; Line = $line.Trim() }
                break
            }
        }
    }
}

function Get-ConfigHash([string]$text) {
    $clean = ($text -split "`r?`n" | Where-Object {
        $_ -notmatch '^(! (Last configuration change|NVRAM config last updated)|Current configuration|Building configuration|ntp clock-period)' -and
        $_ -notmatch '#\s*$' -and $_ -notmatch 'show running-config'
    }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($clean))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join ''), $clean
}

function Escape-Md([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace '\|', '\|') }

# ---------------------------------------------------------------- switch data
function Invoke-SwitchCommands {
    param([string[]]$Commands)
    Import-Module Posh-SSH
    $cred = Import-Clixml $CredPath
    $session = New-SSHSession -ComputerName $SwitchIP -Credential $cred -AcceptKey -ConnectionTimeout 20
    try {
        $stream = New-SSHShellStream -SSHSession $session
        function Read-Until([int]$timeoutSec = 30) {
            $buf = ''; $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
                Start-Sleep -Milliseconds 300
                $chunk = $stream.Read()
                if ($chunk) { $buf += $chunk; $sw.Restart() }
                if ($buf -match '[\w\-\.]+[>#]\s*$') { break }
            }
            return $buf
        }
        $banner = Read-Until 15
        if ($banner -match '>\s*$') {
            if (-not (Test-Path $EnablePath)) { throw 'Switch อยู่ใน user mode (>) และไม่มี enable secret ให้รัน Setup-SwitchCheck.ps1 อีกครั้ง' }
            $stream.WriteLine('enable'); Start-Sleep 1
            $stream.WriteLine((Import-Clixml $EnablePath).GetNetworkCredential().Password)
            $null = Read-Until 10
        }
        $stream.WriteLine('terminal length 0'); $null = Read-Until 10
        $out = @{}
        foreach ($c in $Commands) { $stream.WriteLine($c); $out[$c] = Read-Until 60 }
        $stream.WriteLine('exit')
        return $out
    } finally {
        Remove-SSHSession -SSHSession $session | Out-Null
    }
}

$errors = New-Object System.Collections.Generic.List[string]
$cmdMac = 'show mac address-table'; $cmdSt = 'show interfaces status'
$cmdLog = 'show logging';           $cmdCfg = 'show running-config'
$raw = @{}
try {
    if ($OfflineDataDir) {
        $raw[$cmdMac] = Get-Content -Raw (Join-Path $OfflineDataDir 'mac.txt')
        $raw[$cmdSt]  = Get-Content -Raw (Join-Path $OfflineDataDir 'status.txt')
        $raw[$cmdLog] = Get-Content -Raw (Join-Path $OfflineDataDir 'logging.txt') -ErrorAction SilentlyContinue
        $raw[$cmdCfg] = Get-Content -Raw (Join-Path $OfflineDataDir 'config.txt') -ErrorAction SilentlyContinue
    } else {
        $raw = Invoke-SwitchCommands -Commands $cmdMac, $cmdSt, $cmdLog, $cmdCfg
    }
} catch {
    $errors.Add("เชื่อมต่อ switch $SwitchIP ไม่ได้: $($_.Exception.Message)")
}

$macTable   = @(if ($raw[$cmdMac]) { Get-MacTable  $raw[$cmdMac] })
$portStatus = @(if ($raw[$cmdSt])  { Get-PortStatus $raw[$cmdSt] })
$logEvents  = @(if ($raw[$cmdLog]) { Get-LogEvents $raw[$cmdLog] })

# ---------------------------------------------------------------- network scan
$neighbors = @()
if (-not $SkipScan -and -not $OfflineDataDir) {
    $tasks = 1..254 | ForEach-Object {
        $p = New-Object System.Net.NetworkInformation.Ping
        $p.SendPingAsync("$Subnet.$_", 800)
    }
    try { [Threading.Tasks.Task]::WaitAll($tasks) } catch { }
    $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$Subnet.*" -and $_.State -in 'Reachable','Stale','Delay','Probe','Permanent' -and
                       $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' } |
        ForEach-Object { [pscustomobject]@{ IP = $_.IPAddress; MAC = ConvertTo-CiscoMac $_.LinkLayerAddress } } |
        Sort-Object { [version]$_.IP } -Unique)
}

# ---------------------------------------------------------------- baseline
if ($CreateBaseline) {
    $ipByMac = @{}; foreach ($n in $neighbors) { $ipByMac[$n.MAC] = $n.IP }
    $uplinks = $macTable | Group-Object Port | Where-Object Count -gt 5 | ForEach-Object Name
    $rows = foreach ($m in $macTable) {
        [pscustomobject]@{ Port = $m.Port; MAC = $m.MAC; Vlan = $m.Vlan; IP = $ipByMac[$m.MAC]
                           Device = ''; Uplink = $(if ($m.Port -in $uplinks) { 'yes' } else { '' }) }
    }
    $onSwitch = $macTable.MAC
    $rows += foreach ($n in $neighbors | Where-Object { $_.MAC -notin $onSwitch }) {
        [pscustomobject]@{ Port = ''; MAC = $n.MAC; Vlan = ''; IP = $n.IP; Device = ''; Uplink = '' }
    }
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $BaselinePath
    if ($raw[$cmdCfg]) { (Get-ConfigHash $raw[$cmdCfg])[0] | Set-Content (Join-Path $StateDir 'config.sha256') }
    Write-Host "สร้าง baseline แล้ว: $BaselinePath ($(@($rows).Count) รายการ) - เปิดไฟล์แล้วเติมชื่ออุปกรณ์ในคอลัมน์ Device"
    if ($errors.Count) { Write-Warning ($errors -join "`n") }
    return
}

$baseline = @(if (Test-Path $BaselinePath) { Import-Csv $BaselinePath } else { $errors.Add('ไม่มี baseline.csv ให้รัน -CreateBaseline ก่อน') })
$knownMacs   = @{}; foreach ($b in $baseline) { if ($b.MAC) { $knownMacs[$b.MAC.ToLower()] = $b } }
$uplinkPorts = @($baseline | Where-Object { $_.Uplink -eq 'yes' } | ForEach-Object Port | Select-Object -Unique)
$basePorts   = @($baseline | Where-Object Port | ForEach-Object Port | Select-Object -Unique)

# ---------------------------------------------------------------- findings
$unknownOnSwitch = @($macTable | Where-Object { -not $knownMacs.ContainsKey($_.MAC) })
$movedMacs = @($macTable | Where-Object {
    $knownMacs.ContainsKey($_.MAC) -and $knownMacs[$_.MAC].Port -and $_.Port -ne $knownMacs[$_.MAC].Port -and
    $_.Port -notin $uplinkPorts -and $knownMacs[$_.MAC].Port -notin $uplinkPorts })
$unknownOnNet = @($neighbors | Where-Object { -not $knownMacs.ContainsKey($_.MAC) })
$newPortsUp   = @($portStatus | Where-Object { $_.Status -eq 'connected' -and $_.Port -notin $basePorts -and $_.Port -notin $uplinkPorts })
$errDisabled  = @($portStatus | Where-Object Status -eq 'err-disabled')
$multiMac     = @($macTable | Where-Object { $_.Port -notin $uplinkPorts -and $_.Port -notlike 'Po*' } |
                  Group-Object Port | Where-Object Count -gt 1)

$configChanged = $null
if ($raw[$cmdCfg]) {
    $hash, $clean = Get-ConfigHash $raw[$cmdCfg]
    $hashFile = Join-Path $StateDir 'config.sha256'
    if (Test-Path $hashFile) { $configChanged = ((Get-Content $hashFile -Raw).Trim() -ne $hash) }
    $hash | Set-Content $hashFile
}

$alerts = $unknownOnSwitch.Count + $movedMacs.Count + $unknownOnNet.Count + $newPortsUp.Count +
          $errDisabled.Count + $multiMac.Count + $logEvents.Count + [int]($configChanged -eq $true)

# ---------------------------------------------------------------- report
function Row($n, $item, $scope, $count, $note) {
    $res = if ($null -eq $count) { '⏸️ ไม่มีข้อมูล' } elseif ($count -gt 0) { "🔴 พบ $count" } else { '🟢 ปกติ' }
    "| $n | $item | $scope | $res | $note |"
}
$swOk = [bool]$raw[$cmdMac]
$overall = if ($errors.Count -and -not $swOk) { 'ERROR' } elseif ($alerts -gt 0) { 'ALERT' } else { 'OK' }
$overallTh = @{ ERROR = '⚠️ ตรวจไม่ครบ — มีข้อผิดพลาด'; ALERT = "🔴 พบสิ่งผิดปกติ $alerts รายการ"; OK = '🟢 ไม่พบสิ่งแปลกปลอม' }[$overall]

$md = New-Object System.Collections.Generic.List[string]
$md.Add("<!-- status: $overall alerts=$alerts -->")
$md.Add("# รายงานตรวจสอบ Switch — $Today")
$md.Add('')
$md.Add("**สถานะ: $overallTh**  ")
$md.Add("Switch: Cisco $SwitchIP · เครือข่าย: $Subnet.0/24 · ตรวจเมื่อ: $Now · ตรวจจาก: $env:COMPUTERNAME")
$md.Add('')
$md.Add('| # | รายการตรวจ | ช่องทาง/Port | ผล | หมายเหตุ |')
$md.Add('|---|---|---|---|---|')
$md.Add((Row 1 'MAC ที่ไม่อยู่ใน baseline (บน switch)' "ทุก port ($($portStatus.Count))" $(if ($swOk) { $unknownOnSwitch.Count }) 'อุปกรณ์ใหม่ที่เสียบเข้า switch'))
$md.Add((Row 2 'อุปกรณ์ไม่รู้จักในวง IP' "$Subnet.1-254" $(if ($neighbors.Count) { $unknownOnNet.Count }) "ออนไลน์ $($neighbors.Count) เครื่อง"))
$md.Add((Row 3 'Port ที่ up แต่ไม่อยู่ใน baseline' 'ทุก port' $(if ($portStatus.Count) { $newPortsUp.Count }) ''))
$md.Add((Row 4 'MAC ย้าย port' 'ทุก port' $(if ($swOk) { $movedMacs.Count }) 'อาจเป็น MAC spoofing'))
$md.Add((Row 5 'หลาย MAC ใน access port เดียว' 'access ports' $(if ($swOk) { $multiMac.Count }) 'อาจมี hub/switch/AP แอบต่อ'))
$md.Add((Row 6 'Port err-disabled' 'ทุก port' $(if ($portStatus.Count) { $errDisabled.Count }) ''))
$md.Add((Row 7 'เหตุการณ์ความปลอดภัยใน log' 'Management/ทุก port' $(if ($raw[$cmdLog]) { $logEvents.Count }) 'port-security, login fail, BPDU, DHCP snooping ฯลฯ'))
$md.Add((Row 8 'Running-config เปลี่ยนจากครั้งก่อน' 'Config' $(if ($null -ne $configChanged) { [int]$configChanged }) $(if ($raw[$cmdCfg] -and $null -eq $configChanged) { 'บันทึกค่าแรกแล้ว' })))

function Add-Section($title, $headers, $rows) {
    if (-not $rows -or @($rows).Count -eq 0) { return }
    if ($rows -isnot [array] -or ($rows.Count -gt 0 -and $rows[0] -isnot [array])) { $rows = ,@($rows) }  # single row got unwrapped
    $md.Add(''); $md.Add("## $title"); $md.Add('')
    $md.Add('| ' + ($headers -join ' | ') + ' |')
    $md.Add('|' + (($headers | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $rows) { $md.Add('| ' + (($r | ForEach-Object { Escape-Md "$_" }) -join ' | ') + ' |') }
}
$ipByMac = @{}; foreach ($n in $neighbors) { $ipByMac[$n.MAC] = $n.IP }
Add-Section '🔴 MAC ไม่รู้จักบน switch' 'Port','VLAN','MAC','IP','Type' ($unknownOnSwitch | ForEach-Object { ,@($_.Port, $_.Vlan, $_.MAC, $ipByMac[$_.MAC], $_.Type) })
Add-Section '🔴 อุปกรณ์ไม่รู้จักในวง IP' 'IP','MAC' ($unknownOnNet | ForEach-Object { ,@($_.IP, $_.MAC) })
Add-Section '🔴 Port ใหม่ที่ up' 'Port','ชื่อ','VLAN' ($newPortsUp | ForEach-Object { ,@($_.Port, $_.Name, $_.Vlan) })
Add-Section '🔴 MAC ย้าย port' 'MAC','Port เดิม','Port ปัจจุบัน','อุปกรณ์' ($movedMacs | ForEach-Object { ,@($_.MAC, $knownMacs[$_.MAC].Port, $_.Port, $knownMacs[$_.MAC].Device) })
Add-Section '🔴 หลาย MAC ใน port เดียว' 'Port','จำนวน MAC','MAC' ($multiMac | ForEach-Object { ,@($_.Name, $_.Count, (($_.Group.MAC) -join ', ')) })
Add-Section '🔴 Port err-disabled' 'Port','ชื่อ' ($errDisabled | ForEach-Object { ,@($_.Port, $_.Name) })
Add-Section '🔴 เหตุการณ์ใน log' 'เหตุการณ์','บรรทัด log' ($logEvents | Select-Object -Last 30 | ForEach-Object { ,@($_.Event, $_.Line) })
Add-Section '📋 สถานะทุก port' 'Port','ชื่อ','สถานะ','VLAN','จำนวน MAC' ($portStatus | ForEach-Object {
    $p = $_.Port; ,@($p, $_.Name, $_.Status, $_.Vlan, @($macTable | Where-Object Port -eq $p).Count) })
if ($errors.Count) { $md.Add(''); $md.Add('## ⚠️ ข้อผิดพลาด'); $md.Add(''); foreach ($e in $errors) { $md.Add("- $(Escape-Md $e)") } }

[IO.File]::WriteAllLines($ReportPath, $md, (New-Object Text.UTF8Encoding $false))
Write-Host "เขียนรายงาน: $ReportPath ($overall, alerts=$alerts)"

# ---------------------------------------------------------------- git push
if (-not $NoPush) {
    Push-Location $RepoPath
    try {
        git pull --rebase --autostash origin $Branch 2>&1 | Write-Host
        git add -- 'AI switch' 2>&1 | Write-Host
        git commit -m "AI switch: daily report $Today ($overall)" 2>&1 | Write-Host
        for ($i = 0; $i -lt 4; $i++) {
            git push origin $Branch 2>&1 | Write-Host
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds ([math]::Pow(2, $i + 1))
        }
    } finally { Pop-Location }
}
