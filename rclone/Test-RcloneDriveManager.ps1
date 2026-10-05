#requires -Version 5.1
# All system mutations are mocked; file fixtures are confined to WorkRoot.
param([string]$WorkRoot = (Join-Path $PSScriptRoot '..\work\tests'), [switch]$Integration)
$ErrorActionPreference = 'Stop'
$WorkRoot = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('run-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$manager = Join-Path $PSScriptRoot 'RcloneDriveManager.ps1'
$errors = $null; $tokens = $null
$null = [Management.Automation.Language.Parser]::ParseFile($manager,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $manager -Library -StoreRoot (Join-Path $WorkRoot 'store')
$realResolve = ${function:Resolve-Rclone}
$realInvoke = ${function:Invoke-Control}
$realFind = ${function:Find-OwnedProcess}
$config = Join-Path $WorkRoot 'fake-rclone.conf'
'[example]' | Set-Content -LiteralPath $config
$script:passed = 0
function Check([string]$Name,[scriptblock]$Test) {
    & $Test
    $script:passed++
    Write-Output "PASS $Name"
}
function Assert($Value,[string]$Message='Assertion failed') { if (!$Value) { throw $Message } }
function Reject([scriptblock]$Code) {
    $rejected = $false
    try { & $Code | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Expected refusal'
}
function New-Fixture {
    return [pscustomobject]@{Drive='X';Remote='omv:';Subpath='';Mode='network';CacheMode='full';CacheLimit='20G';TotalSize='auto';ReadOnly=$false;Binary='C:\fake\rclone.exe';Config=$config}
}
Check 'Initialize store updates only access permissions and preserves owner (fixture only)' {
    New-Item -ItemType Directory -Path $script:StoreRoot -Force | Out-Null
    $ownerBefore = (Get-Acl -LiteralPath $script:StoreRoot).Owner
    Initialize-Store
    Initialize-Store
    $acl = Get-Acl -LiteralPath $script:StoreRoot
    Assert ($acl.Owner -eq $ownerBefore) 'Directory owner was changed'
    Assert $acl.AreAccessRulesProtected 'Access inheritance was not disabled'
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Assert ($rules.Count -eq 3) 'Unexpected access rules'
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($sid in @($userSid,'S-1-5-18','S-1-5-32-544')) {
        Assert (@($rules | Where-Object { $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' }).Count -eq 1) "Missing permission: $sid"
    }
    $probe = Join-Path $script:StoreRoot 'acl-probe.txt'
    'fixture-write' | Set-Content -LiteralPath $probe
    Assert ((Get-Content -LiteralPath $probe) -eq 'fixture-write')
}
Check 'Valid profile / argument injection boundary' {
    $p=New-Fixture; Assert-Profile $p
    $p.Drive='../X'; Reject { Assert-Profile $p }
    $p=New-Fixture; $p.Remote=':webdav,url=http://override:'; Reject { Assert-Profile $p }
    $p=New-Fixture; $p.CacheLimit='20G --bad'; Reject { Assert-Profile $p }
    $p=New-Fixture; $p.TotalSize='-1G'; Reject { Assert-Profile $p }
    $p=New-Fixture; $p.Subpath="bad`npath"; Reject { Assert-Profile $p }
    $p=New-Fixture; $p.Config=Join-Path $WorkRoot 'missing.conf'; Reject { Assert-Profile $p }
}
Check 'Network / fixed mode and exact remote path' {
    $p=New-Fixture; $p.Subpath='folder with space'
    $args=Build-MountArgs $p 12345 'test-token'
    Assert ($args[1] -eq 'omv:folder with space')
    Assert ($args -contains '--network-mode')
    Assert ($args -contains '127.0.0.1:12345')
    Assert ($args -notcontains '--rc-no-auth')
    Assert ($args -notcontains '--vfs-used-is-size')
    $p.Mode='fixed'; Assert ((Build-MountArgs $p 12345 'token') -notcontains '--network-mode')
}
Check 'Capacity auto/custom and read-only options' {
    $p=New-Fixture; Assert ((Build-MountArgs $p 12345 'token') -notcontains '--vfs-disk-space-total-size')
    $p.TotalSize='2T'; $p.ReadOnly=$true; $args=Build-MountArgs $p 12345 'token'
    Assert ($args -contains '--vfs-disk-space-total-size'); Assert ($args -contains '2T'); Assert ($args -contains '--read-only')
    foreach($mode in @('full','writes','off')) { $p.CacheMode=$mode; Assert ((Build-MountArgs $p 12345 'token') -contains $mode) }
}
Check 'Windows quoting round-trip with real CommandLineToArgvW' {
    if (!('RDMTest.Argv' -as [type])) {
        Add-Type 'using System; using System.Runtime.InteropServices; namespace RDMTest { public static class Argv { [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string cmd, out int argc); [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p); public static string[] Parse(string cmd) { int n; var p=CommandLineToArgvW(cmd,out n); if(p==IntPtr.Zero) throw new Exception("parse failed"); try { var a=new string[n]; for(int i=0;i<n;i++) a[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,i*IntPtr.Size)); return a; } finally { LocalFree(p); } } } }'
    }
    $values=@('', 'folder with spaces', 'C:\folder with space\', 'embedded"quote', 'before\\"after', 'omv:中文目录', 'http://unchanged')
    $line='dummy.exe ' + (($values | ForEach-Object { Quote-NativeArg $_ }) -join ' ')
    $parsed=[RDMTest.Argv]::Parse($line)
    Assert ($parsed.Length -eq $values.Count+1)
    for($i=0;$i -lt $values.Count;$i++){Assert ($parsed[$i+1] -ceq $values[$i]) "Quote roundtrip failed at $i"}
}
Check 'Profile persistence and isolated drive paths' {
    $p=New-Fixture; $dir=Get-ProfileDir 'X'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-JsonFile (Join-Path $dir 'profile.json') $p
    $read=Get-Profile 'X'; Assert ($read.Remote -eq 'omv:'); Assert ($read.TotalSize -eq 'auto')
    Reject { Get-ProfileDir '..\X' }
}
Check 'DPAPI secret round-trip (current user only)' {
    $token=Protect-ControlSecret 'temporary-test-token'
    Assert ($token -ne 'temporary-test-token')
    $credential=New-Object Management.Automation.PSCredential('test',(ConvertTo-SecureString $token))
    Assert ($credential.GetNetworkCredential().Password -eq 'temporary-test-token')
}
Check 'Safe unmount blocks handles, queued/active/failed uploads and unknown stats' {
    $safe=[pscustomobject]@{inUse=0;diskCache=[pscustomobject]@{uploadsQueued=0;uploadsInProgress=0;erroredFiles=0}}
    Assert-SafeToUnmount $safe
    foreach($field in @('uploadsQueued','uploadsInProgress','erroredFiles')) {
        $safe.diskCache.$field=1; Reject { Assert-SafeToUnmount $safe }; $safe.diskCache.$field=0
    }
    $safe.inUse=1; Reject { Assert-SafeToUnmount $safe }
    Reject { Assert-SafeToUnmount $null }
    Reject { Assert-SafeToUnmount ([pscustomobject]@{inUse=0}) }
}
# Replace every OS boundary before exercising actions. No real processes/tasks/registry writes.
$script:mockRuntime=[pscustomobject]@{ProcessId=123;StartTicks='1';Binary='fake';Port=12345;Secret='fake'}
$script:owned=$null; $script:occupied=$false; $script:task=$null; $script:controlCalls=@(); $script:refreshes=0
$script:stats=[pscustomobject]@{inUse=0;diskCache=[pscustomobject]@{uploadsQueued=0;uploadsInProgress=0;erroredFiles=0}}
function Get-Runtime { return $script:mockRuntime }
function Find-OwnedProcess { return $script:owned }
function Get-PSDrive { param($Name,$ErrorAction); if($script:occupied){return [pscustomobject]@{Name=$Name}} }
function Invoke-Control { param($Runtime,$Method,$Body); $script:controlCalls += $Method; if($Method -eq 'vfs/stats'){return $script:stats}; return @{} }
function Refresh-Explorer { param($Drive,$NetworkMode); $script:refreshes++ }
function Get-Autostart { return $script:task }
function Disable-ScheduledTask { param($TaskName); $script:disabled=$TaskName }
function Get-ScheduledTaskInfo { return [pscustomobject]@{LastTaskResult=0} }
function New-ScheduledTaskAction { param($Execute,$Argument); return [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User); return [pscustomobject]@{User=$User;Delay=''} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit,$RestartCount,$RestartInterval,$MultipleInstances,[switch]$StartWhenAvailable)
    return [pscustomobject]@{ExecutionTimeLimit=$ExecutionTimeLimit;RestartCount=$RestartCount;RestartInterval=$RestartInterval;MultipleInstances=$MultipleInstances}
}
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,[switch]$Force); $script:registered=$PSBoundParameters }
function Unregister-ScheduledTask { param($TaskName,$Confirm); $script:unregistered=$TaskName }
Check 'Already-running mount is idempotent; occupied foreign drive is refused' {
    $script:owned=[pscustomobject]@{Id=123}; Assert ((Start-MountCore (New-Fixture)).Id -eq 123)
    $script:owned=$null; $script:occupied=$true; Reject { Start-MountCore (New-Fixture) }; $script:occupied=$false
}
Check 'Mocked successful startup records ownership; early exit is reported without force kill' {
    function Get-Service { param($Name,$ErrorAction); return [pscustomobject]@{Name='WinFsp.Launcher'} }
    function Resolve-Rclone { return 'C:\fake\rclone.exe' }
    function New-ControlPort { return 12345 }
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
        $script:spawnArgs=$ArgumentList
        $script:occupied=$true
        $fake=[pscustomobject]@{Id=987654;StartTime=(Get-Date);HasExited=$script:earlyExit}
        $fake | Add-Member ScriptMethod Refresh { }
        return $fake
    }
    $script:earlyExit=$false
    $result=Start-MountCore (New-Fixture)
    Assert ($result.Id -eq 987654)
    $runtimePath=Join-Path (Get-ProfileDir 'X') 'runtime.json'
    $saved=Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
    Assert ($saved.ProcessId -eq 987654); Assert ($saved.Port -eq 12345); Assert ($saved.Secret -ne 'fake')
    Assert ($script:spawnArgs.Contains('"X:"')); Assert ($script:spawnArgs.Contains('--network-mode'))
    $script:occupied=$false; $script:earlyExit=$true; Reject { Start-MountCore (New-Fixture) }
    $script:occupied=$false
}
Check 'Graceful unmount uses authenticated control and no force kill' {
    $script:owned=[pscustomobject]@{Id=123}; $script:owned | Add-Member ScriptMethod WaitForExit { param($Timeout); return $true }
    $script:controlCalls=@(); Stop-Mount (New-Fixture)
    Assert (($script:controlCalls -join ',') -eq 'vfs/stats,core/quit'); Assert ($script:refreshes -eq 1)
    $script:stats.diskCache.uploadsQueued=1; $script:controlCalls=@(); Reject { Stop-Mount (New-Fixture) }
    Assert ($script:controlCalls -notcontains 'core/quit'); $script:stats.diskCache.uploadsQueued=0
    $script:owned=$null
}
Check 'Unmount refuses foreign mount and retains caches' {
    $script:occupied=$true; Reject { Stop-Mount (New-Fixture) }; $script:occupied=$false
    $cache=Join-Path (Get-ProfileDir 'X') 'cache'; New-Item -ItemType Directory -Path $cache -Force | Out-Null
    'retain' | Set-Content -LiteralPath (Join-Path $cache 'pending.bin')
    Stop-Mount (New-Fixture); Assert (Test-Path -LiteralPath (Join-Path $cache 'pending.bin'))
}
Check 'Autostart register settings / encoded path / disabling without stopping mount' {
    Set-Autostart (New-Fixture) $true
    Assert ($script:registered.Trigger.Delay -eq 'PT20S')
    Assert ($script:registered.Principal.RunLevel -eq 'Limited')
    Assert ($script:registered.Principal.LogonType -eq 'Interactive')
    Assert ($script:registered.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero)
    Assert ($script:registered.Settings.RestartCount -eq 10)
    Assert ($script:registered.Settings.MultipleInstances -eq 'IgnoreNew')
    Assert ($script:registered.Action.Execute -like '*\wscript.exe')
    Assert ($script:registered.Action.Arguments.StartsWith('//B //NoLogo '))
    $launcher = Get-Content -LiteralPath (Join-Path (Get-ProfileDir 'X') 'autostart.vbs') -Raw
    Assert ($launcher.Contains('WScript.Quit result')) 'Launcher must propagate the child exit code'
    Assert ($launcher -match 'result = shell.Run\("((?:""|[^"])*)", 0, True\)') 'Launcher must hide and wait for its child'
    $childCommand = $matches[1].Replace('""','"')
    $encoded=([RDMTest.Argv]::Parse($childCommand))[-1]
    $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    Assert ($decoded.Contains("-RunProfile 'X'")); Assert ($decoded.Contains('-StoreRoot'))
    $parseErrors=$null; $t=$null; $null=[Management.Automation.Language.Parser]::ParseInput($decoded,[ref]$t,[ref]$parseErrors); Assert (!$parseErrors.Count)
    $script:task=[pscustomobject]@{TaskName='RcloneDriveManager-X';Description='Managed by RcloneDriveManager'}
    $script:disabled=$null; $script:controlCalls=@(); Set-Autostart (New-Fixture) $false
    Assert ($script:disabled -eq 'RcloneDriveManager-X'); Assert ($script:controlCalls.Count -eq 0)
    $script:task.Description='other software'; Reject { Set-Autostart (New-Fixture) $false }; Reject { Set-Autostart (New-Fixture) $true }
    $script:task=$null
}
Check 'Interactive creation validates input and does not mount or enable startup' {
    function Resolve-Rclone { return 'C:\fake\rclone.exe' }
    function Get-RcloneConfig { return $config }
    function Get-RemoteNames { return @('omv:','second:') }
    $script:responses=New-Object Collections.Queue
    foreach($answer in @('auto',$config,'2','documents','Y','fixed','writes','10G','2T','y')) { $script:responses.Enqueue($answer) }
    function Read-Choice { return $script:responses.Dequeue() }
    New-MountProfile
    $p=Get-Profile 'Y'; Assert ($p.Remote -eq 'second:'); Assert ($p.Subpath -eq 'documents'); Assert ($p.Mode -eq 'fixed'); Assert ($p.TotalSize -eq '2T'); Assert $p.ReadOnly
    Assert (!(Test-Path -LiteralPath (Join-Path (Get-ProfileDir 'Y') 'runtime.json')))
}
Check 'Delete managed profile/task leaves remote config and cache untouched' {
    $script:task=[pscustomobject]@{TaskName='RcloneDriveManager-X';Description='Managed by RcloneDriveManager'}
    Remove-Profile (New-Fixture)
    Assert (!(Test-Path -LiteralPath (Join-Path (Get-ProfileDir 'X') 'profile.json')))
    Assert (Test-Path -LiteralPath (Join-Path (Get-ProfileDir 'X') 'cache\pending.bin'))
    Assert (Test-Path -LiteralPath $config)
    Assert ($script:unregistered -eq 'RcloneDriveManager-X')
}
Check 'Component package allowlist, exact winget arguments and HRESULT handling' {
    $fakeWinget = Join-Path $WorkRoot 'winget-fixture.ps1'
    @'
$global:rdmTestWingetArguments = @($args)
$global:LASTEXITCODE = $global:rdmTestWingetExitCode
'@ | Set-Content -LiteralPath $fakeWinget -Encoding UTF8
    function Resolve-Winget { return $fakeWinget }
    function Assert-ComponentsIdle { $script:idleChecks++ }
    $global:rdmTestWingetExitCode=0; $script:idleChecks=0
    Invoke-ComponentAction install 'Rclone.Rclone'
    Assert (($global:rdmTestWingetArguments -join ' ') -eq 'install --id Rclone.Rclone --exact --source winget --accept-source-agreements --disable-interactivity --accept-package-agreements')
    Invoke-ComponentAction uninstall 'WinFsp.WinFsp'
    Assert ($script:idleChecks -eq 1)
    Assert ($global:rdmTestWingetArguments -notcontains '--accept-package-agreements')
    Assert ($global:rdmTestWingetArguments[2] -eq 'WinFsp.WinFsp')
    Reject { Invoke-ComponentAction install 'untrusted.package' }
    $global:rdmTestWingetExitCode=-1978335189 # 0x8A15002B: no applicable upgrade
    Invoke-ComponentAction install 'Rclone.Rclone'
    Reject { Invoke-ComponentAction uninstall 'Rclone.Rclone' }
    $global:rdmTestWingetExitCode=-1978335212 # 0x8A150014: no installed package
    Invoke-ComponentAction uninstall 'Rclone.Rclone'
    Reject { Invoke-ComponentAction install 'Rclone.Rclone' }
    $global:rdmTestWingetExitCode=1; Reject { Invoke-ComponentAction install 'WinFsp.WinFsp' }
    function Assert-ComponentsIdle { throw 'fixture: active mount' }
    $global:rdmTestWingetArguments=@(); Reject { Invoke-ComponentAction uninstall 'Rclone.Rclone' }
    Assert ($global:rdmTestWingetArguments.Count -eq 0) 'Uninstall reached winget despite unsafe state'
}
Check 'Component uninstall refuses active processes and enabled managed tasks, fails closed' {
    function Get-Process { param($Name,$ErrorAction); return $script:componentProcess }
    function Get-ScheduledTask { param($ErrorAction); if($script:taskQueryFails){throw 'fixture: task query denied'}; return $script:componentTasks }
    $script:componentProcess=[pscustomobject]@{Id=123}
    Reject { Assert-ComponentsIdle }
    $script:componentProcess=$null
    $script:componentTasks=@([pscustomobject]@{Description='Managed by RcloneDriveManager';Settings=[pscustomobject]@{Enabled=$true}})
    Reject { Assert-ComponentsIdle }
    $script:componentTasks[0].Settings.Enabled=$false; Assert-ComponentsIdle
    $script:componentTasks[0].Description='Other application'; $script:componentTasks[0].Settings.Enabled=$true; Assert-ComponentsIdle
    $script:taskQueryFails=$true; Reject { Assert-ComponentsIdle }
}
if ($Integration) {
    Check 'Actual hidden launcher waits for harmless child and propagates failure code (fixture only)' {
        $marker = Join-Path $WorkRoot 'hidden-launcher-marker.txt'
        $child = "[IO.File]::WriteAllText('" + $marker.Replace("'","''") + "','fixture-only'); exit 7"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $line = (Quote-NativeArg $powershell) + ' -NoProfile -NonInteractive -EncodedCommand ' + $encoded
        $launcher = Join-Path $WorkRoot 'hidden-launcher-test.vbs'
        Build-HiddenLauncher $line (Join-Path $WorkRoot 'launcher-error.log') | Set-Content -LiteralPath $launcher -Encoding Unicode
        $runner = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('//B //NoLogo ' + (Quote-NativeArg $launcher)) -WindowStyle Hidden -PassThru
        try {
            Assert ($runner.WaitForExit(10000)) 'Hidden launcher timed out'
            Assert ($runner.ExitCode -eq 7) 'Child failure did not reach task scheduler'
            Assert ((Get-Content -LiteralPath $marker) -eq 'fixture-only') 'Child was not launched'
        } finally { $runner.Refresh(); if (!$runner.HasExited) { Stop-Process -Id $runner.Id -ErrorAction SilentlyContinue } }
    }
    Check 'Actual rclone flags, authenticated localhost RC and graceful process exit (no mount)' {
        $binary = & $realResolve ''
        $help = (& $binary mount --help) -join "`n"
        foreach($flag in @('--vfs-disk-space-total-size','--network-mode','--vfs-cache-mode')) { Assert ($help.Contains($flag)) "Unsupported flag: $flag" }
        $port = New-ControlPort
        $token = [Guid]::NewGuid().ToString('N')
        $arguments = @('rcd','--config',$config,'--rc-addr',('127.0.0.1:'+$port),'--rc-user','mount-manager','--rc-pass',$token,'--log-file',(Join-Path $WorkRoot 'rc-test.log'))
        $line = ($arguments | ForEach-Object { Quote-NativeArg $_ }) -join ' '
        $server = Start-Process -FilePath $binary -ArgumentList $line -WindowStyle Hidden -PassThru
        try {
            $runtime=[pscustomobject]@{ProcessId=$server.Id;StartTicks=$server.StartTime.ToUniversalTime().Ticks.ToString();Binary=$binary;Port=$port;Secret=(Protect-ControlSecret $token)}
            $ready=$false
            for($i=0;$i -lt 30;$i++) {
                try { $reply=& $realInvoke $runtime 'rc/noopauth' @{marker='fixture-only'}; $ready=($reply.marker -eq 'fixture-only'); if($ready){break} } catch { }
                Start-Sleep -Milliseconds 200
            }
            Assert $ready 'Local RC authentication did not succeed'
            Assert ((& $realFind $runtime).Id -eq $server.Id)
            $badRuntime=$runtime.PSObject.Copy(); $badRuntime.StartTicks='0'; Reject { & $realFind $badRuntime }
            $badRuntime=$runtime.PSObject.Copy(); $badRuntime.Binary='C:\wrong.exe'; Reject { & $realFind $badRuntime }
            $null = & $realInvoke $runtime 'core/quit' @{exitCode=0}
            Assert ($server.WaitForExit(5000)) 'Graceful quit timed out'
            Assert ($server.ExitCode -eq 0) 'Unexpected quit exit code'
        } finally {
            $server.Refresh()
            if (!$server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
        }
    }
}
Write-Output "All $script:passed test groups passed. No real mount, task or remote configuration was modified."
