#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[D-Z]$')][string]$RunProfile,
    [string]$StoreRoot = (Join-Path $env:LOCALAPPDATA 'RcloneDriveManager'),
    [switch]$Library
)
$ErrorActionPreference = 'Stop'
$script:StoreRoot = [IO.Path]::GetFullPath($StoreRoot)
$script:SourceFile = $PSCommandPath
$script:Version = '1.0.0'

function Resolve-Winget {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (!$command) { throw '未找到 winget。请从 Microsoft Store 安装或更新“应用安装程序”，然后重新打开 PowerShell。' }
    return $command.Source
}
function Assert-ComponentsIdle {
    # Dependencies are shared by all rclone instances, including mounts outside this manager.
    if (Get-Process -Name rclone -ErrorAction SilentlyContinue) { throw '检测到运行中的 rclone。请先安全卸载所有磁盘并退出其他 rclone 实例，再卸载组件。' }
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.Description -eq 'Managed by RcloneDriveManager' -and $_.Settings.Enabled
    })
    if ($tasks.Count) { throw '请先关闭所有磁盘的登录自启，再卸载组件。' }
}
function Invoke-ComponentAction {
    param(
        [ValidateSet('install','uninstall')][string]$Action,
        [ValidateSet('Rclone.Rclone','WinFsp.WinFsp')][string]$PackageId
    )
    $winget = Resolve-Winget
    if ($Action -eq 'uninstall') { Assert-ComponentsIdle }
    $arguments = @($Action, '--id', $PackageId, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    if ($Action -eq 'install') { $arguments += '--accept-package-agreements' }
    & $winget @arguments | Out-Host
    $code = $LASTEXITCODE
    # WinGet returns HRESULTs; compare unsigned hexadecimal representations.
    $hex = '{0:X8}' -f ([long]$code -band 0xFFFFFFFFL)
    if ($code -eq 0) {
        Write-Host '组件操作完成；如安装程序要求重启，请先重启 Windows。' -ForegroundColor Green
    } elseif ($Action -eq 'install' -and $hex -eq '8A15002B') {
        Write-Host '组件已安装且没有可用更新。'
    } elseif ($Action -eq 'uninstall' -and $hex -eq '8A150014') {
        Write-Host 'winget 未找到匹配的已安装组件；手动或便携安装请自行管理。'
    } else { throw "winget 操作失败（0x$hex）；请检查上方输出，组件可能尚未完成安装或卸载。" }
}
function Show-Components {
    $winget = Resolve-Winget
    foreach ($id in @('Rclone.Rclone','WinFsp.WinFsp')) {
        & $winget list --id $id --exact --accept-source-agreements --disable-interactivity | Out-Host
        $hex = '{0:X8}' -f ([long]$LASTEXITCODE -band 0xFFFFFFFFL)
        if ($LASTEXITCODE -ne 0 -and $hex -ne '8A150014') { throw "无法查询组件 $id（0x$hex）。" }
    }
    try { Write-Host ('rclone 路径：' + (Resolve-Rclone '')) } catch { Write-Host $_.Exception.Message }
    $service = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    Write-Host ('WinFsp 服务：' + $(if ($service) { $service.Status } else { '未检测到' }))
}
function Show-ComponentMenu {
    while ($true) {
        Write-Heading '组件安装管理'
        Write-MenuItem '1' '安装 rclone 和 WinFsp' '通过 winget 官方源安装；WinFsp 可能弹出 UAC。'
        Write-MenuItem '2' '安装 rclone' '包 ID：Rclone.Rclone'
        Write-MenuItem '3' '安装 WinFsp' '包 ID：WinFsp.WinFsp'
        Write-MenuItem '4' '查看组件状态' '查询 winget 记录、rclone 路径和 WinFsp 服务。'
        Write-MenuItem '5' '卸载 rclone' '先关闭自启，安全卸载磁盘并退出所有 rclone 实例。'
        Write-MenuItem '6' '卸载 WinFsp' '也会影响其他依赖 WinFsp 的应用；先关闭这些应用。'
        Write-MenuItem '7' '卸载两个组件' '保留本脚本的挂载设置、缓存和日志。'
        Write-MenuItem '0' '返回主菜单' ''
        try {
            $choice = (Read-Host '  输入操作编号').Trim()
            switch ($choice) {
                '0' { return }
                '1' { Invoke-ComponentAction install 'WinFsp.WinFsp'; Invoke-ComponentAction install 'Rclone.Rclone' }
                '2' { Invoke-ComponentAction install 'Rclone.Rclone' }
                '3' { Invoke-ComponentAction install 'WinFsp.WinFsp' }
                '4' { Show-Components }
                { $_ -in @('5','6','7') } {
                    if ((Read-Choice '确认通过 winget 卸载所选组件？y/n' 'n') -eq 'y') {
                        if ($choice -in @('5','7')) { Invoke-ComponentAction uninstall 'Rclone.Rclone' }
                        if ($choice -in @('6','7')) { Invoke-ComponentAction uninstall 'WinFsp.WinFsp' }
                    }
                }
                default { Write-Host '请输入菜单中的操作编号。' }
            }
        } catch { Write-Host ('操作未完成：' + $_.Exception.Message) -ForegroundColor Yellow }
        $null = Read-Host '  按回车继续'
    }
}

function Read-Choice([string]$Prompt, [string]$Default) {
    Write-Host "  $Prompt" -ForegroundColor White
    $value = (Read-Host "  输入（回车采用 $Default）").Trim()
    if (!$value) { return $Default }
    return $value
}
function Write-Heading([string]$Title) {
    Write-Host ''
    Write-Host '  ────────────────────────────────────────────────' -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────────' -ForegroundColor DarkCyan
}
function Write-MenuItem([string]$Key, [string]$Title, [string]$Hint) {
    Write-Host "  [$Key] " -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White
    if ($Hint) { Write-Host "      $Hint" -ForegroundColor DarkGray }
}
function Assert-Profile($Profile) {
    if ($Profile.Drive -notmatch '^[D-Z]$') { throw '盘符必须为 D 到 Z 的一个字母。' }
    if ($Profile.Remote -notmatch '^[^:\r\n]+:$') { throw '请选择已有 rclone 远端。' }
    if ($Profile.Subpath -match '[\r\n\x00]') { throw '子目录包含无效字符。' }
    if ($Profile.Mode -notin @('network','fixed')) { throw '挂载模式无效。' }
    if ($Profile.CacheMode -notin @('full','writes','off')) { throw '缓存模式无效。' }
    if ($Profile.CacheLimit -notmatch '^[1-9]\d*(M|G|T)$') { throw '缓存上限格式应为 20G、500M 等。' }
    if ($Profile.TotalSize -ne 'auto' -and $Profile.TotalSize -notmatch '^[1-9]\d*(G|T)$') { throw '显示容量应为 auto、500G、2T 等。' }
    if (![IO.Path]::IsPathRooted($Profile.Config) -or !(Test-Path -LiteralPath $Profile.Config)) { throw 'rclone 配置文件不存在。' }
}
function Get-ProfileDir([string]$Drive) {
    if ($Drive -notmatch '^[D-Z]$') { throw '无效盘符。' }
    return Join-Path $script:StoreRoot $Drive
}
function Initialize-Store {
    New-Item -ItemType Directory -Path $script:StoreRoot -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # Persist only the DACL; Set-Acl can also request audit-security privileges.
    $sddl = 'D:P(A;OICI;FA;;;' + $userSid + ')(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    $acl.SetSecurityDescriptorSddlForm($sddl,[Security.AccessControl.AccessControlSections]::Access)
    $directory = New-Object IO.DirectoryInfo($script:StoreRoot)
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $directory.SetAccessControl($acl)
    } else {
        [IO.FileSystemAclExtensions]::SetAccessControl($directory,$acl)
    }
}
function Write-JsonFile([string]$Path, $Value) {
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-Profile([string]$Drive) {
    $path = Join-Path (Get-ProfileDir $Drive) 'profile.json'
    if (!(Test-Path -LiteralPath $path)) { throw "没有 $Drive 盘的管理配置。" }
    $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-Profile $profile
    if ($profile.Drive -ne $Drive) { throw '配置盘符与目录不一致。' }
    return $profile
}
function Resolve-Rclone([string]$Preferred) {
    if ($Preferred -and (Test-Path -LiteralPath $Preferred)) { return [IO.Path]::GetFullPath($Preferred) }
    $found = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Rclone.Rclone_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $found = Get-ChildItem -LiteralPath $winget -Filter rclone.exe -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw '未找到 rclone.exe，请通过菜单 [9] 安装，或在新建配置时填写程序路径。'
}
function Get-RcloneConfig([string]$Binary) {
    $result = @(& $Binary config file)
    if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) { throw '无法查询 rclone 配置路径。' }
    $path = $result[-1].Trim()
    if (!(Test-Path -LiteralPath $path)) { throw '请先使用 rclone config 创建远端。' }
    return [IO.Path]::GetFullPath($path)
}
function Get-RemoteNames([string]$Binary, [string]$Config) {
    $names = @(& $Binary listremotes --config $Config)
    if ($LASTEXITCODE -ne 0) { throw '无法读取远端列表；加密配置请先确认非交互解锁方式。' }
    return @($names | Where-Object { $_ -match '^[^:\r\n]+:$' })
}
function Quote-NativeArg([string]$Value) {
    # Windows CommandLineToArgvW escaping, including trailing backslashes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Build-MountArgs($Profile, [int]$Port, [string]$Secret) {
    Assert-Profile $Profile
    $dir = Get-ProfileDir $Profile.Drive
    $arguments = @('mount', ($Profile.Remote + $Profile.Subpath), ($Profile.Drive + ':'),
        '--config', $Profile.Config, '--no-console', '--volname', ('RDM-' + $Profile.Drive),
        '--vfs-cache-mode', $Profile.CacheMode, '--vfs-cache-max-size', $Profile.CacheLimit,
        '--cache-dir', (Join-Path $dir 'cache'), '--dir-cache-time', '1m',
        '--log-file', (Join-Path $dir 'mount.log'), '--log-level', 'NOTICE',
        '--log-file-max-size', '10M', '--log-file-max-backups', '3',
        '--rc', '--rc-addr', ('127.0.0.1:' + $Port), '--rc-user', 'mount-manager', '--rc-pass', $Secret)
    if ($Profile.Mode -eq 'network') { $arguments += '--network-mode' }
    if ($Profile.ReadOnly) { $arguments += '--read-only' }
    if ($Profile.TotalSize -ne 'auto') { $arguments += @('--vfs-disk-space-total-size', $Profile.TotalSize) }
    # Never enable recursive used-size scanning implicitly.
    return $arguments
}
function New-ControlPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    try { $listener.Start(); return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
function Protect-ControlSecret([string]$Secret) {
    return ConvertFrom-SecureString (ConvertTo-SecureString $Secret -AsPlainText -Force)
}
function Get-Runtime([string]$Drive) {
    $path = Join-Path (Get-ProfileDir $Drive) 'runtime.json'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
function Find-OwnedProcess($Runtime) {
    if (!$Runtime) { return $null }
    $process = Get-Process -Id $Runtime.ProcessId -ErrorAction SilentlyContinue
    if (!$process) { return $null }
    if ($process.StartTime.ToUniversalTime().Ticks.ToString() -ne $Runtime.StartTicks) { throw '进程标识不匹配，拒绝操作。' }
    if ($process.Path -ne $Runtime.Binary) { throw '程序路径不匹配，拒绝操作。' }
    return $process
}
function Invoke-Control($Runtime, [string]$Method, $Body = @{}) {
    $secret = ConvertTo-SecureString $Runtime.Secret
    $credential = New-Object Management.Automation.PSCredential('mount-manager',$secret)
    $raw = 'mount-manager:' + $credential.GetNetworkCredential().Password
    $headers = @{Authorization='Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))}
    return Invoke-RestMethod -Uri ("http://127.0.0.1:$($Runtime.Port)/$Method") -Method Post -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress) -TimeoutSec 5
}
function Assert-SafeToUnmount($Stats) {
    if (!$Stats -or !$Stats.diskCache -or $null -eq $Stats.inUse -or
        $null -eq $Stats.diskCache.uploadsQueued -or $null -eq $Stats.diskCache.uploadsInProgress -or $null -eq $Stats.diskCache.erroredFiles) {
        throw '无法确认上传状态，拒绝卸载。'
    }
    if ($Stats.inUse -gt 0 -or $Stats.diskCache.uploadsQueued -gt 0 -or
        $Stats.diskCache.uploadsInProgress -gt 0 -or $Stats.diskCache.erroredFiles -gt 0) {
        throw '文件仍被打开、正在上传、等待上传或上传失败；请关闭文件并等待上传完成，再卸载。'
    }
}
function Start-Mount($Profile) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false,('Local\RcloneDriveManager-' + $sid + '-' + $Profile.Drive))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw '该盘的另一启动操作尚未结束，请稍后重试。' }
        return Start-MountCore $Profile
    } finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Start-MountCore($Profile) {
    Assert-Profile $Profile
    $runtime = Get-Runtime $Profile.Drive
    $existing = Find-OwnedProcess $runtime
    if ($existing) { return $existing }
    if (Get-PSDrive -Name $Profile.Drive -ErrorAction SilentlyContinue) { throw '盘符已占用，未接管现有驱动器。' }
    if (!(Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue)) { throw '未检测到 WinFsp，请先安装。' }
    $binary = Resolve-Rclone $Profile.Binary
    $port = New-ControlPort
    $secret = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $dir = Get-ProfileDir $Profile.Drive
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $arguments = Build-MountArgs $Profile $port $secret
    $line = ($arguments | ForEach-Object { Quote-NativeArg $_ }) -join ' '
    $process = Start-Process -FilePath $binary -ArgumentList $line -WindowStyle Hidden -PassThru
    $runtime = [pscustomobject]@{ProcessId=$process.Id;StartTicks=$process.StartTime.ToUniversalTime().Ticks.ToString();Binary=$binary;Port=$port;Secret=(Protect-ControlSecret $secret)}
    Write-JsonFile (Join-Path $dir 'runtime.json') $runtime
    for ($attempt=0; $attempt -lt 30; $attempt++) {
        $process.Refresh()
        if ($process.HasExited) { throw "挂载进程已退出，请查看 $dir\mount.log。" }
        try {
            $null = Invoke-Control $runtime 'vfs/stats'
            if (Get-PSDrive -Name $Profile.Drive -ErrorAction SilentlyContinue) { return $process }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    # ponytail: keep the owned process/state on timeout; never kill a potentially writing mount.
    throw '挂载尚未就绪；保留进程和缓存，请查看状态及日志，不要重复挂载。'
}
function Refresh-Explorer([string]$Drive, [bool]$NetworkMode) {
    if ($NetworkMode) {
        # Only our unique UNC record, not the generic drive-letter record or other mappings.
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##server#RDM-' + $Drive
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    if (!('RDM.Shell' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; namespace RDM { public static class Shell { [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(uint e, uint f, string p, IntPtr q); } }'
    }
    [RDM.Shell]::SHChangeNotify(0x80,0x1005,($Drive + ':\'),[IntPtr]::Zero)
}
function Stop-Mount($Profile) {
    $runtime = Get-Runtime $Profile.Drive
    $process = Find-OwnedProcess $runtime
    if ($process) {
        if ($Profile.CacheMode -eq 'off') {
            $stats = Invoke-Control $runtime 'vfs/stats'
            if ($null -eq $stats.inUse -or $stats.inUse -gt 0) { throw '仍有打开的文件，或无法确认状态；拒绝卸载。' }
        } else { Assert-SafeToUnmount (Invoke-Control $runtime 'vfs/stats') }
        Write-Host '请勿继续访问该盘，正在退出挂载。'
        $null = Invoke-Control $runtime 'core/quit' @{exitCode=0}
        if (!$process.WaitForExit(10000)) { throw '退出超时，保留缓存和状态；未强制结束进程。' }
    } elseif (Get-PSDrive -Name $Profile.Drive -ErrorAction SilentlyContinue) {
        throw '该盘由其他程序管理，拒绝卸载。'
    }
    $path = Join-Path (Get-ProfileDir $Profile.Drive) 'runtime.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    Refresh-Explorer $Profile.Drive ($Profile.Mode -eq 'network')
    Write-Host '已卸载；缓存保留，以便恢复未完成的上传。'
}
function Get-TaskName([string]$Drive) { return 'RcloneDriveManager-' + $Drive }
function Get-Autostart([string]$Drive) {
    return Get-ScheduledTask -TaskName (Get-TaskName $Drive) -ErrorAction SilentlyContinue
}
function Build-HiddenLauncher([string]$CommandLine, [string]$ErrorLog) {
    $escapedCommand = $CommandLine.Replace('"','""')
    $escapedLog = $ErrorLog.Replace('"','""')
    return @"
Option Explicit
Dim shell, result, failure, fs, log
On Error Resume Next
Set shell = CreateObject("WScript.Shell")
result = shell.Run("$escapedCommand", 0, True)
If Err.Number <> 0 Then
    failure = Err.Description
    Set fs = CreateObject("Scripting.FileSystemObject")
    Set log = fs.OpenTextFile("$escapedLog", 8, True, -1)
    log.WriteLine CStr(Now) & " " & failure
    log.Close
    WScript.Quit 1
End If
WScript.Quit result
"@
}
function Set-Autostart($Profile, [bool]$Enabled) {
    $name = Get-TaskName $Profile.Drive
    if (!$Enabled) {
        $existing = Get-Autostart $Profile.Drive
        if ($existing -and $existing.Description -ne 'Managed by RcloneDriveManager') { throw '同名任务不属于本脚本，拒绝禁用。' }
        if ($existing) { Disable-ScheduledTask -TaskName $name | Out-Null }
        Write-Host '已关闭登录自启；当前挂载继续运行。'
        return
    }
    $existing = Get-Autostart $Profile.Drive
    if ($existing -and $existing.Description -ne 'Managed by RcloneDriveManager') { throw '存在同名但不属于本脚本的任务，拒绝覆盖。' }
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (!(Test-Path -LiteralPath $wscript)) { throw 'Windows Script Host 不可用，无法设置无窗口自启。' }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows Script Host\Settings','HKLM:\Software\Microsoft\Windows Script Host\Settings')) {
        $hostSettings = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($hostSettings -and $null -ne $hostSettings.Enabled -and $hostSettings.Enabled -eq 0) { throw 'Windows Script Host 已被禁用；未修改该策略或自启任务。' }
    }
    $installed = Join-Path $script:StoreRoot 'RcloneDriveManager.ps1'
    if ([IO.Path]::GetFullPath($script:SourceFile) -ne [IO.Path]::GetFullPath($installed)) { Copy-Item -LiteralPath $script:SourceFile -Destination $installed -Force }
    $command = "& '" + $installed.Replace("'","''") + "' -RunProfile '" + $Profile.Drive + "' -StoreRoot '" + $script:StoreRoot.Replace("'","''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $commandLine = (Quote-NativeArg $powershell) + ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded
    $dir = Get-ProfileDir $Profile.Drive
    $launcher = Join-Path $dir 'autostart.vbs'
    Build-HiddenLauncher $commandLine (Join-Path $dir 'launcher-error.log') | Set-Content -LiteralPath $launcher -Encoding Unicode
    $action = New-ScheduledTaskAction -Execute $wscript -Argument ('//B //NoLogo ' + (Quote-NativeArg $launcher))
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT20S'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Managed by RcloneDriveManager' -Force | Out-Null
    Write-Host '已开启无窗口自启：登录后约 20 秒挂载，失败每分钟重试，最多 10 次。'
}
function New-MountProfile {
    Write-Heading '挂载设置 · 1 / 3  选择远端'
    $preferred = Read-Choice 'rclone.exe 路径（auto 为自动查找）' 'auto'
    $binary = Resolve-Rclone $(if ($preferred -eq 'auto') { '' } else { $preferred })
    $config = Read-Choice 'rclone 配置文件路径' (Get-RcloneConfig $binary)
    $remotes = @(Get-RemoteNames $binary $config)
    if (!$remotes.Count) { throw '没有远端，请先运行 rclone config。' }
    for ($i=0; $i -lt $remotes.Count; $i++) { Write-MenuItem ($i+1) $remotes[$i] '' }
    $choice = Read-Choice '选择远端编号' '1'
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $remotes.Count) { throw '远端编号无效。' }
    $remote = $remotes[[int]$choice-1]
    $subpath = Read-Choice '远端子目录（/ 表示根目录）' '/'
    if ($subpath -eq '/') { $subpath = '' }
    Write-Heading '挂载设置 · 2 / 3  盘符与显示'
    $drive = (Read-Choice '盘符，填写单个字母' 'X').ToUpperInvariant()
    $dir = Get-ProfileDir $drive
    if (Test-Path -LiteralPath (Join-Path $dir 'profile.json')) { throw '该盘已有配置；先卸载并删除配置后再重新创建，旧缓存会保留。' }
    if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) { throw '盘符已占用。' }
    Write-MenuItem 'network' '网络驱动器 · 推荐' '显示在“网络位置”，适合远程存储。'
    Write-MenuItem 'fixed' '固定磁盘' '显示在“设备和驱动器”，数据仍在远端。'
    $mode = Read-Choice '挂载模式 network / fixed' 'network'
    Write-Heading '挂载设置 · 3 / 3  缓存与访问'
    Write-MenuItem 'full' '读写缓存 · 推荐' '普通应用兼容性更好。'
    Write-MenuItem 'writes' '只缓存写入' '减少读取占用的磁盘空间。'
    Write-MenuItem 'off' '关闭磁盘缓存' '部分应用可能无法正常保存。'
    $cacheMode = Read-Choice '缓存模式 full / writes / off' 'full'
    $cacheLimit = (Read-Choice '缓存目标上限（不是硬限制；打开或待上传文件可能超出）' '20G').ToUpperInvariant()
    Write-Host ''
    Write-Host '  容量显示说明' -ForegroundColor Cyan
    Write-Host '  auto：由服务端提供；缺失时可能显示 1 PiB。' -ForegroundColor Gray
    Write-Host '  500G / 2T 等：仅自定义总容量，剩余量未必准确。' -ForegroundColor Gray
    $totalSize = Read-Choice '总容量显示 auto / 500G / 2T 等' 'auto'
    if ($totalSize -ne 'auto') { $totalSize = $totalSize.ToUpperInvariant() }
    $readOnly = Read-Choice '只读挂载？y/n' 'n'
    if ($readOnly -notin @('y','n')) { throw '只读选项应为 y 或 n。' }
    $profile = [pscustomobject]@{Drive=$drive;Remote=$remote;Subpath=$subpath;Mode=$mode;CacheMode=$cacheMode;CacheLimit=$cacheLimit;TotalSize=$totalSize;ReadOnly=($readOnly -eq 'y');Binary=$binary;Config=[IO.Path]::GetFullPath($config)}
    Assert-Profile $profile
    $archive = Join-Path $script:StoreRoot ('retained-' + $drive + '-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $dir) { Move-Item -LiteralPath $dir -Destination $archive; Write-Host "旧缓存已保留在 $archive，未删除。" }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-JsonFile (Join-Path $dir 'profile.json') $profile
    Write-Host ''
    Write-Host "  已保存：$drive`:  ←  $remote$subpath" -ForegroundColor Green
    Write-Host '  下一步：[3] 挂载；需要登录自启时选择 [6]。' -ForegroundColor Gray
}
function Select-Profile {
    Write-Heading '选择挂载配置'
    $dirs = @(Get-ChildItem -LiteralPath $script:StoreRoot -Directory | Where-Object { $_.Name -match '^[D-Z]$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'profile.json')) })
    if (!$dirs.Count) { throw '请先选择菜单 [2]，创建挂载设置（盘符/缓存）。' }
    foreach ($dir in $dirs) {
        $p = Get-Profile $dir.Name
        $modeName = if ($p.Mode -eq 'network') { '网络驱动器' } else { '固定磁盘' }
        Write-MenuItem $p.Drive ($p.Remote + $p.Subpath) ("$($p.Drive):  ·  $modeName")
    }
    return Get-Profile ((Read-Choice '选择盘符' $dirs[0].Name).ToUpperInvariant())
}
function Show-Status($Profile) {
    $runtime = Get-Runtime $Profile.Drive
    $process = Find-OwnedProcess $runtime
    $task = Get-Autostart $Profile.Drive
    $enabled = $task -and $task.Settings.Enabled
    Write-Heading ("$($Profile.Drive):  挂载状态")
    $modeName = if ($Profile.Mode -eq 'network') { '网络驱动器' } else { '固定磁盘' }
    $startupName = if ($enabled) { '已开启' } else { '已关闭' }
    $processName = if ($process) { '运行中' } else { '未运行' }
    Write-Host "  远端       $($Profile.Remote)$($Profile.Subpath)"
    Write-Host "  显示模式   $modeName"
    Write-Host "  挂载进程   $processName" -ForegroundColor $(if ($process) { 'Green' } else { 'Gray' })
    Write-Host "  登录自启   $startupName"
    Write-Host "  只读访问   $(if ($Profile.ReadOnly) { '是' } else { '否' })"
    Write-Host "  缓存模式   $($Profile.CacheMode)"
    Write-Host "  缓存上限   $($Profile.CacheLimit)（清理目标）"
    Write-Host "  显示容量   $($Profile.TotalSize)"
    if ($task) { $info = Get-ScheduledTaskInfo -TaskName $task.TaskName; Write-Host "  自启任务   $($task.State) · 上次返回码 $($info.LastTaskResult)" }
    if ($process) {
        $stats = Invoke-Control $runtime 'vfs/stats'
        Write-Host ''
        Write-Host '  文件活动' -ForegroundColor Cyan
        Write-Host "  打开句柄   $($stats.inUse)"
        if ($stats.diskCache) {
            Write-Host "  等待上传   $($stats.diskCache.uploadsQueued)"
            Write-Host "  正在上传   $($stats.diskCache.uploadsInProgress)"
            Write-Host "  上传失败   $($stats.diskCache.erroredFiles)"
        }
    }
    Write-Host ''
    Write-Host '  日志位置' -ForegroundColor Cyan
    Write-Host ('  ' + (Join-Path (Get-ProfileDir $Profile.Drive) 'mount.log')) -ForegroundColor Gray
}
function Remove-Profile($Profile) {
    Stop-Mount $Profile
    $task = Get-Autostart $Profile.Drive
    if ($task) {
        if ($task.Description -ne 'Managed by RcloneDriveManager') { throw '同名任务不是本脚本创建的，拒绝删除。' }
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
    }
    Remove-Item -LiteralPath (Join-Path (Get-ProfileDir $Profile.Drive) 'profile.json')
    Write-Host '已删除管理配置和自启任务；远端配置、缓存和日志均保留。'
}
function Show-Menu {
    while ($true) {
        Write-Heading ('rclone 磁盘管理 · v' + $script:Version)
        Write-Host '  首次使用：[9] 安装组件 → 配置远端 → 挂载设置 → 挂载' -ForegroundColor Gray
        Write-Host '  已有 omv 等远端？直接从 [2] 开始。' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  首次设置' -ForegroundColor Cyan
        Write-MenuItem '9' '组件安装管理' '安装、卸载或检查 rclone 和 WinFsp。'
        Write-MenuItem '1' '配置远端' '添加或修改服务器地址、账号和密码。'
        Write-MenuItem '2' '挂载设置' '选择远端，保存盘符、模式和缓存；暂不挂载。'
        Write-Host ''
        Write-Host '  挂载与状态' -ForegroundColor Cyan
        Write-MenuItem '3' '挂载' '启动磁盘，让盘符出现在资源管理器中。'
        Write-MenuItem '4' '卸载' '上传完成后断开磁盘，保留挂载设置。'
        Write-MenuItem '5' '状态' '查看磁盘是否运行、上传情况和自启状态。'
        Write-Host ''
        Write-Host '  登录自启' -ForegroundColor Cyan
        Write-MenuItem '6' '开启自启' '登录 Windows 后自动挂载选定磁盘。'
        Write-MenuItem '7' '关闭自启' '以后不再自动挂载，当前磁盘继续运行。'
        Write-Host ''
        Write-Host '  其他操作' -ForegroundColor Cyan
        Write-MenuItem '8' '删除挂载设置' '卸载并删除设置和自启；保留远端、缓存及日志。'
        Write-MenuItem '0' '退出' '关闭管理界面，已挂载磁盘继续运行。'
        Write-Host ''
        try {
            switch ((Read-Host '  输入操作编号').Trim()) {
                '9' { Show-ComponentMenu }
                '1' { & (Resolve-Rclone '') config }
                '2' { New-MountProfile }
                '3' { $p=Select-Profile; $null=Start-Mount $p; Write-Host '  已挂载，可以在资源管理器中访问。' -ForegroundColor Green }
                '4' { Stop-Mount (Select-Profile) }
                '5' { Show-Status (Select-Profile) }
                '6' { Set-Autostart (Select-Profile) $true }
                '7' { Set-Autostart (Select-Profile) $false }
                '8' { $p=Select-Profile; if ((Read-Choice '卸载并删除挂载设置（保留远端）？y/n' 'n') -eq 'y') { Remove-Profile $p } }
                '0' { return }
                default { Write-Host '  请输入菜单中的操作编号。' -ForegroundColor Yellow }
            }
        } catch { Write-Host ''; Write-Host ('  操作未完成：' + $_.Exception.Message) -ForegroundColor Yellow }
        Write-Host ''
        $null = Read-Host '  按回车返回主菜单'
    }
}
if (!$Library) {
    if ($env:OS -ne 'Windows_NT') { throw '初版只支持 Windows；JSON 配置格式可供后续 Linux 版本沿用。' }
    if (!$RunProfile) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '请使用普通权限 PowerShell，以免盘符对资源管理器不可见。' }
    }
    Initialize-Store
    if ($RunProfile) {
        try {
            $process = Start-Mount (Get-Profile $RunProfile)
            $process.WaitForExit()
            exit $process.ExitCode
        } catch {
            Add-Content -LiteralPath (Join-Path $script:StoreRoot 'startup-error.log') -Value ('{0:o} {1}' -f (Get-Date),$_.Exception.Message)
            exit 1
        }
    } else { Show-Menu }
}
