# Pester 3.4 tests for agent\Install-TestRigAgent.ps1.
# Run:  powershell -NoProfile -Command "Invoke-Pester <repo>\tests\agent"
# The ScheduledTasks cmdlets are mocked: nothing is registered, copied outside TestDrive, or started.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'agent\Install-TestRigAgent.ps1'

function New-PolicyList {
    # Shape of Get-ExecutionPolicy -List.
    param([string]$MachinePolicy = 'Undefined', [string]$UserPolicy = 'Undefined', [string]$Process = 'Undefined',
        [string]$CurrentUser = 'Undefined', [string]$LocalMachine = 'Undefined')
    return @(
        [pscustomobject]@{ Scope = 'MachinePolicy'; ExecutionPolicy = $MachinePolicy },
        [pscustomobject]@{ Scope = 'UserPolicy'; ExecutionPolicy = $UserPolicy },
        [pscustomobject]@{ Scope = 'Process'; ExecutionPolicy = $Process },
        [pscustomobject]@{ Scope = 'CurrentUser'; ExecutionPolicy = $CurrentUser },
        [pscustomobject]@{ Scope = 'LocalMachine'; ExecutionPolicy = $LocalMachine }
    )
}

Describe 'Install-TestRigAgent' {
    Mock Write-Host { }
    Mock Write-Warning { }
    # The New-ScheduledTask* cmdlets run for real (in-memory CIM objects); only the registration is mocked.
    Mock Register-ScheduledTask { }
    Mock Stop-ScheduledTask { }
    Mock Start-ScheduledTask { }
    Mock Get-ExecutionPolicy { return (New-PolicyList -LocalMachine 'RemoteSigned') }

    It 'registers an at-logon, interactive, limited task with priority 4, restarts and no time limit' {
        $root = Join-Path $TestDrive 'install1'
        & $installer -InstallRoot $root
        Test-Path (Join-Path $root 'TestRigAgent.ps1') | Should Be $true
        Assert-MockCalled Register-ScheduledTask -Exactly -Times 1 -ParameterFilter {
            $TaskName -eq 'BannerlordTestRigAgent' -and
            @($Trigger)[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and
            $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited' -and
            $Settings.Priority -eq 4 -and $Settings.RestartCount -eq 3 -and $Settings.RestartInterval -eq 'PT1M' -and
            $Settings.ExecutionTimeLimit -eq 'PT0S'
        }
    }

    It 'does not stop or start the task without -Restart and says a running agent keeps the old script' {
        & $installer -InstallRoot (Join-Path $TestDrive 'install2')
        Assert-MockCalled Stop-ScheduledTask -Exactly -Times 0
        Assert-MockCalled Start-ScheduledTask -Exactly -Times 0
        Assert-MockCalled Write-Host -ParameterFilter { $Object -match 'old script' }
    }

    It 'stops and starts the task with -Restart' {
        & $installer -InstallRoot (Join-Path $TestDrive 'install3') -Restart
        Assert-MockCalled Stop-ScheduledTask -Exactly -Times 1 -ParameterFilter { $TaskName -eq 'BannerlordTestRigAgent' }
        Assert-MockCalled Start-ScheduledTask -Exactly -Times 1 -ParameterFilter { $TaskName -eq 'BannerlordTestRigAgent' }
    }

    It 'warns when the effective policy (without the Process scope) is Restricted' {
        $global:InstallWarnings = New-Object System.Collections.ArrayList
        Mock Write-Warning { [void]$global:InstallWarnings.Add([string]$Message) }
        Mock Get-ExecutionPolicy { return (New-PolicyList -Process 'Bypass' -CurrentUser 'Restricted' -LocalMachine 'RemoteSigned') }
        & $installer -InstallRoot (Join-Path $TestDrive 'install4')
        $global:InstallWarnings.Count | Should Be 1
        $global:InstallWarnings[0] | Should Match 'Restricted'
    }

    It 'treats all-Undefined as Restricted and warns' {
        $global:InstallWarnings = New-Object System.Collections.ArrayList
        Mock Write-Warning { [void]$global:InstallWarnings.Add([string]$Message) }
        Mock Get-ExecutionPolicy { return (New-PolicyList -Process 'Bypass') }
        & $installer -InstallRoot (Join-Path $TestDrive 'install5')
        $global:InstallWarnings.Count | Should Be 1
        $global:InstallWarnings[0] | Should Match 'Restricted'
    }

    It 'lets a machine policy override a permissive user scope' {
        $global:InstallWarnings = New-Object System.Collections.ArrayList
        Mock Write-Warning { [void]$global:InstallWarnings.Add([string]$Message) }
        Mock Get-ExecutionPolicy { return (New-PolicyList -MachinePolicy 'AllSigned' -CurrentUser 'RemoteSigned') }
        & $installer -InstallRoot (Join-Path $TestDrive 'install6')
        $global:InstallWarnings.Count | Should Be 1
        $global:InstallWarnings[0] | Should Match 'AllSigned'
    }

    It 'does not warn when the effective policy is permissive although Process is Restricted' {
        $global:InstallWarnings = New-Object System.Collections.ArrayList
        Mock Write-Warning { [void]$global:InstallWarnings.Add([string]$Message) }
        Mock Get-ExecutionPolicy { return (New-PolicyList -Process 'Restricted' -LocalMachine 'RemoteSigned') }
        & $installer -InstallRoot (Join-Path $TestDrive 'install7')
        $global:InstallWarnings.Count | Should Be 0
    }
}
