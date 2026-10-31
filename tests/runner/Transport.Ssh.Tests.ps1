$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\..\runner\Transport.Ssh.ps1')
. (Join-Path $here 'RemoteHarness.ps1')

$script:target = [pscustomobject]@{
    host            = 'testpc'
    user            = 'rig'
    keyPath         = 'C:\keys\rig_ed25519'
    remoteQueueRoot = 'C:\TestRig\queue'
}
$script:jobId = '20261031-153000-a1b2'

function Get-DecodedCommand([string]$Command) {
    # "powershell -NoProfile -EncodedCommand <b64>" -> script text
    $b64 = ($Command -split ' ')[-1]
    [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
}

Describe 'ConvertTo-EncodedCommand' {
    It 'round-trips UTF-16LE base64 including non-ASCII and quotes' {
        $text = "Write-Output 'h' + `"ue`" # " + [char]0x00FC + [char]0x20AC
        $enc = ConvertTo-EncodedCommand -Script $text
        $enc | Should Match '^[A-Za-z0-9+/=]+$'
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc)) | Should Be $text
    }
}

Describe 'Select-SshStderrLine' {
    It 'drops post-quantum warning lines and blanks, keeps real errors' {
        $lines = @(
            '** WARNING: connection is not using a post-quantum key exchange algorithm.',
            '** This session may be vulnerable to "store now, decrypt later" attacks.',
            '',
            'Permission denied (publickey).')
        $r = @(Select-SshStderrLine -Line $lines)
        $r.Count | Should Be 1
        $r[0] | Should Be 'Permission denied (publickey).'
    }
}

Describe 'Invoke-RigSsh / Invoke-RigScp (native tool stubs)' {
    # The function stubs below stand in for the native tools; the resolver returns their names.
    BeforeEach { $script:nativeArgs = $null; Mock Get-RigOpenSshTool { $Name } }

    It 'passes BatchMode, ConnectTimeout, keepalive, IdentitiesOnly, key and user@host to ssh and returns stdout' {
        function ssh { $script:nativeArgs = $args; $global:LASTEXITCODE = 0; 'out1' }
        $r = @(Invoke-RigSsh -Target $script:target -Command 'echo hi')
        $r[0] | Should Be 'out1'
        ($script:nativeArgs -join ' ') | Should Be '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i C:\keys\rig_ed25519 rig@testpc echo hi'
    }

    It 'does not treat PQ warnings on stderr as errors when exit code is 0' {
        function ssh {
            $global:LASTEXITCODE = 0
            Write-Error '** WARNING: connection is not using a post-quantum key exchange algorithm.' -ErrorAction Continue
            'payload'
        }
        $r = @(Invoke-RigSsh -Target $script:target -Command 'x')
        $r.Count | Should Be 1
        $r[0] | Should Be 'payload'
    }

    It 'throws a transport error with filtered stderr on non-zero exit' {
        function ssh {
            $global:LASTEXITCODE = 255
            Write-Error '** WARNING: pq' -ErrorAction Continue
            Write-Error 'Connection timed out' -ErrorAction Continue
        }
        $msg = ''
        try { Invoke-RigSsh -Target $script:target -Command 'x' } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'exit 255'
        $msg | Should Match 'Connection timed out'
        $msg | Should Not Match 'WARNING: pq'
    }

    It 'scp uses the same options and throws on non-zero exit' {
        function scp { $script:nativeArgs = $args; $global:LASTEXITCODE = 1 }
        { Invoke-RigScp -Target $script:target -Source 'a' -Destination 'b' -Recurse } | Should Throw
        ($script:nativeArgs -join ' ') | Should Be '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i C:\keys\rig_ed25519 -r a b'
    }
}

Describe 'Publish-Job' {
    BeforeEach {
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('rigpub-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:dir 'package.zip') -Value 'z'
        Set-Content -LiteralPath (Join-Path $script:dir 'job.json') -Value '{}'
        $script:ops = New-Object System.Collections.ArrayList
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the folder, copies zip then job.json.tmp, then renames (job.json last)' {
        Mock Invoke-RigSsh { [void]$script:ops.Add("ssh:$Command"); @() }
        Mock Invoke-RigScp { [void]$script:ops.Add("scp:$Destination"); }
        Publish-Job -Target $script:target -JobId $script:jobId -JobDirectory $script:dir
        $script:ops.Count | Should Be 4
        $mk = Get-DecodedCommand ($script:ops[0] -replace '^ssh:', '')
        $mk | Should Match 'CreateDirectory\(''C:\\TestRig\\queue\\jobs\\20261031-153000-a1b2''\)'
        $script:ops[1] | Should Be 'scp:rig@testpc:C:/TestRig/queue/jobs/20261031-153000-a1b2/package.zip'
        $script:ops[2] | Should Be 'scp:rig@testpc:C:/TestRig/queue/jobs/20261031-153000-a1b2/job.json.tmp'
        $ren = Get-DecodedCommand ($script:ops[3] -replace '^ssh:', '')
        $ren | Should Match 'Rename-Item -LiteralPath ''C:\\TestRig\\queue\\jobs\\20261031-153000-a1b2\\job\.json\.tmp'' -NewName ''job\.json'''
        $ren | Should Not Match '-Force'
    }
}

Describe 'Remote scripts fail loudly' {
    It 'wraps every script: ErrorActionPreference Stop and exit 1 on error' {
        $script:sent = $null
        Mock Invoke-RigSsh { $script:sent = $Command; @() }
        Invoke-RigRemoteScript -Target $script:target -Script 'Get-Date' | Out-Null
        $d = Get-DecodedCommand $script:sent
        $d | Should Match "ErrorActionPreference = 'Stop'"
        $d | Should Match 'catch \{[^}]*exit 1'
    }
}

Describe 'Get-RigOpenSshTool' {
    BeforeEach { $script:RigToolPaths = @{}; $script:origRoot = $env:SystemRoot }
    AfterEach { $env:SystemRoot = $script:origRoot; $script:RigToolPaths = @{} }

    It 'resolves to the Windows OpenSSH binaries under SystemRoot, not PATH' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('rigtool-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'System32\OpenSSH') -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $root 'System32\OpenSSH\ssh.exe') -Value 'x'
            Set-Content -LiteralPath (Join-Path $root 'System32\OpenSSH\scp.exe') -Value 'x'
            $env:SystemRoot = $root
            Get-RigOpenSshTool -Name ssh | Should Be (Join-Path $root 'System32\OpenSSH\ssh.exe')
            Get-RigOpenSshTool -Name scp | Should Be (Join-Path $root 'System32\OpenSSH\scp.exe')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'throws a clear transport error when the client is missing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('rigtool-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $env:SystemRoot = $root
            $msg = ''
            try { Get-RigOpenSshTool -Name ssh } catch { $msg = $_.Exception.Message }
            $msg | Should Match 'Windows OpenSSH client not found'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Native arguments (PS 5.1 mangles quotes, MSYS ssh eats backslashes)' {
    BeforeEach {
        $script:calls = New-Object System.Collections.ArrayList
        Mock Get-RigOpenSshTool { "C:\fake\$Name.exe" }
        Mock Invoke-RigNative {
            [void]$script:calls.Add([pscustomobject]@{ Tool = $Tool; Arguments = @($Arguments) })
            # a successful scp -r creates <destination>\<jobId>
            if ($Tool -match 'scp' -and $Arguments -contains '-r') { $null = New-Item -ItemType Directory -Path (Join-Path $Arguments[-1] $script:jobId) -Force }
            '{"jobJson":false,"claimed":false,"withdrawn":true,"state":null,"done":false,"open":[]}'
        }
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('rigarg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:dir 'package.zip') -Value 'z'
        Set-Content -LiteralPath (Join-Path $script:dir 'job.json') -Value '{}'
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    function Assert-ssh-args-clean([int]$MinSsh = 1) {
        $ssh = @($script:calls | Where-Object { $_.Tool -match '(^|[\\/])ssh(\.exe)?$' })
        $ssh.Count | Should Not BeLessThan $MinSsh
        foreach ($c in $ssh) {
            # The key path is a local Windows path for ssh itself; everything else must be free of " and \.
            foreach ($a in @($c.Arguments | Where-Object { $_ -ne $script:target.keyPath })) {
                $a | Should Not Match '["\\]'
            }
        }
        foreach ($c in @($script:calls | Where-Object { $_.Tool -match '(^|[\\/])scp(\.exe)?$' })) {
            foreach ($a in $c.Arguments) { $a | Should Not Match '"' }
        }
    }

    It 'Invoke-RigSsh rejects a command with " or \' {
        { Invoke-RigSsh -Target $script:target -Command 'mkdir "C:\a b"' } | Should Throw
        Assert-MockCalled Invoke-RigNative -Times 0
    }
    It 'Publish-Job' {
        Publish-Job -Target $script:target -JobId $script:jobId -JobDirectory $script:dir
        Assert-ssh-args-clean
    }
    It 'Get-JobState (job)' {
        Get-JobState -Target $script:target -JobId $script:jobId | Out-Null
        Assert-ssh-args-clean
    }
    It 'Get-JobState (-OpenJobs)' {
        @(Get-JobState -Target $script:target -OpenJobs) | Out-Null
        Assert-ssh-args-clean
    }
    It 'Send-JobAbort' {
        Send-JobAbort -Target $script:target -JobId $script:jobId
        Assert-ssh-args-clean
    }
    It 'Send-JobAbort -Withdraw' {
        Send-JobAbort -Target $script:target -JobId $script:jobId -Withdraw | Out-Null
        Assert-ssh-args-clean
    }
    It 'Receive-JobResult' {
        $root = Join-Path $script:dir 'res'
        Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $root | Out-Null
        Assert-ssh-args-clean -MinSsh 0
        $scp = @($script:calls | Where-Object { $_.Tool -match '(^|[\\/])scp(\.exe)?$' })
        $scp.Count | Should Be 1
    }
    It 'passes local Windows paths to scp unchanged' {
        Publish-Job -Target $script:target -JobId $script:jobId -JobDirectory $script:dir
        $scp = @($script:calls | Where-Object { $_.Tool -match '(^|[\\/])scp(\.exe)?$' })
        ($scp[0].Arguments -contains (Join-Path $script:dir 'package.zip')) | Should Be $true
        ($scp[1].Arguments -contains (Join-Path $script:dir 'job.json')) | Should Be $true
    }
}

Describe 'Publish-Job input validation' {
    It 'rejects a malformed jobId before any remote call' {
        Mock Invoke-RigSsh { }
        Mock Invoke-RigScp { }
        $d = Join-Path ([IO.Path]::GetTempPath()) ('rigval-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $d 'package.zip') -Value 'z'
            Set-Content -LiteralPath (Join-Path $d 'job.json') -Value '{}'
            { Publish-Job -Target $script:target -JobId 'x& calc' -JobDirectory $d } | Should Throw
        } finally { Remove-Item -LiteralPath $d -Recurse -Force }
        Assert-MockCalled Invoke-RigSsh -Times 0
        Assert-MockCalled Invoke-RigScp -Times 0
    }
}

Describe 'Get-JobState' {
    It 'is one round trip and parses the JSON result' {
        $script:sent = $null
        Mock Invoke-RigSsh {
            $script:sent = $Command
            '{"jobJson":false,"claimed":true,"withdrawn":false,"state":{"beat":7,"state":"running"},"done":false}'
        }
        $s = Get-JobState -Target $script:target -JobId $script:jobId
        Assert-MockCalled Invoke-RigSsh -Times 1
        $s.claimed | Should Be $true
        $s.jobJson | Should Be $false
        $s.done | Should Be $false
        $s.state.beat | Should Be 7
        (Get-DecodedCommand $script:sent) | Should Match '20261031-153000-a1b2'
    }

    It 'returns state = null when state.json is absent' {
        Mock Invoke-RigSsh { '{"jobJson":true,"claimed":false,"withdrawn":false,"state":null,"done":false}' }
        $s = Get-JobState -Target $script:target -JobId $script:jobId
        $s.state | Should BeNullOrEmpty
        $s.jobJson | Should Be $true
    }

    It 'lists open jobs with -OpenJobs' {
        Mock Invoke-RigSsh { '{"open":["20261031-153000-a1b2","20261031-160000-ffff"]}' }
        $r = @(Get-JobState -Target $script:target -OpenJobs)
        $r.Count | Should Be 2
        $r[0] | Should Be '20261031-153000-a1b2'
    }

    It 'returns an empty list when nothing is open' {
        Mock Invoke-RigSsh { '{"open":[]}' }
        @(Get-JobState -Target $script:target -OpenJobs).Count | Should Be 0
    }

    It 'throws on unparsable remote output' {
        Mock Invoke-RigSsh { 'garbage' }
        { Get-JobState -Target $script:target -JobId $script:jobId } | Should Throw
    }
}

Describe 'Send-JobAbort' {
    It 'creates the abort file' {
        $script:sent = $null
        Mock Invoke-RigSsh { $script:sent = $Command; @() }
        Send-JobAbort -Target $script:target -JobId $script:jobId
        $d = Get-DecodedCommand $script:sent
        $d | Should Match 'abort'
        $d | Should Match '20261031-153000-a1b2'
    }

    It '-Withdraw returns { withdrawn, jobJsonPresent, claimed } as booleans' {
        Mock Invoke-RigSsh { '{"withdrawn":false,"jobJsonPresent":true,"claimed":false}' }
        $r = Send-JobAbort -Target $script:target -JobId $script:jobId -Withdraw
        $r.withdrawn | Should Be $false
        $r.jobJsonPresent | Should Be $true
        $r.claimed | Should Be $false
    }
}

Describe 'Receive-JobResult' {
    BeforeEach {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ('rigrec-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'copies the results folder recursively into the destination root' {
        Mock Invoke-RigScp {
            $script:src = $Source; $script:dst = $Destination; $script:rec = [bool]$Recurse
            $d = Join-Path $Destination '20261031-153000-a1b2'
            $null = New-Item -ItemType Directory -Path $d -Force
            [IO.File]::WriteAllText((Join-Path $d 'done.json'), '{}')
        }
        $p = Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $script:root
        $script:src | Should Be 'rig@testpc:C:/TestRig/queue/results/20261031-153000-a1b2'
        $script:dst | Should Be ((Join-Path $script:root $script:jobId) + '.partial')
        $script:rec | Should Be $true
        $p | Should Be (Join-Path $script:root $script:jobId)
        Test-Path -LiteralPath (Join-Path $p 'done.json') | Should Be $true
        Test-Path -LiteralPath ($p + '.partial') | Should Be $false
    }

    It 'a failed scp leaves only <jobId>.partial and no final folder' {
        Mock Invoke-RigScp {
            $null = New-Item -ItemType Directory -Path (Join-Path $Destination '20261031-153000-a1b2') -Force
            throw 'scp failed (exit 1)'
        }
        { Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $script:root } | Should Throw 'scp failed'
        Test-Path -LiteralPath (Join-Path $script:root $script:jobId) | Should Be $false
        Test-Path -LiteralPath ((Join-Path $script:root $script:jobId) + '.partial') | Should Be $true
    }

    It 'deletes a leftover .partial before a new attempt' {
        $stale = Join-Path (Join-Path $script:root ($script:jobId + '.partial')) 'old.txt'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $stale) -Force
        [IO.File]::WriteAllText($stale, 'old')
        Mock Invoke-RigScp {
            $script:sawStale = Test-Path -LiteralPath (Join-Path $Destination 'old.txt')
            $null = New-Item -ItemType Directory -Path (Join-Path $Destination '20261031-153000-a1b2') -Force
        }
        $p = Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $script:root
        $script:sawStale | Should Be $false
        Test-Path -LiteralPath $p | Should Be $true
        Test-Path -LiteralPath ($p + '.partial') | Should Be $false
    }

    It 'throws when scp reports success but the folder is missing' {
        Mock Invoke-RigScp { }
        { Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $script:root } | Should Throw 'missing'
        Test-Path -LiteralPath (Join-Path $script:root $script:jobId) | Should Be $false
    }

    It 'refuses to overwrite an existing local result folder' {
        New-Item -ItemType Directory -Path (Join-Path $script:root $script:jobId) -Force | Out-Null
        Mock Invoke-RigScp { }
        { Receive-JobResult -Target $script:target -JobId $script:jobId -DestinationRoot $script:root } | Should Throw 'already exists'
    }
}

Describe 'ConvertTo-PsLiteral' {
    # Executes the literal as PowerShell source: the result must be exactly the input text.
    function Invoke-Literal([string]$Text) {
        $lit = ConvertTo-PsLiteral $Text
        & ([scriptblock]::Create($lit))
    }
    $q2018 = [string][char]0x2018; $q2019 = [string][char]0x2019; $q201A = [string][char]0x201A; $q201B = [string][char]0x201B

    $cases = @(
        @{ name = "ASCII '"; text = "it's" },
        @{ name = 'U+2018'; text = "a${q2018}b" },
        @{ name = 'U+2019'; text = "a${q2019}b" },
        @{ name = 'U+201A'; text = "a${q201A}b" },
        @{ name = 'U+201B'; text = "a${q201B}b" },
        @{ name = 'path with U+2019 and injection'; text = "C:\a${q2019}; Write-Output INJECTED; ${q2019}" },
        @{ name = "path with ' and injection"; text = "C:\a'; Write-Output INJECTED; '" },
        @{ name = 'all quote kinds'; text = "'${q2018}${q2019}${q201A}${q201B}'" },
        @{ name = 'plain path'; text = 'C:\TestRig\queue\jobs' }
    )
    foreach ($c in $cases) {
        It "round-trips as a literal: $($c.name)" {
            $r = @(Invoke-Literal $c.text)
            $r.Count | Should Be 1
            ($r[0] -ceq $c.text) | Should Be $true
        }
    }
}

Describe 'Invoke-RigNative (real native process)' {
    It 'returns the stdout lines on exit 0 and ignores stderr, including "** " lines' {
        $r = @(Invoke-RigNative -Tool 'cmd.exe' -Arguments @('/c', 'echo out&echo ** WARNING pq>&2&echo noise>&2'))
        $r.Count | Should Be 1
        $r[0] | Should Be 'out'
    }

    It 'throws with the exit code and the stderr text on a non-zero exit' {
        $msg = ''
        try { Invoke-RigNative -Tool 'cmd.exe' -Arguments @('/c', 'echo out&echo err>&2&exit 3') } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'exit 3'
        $msg | Should Match 'err'
    }

    It 'filters "** " lines out of the error message' {
        $msg = ''
        try { Invoke-RigNative -Tool 'cmd.exe' -Arguments @('/c', 'echo ** WARNING pq>&2&echo real problem>&2&exit 3') } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'real problem'
        $msg | Should Not Match 'WARNING pq'
    }

    It 'does not return stdout when it throws' {
        $r = $null
        try { $r = Invoke-RigNative -Tool 'cmd.exe' -Arguments @('/c', 'echo out&exit 3') } catch { }
        $r | Should BeNullOrEmpty
    }
}

Describe 'Invoke-RigRemoteScript size limit' {
    It 'throws when the encoded command would exceed 8000 characters' {
        Mock Invoke-RigSsh { }
        $big = '$x = ' + "'" + ('a' * 3000) + "'"
        { Invoke-RigRemoteScript -Target $script:target -Script $big } | Should Throw 'too long'
        Assert-MockCalled Invoke-RigSsh -Times 0
    }
    It 'accepts a normal script' {
        Mock Invoke-RigSsh { @() }
        { Invoke-RigRemoteScript -Target $script:target -Script 'Get-Date' } | Should Not Throw
    }
}

Describe 'Assert-RigJobId strictness' {
    foreach ($bad in "20261031-153000-a1b2`n", '20261031-153000-A1B2', ('2026103' + [char]0x0661 + '-153000-a1b2'), '20261031-153000-a1b', '../x') {
        It "rejects '$($bad -replace "`n", '\n')'" {
            { Assert-RigJobId $bad } | Should Throw 'Invalid jobId'
        }
    }
    It 'accepts a valid id' { { Assert-RigJobId '20261031-153000-a1b2' } | Should Not Throw }
}

Describe 'Remote scripts executed for real (local powershell, TestDrive queue root)' {
    BeforeEach {
        $script:q = Join-Path $TestDrive ('q' + [guid]::NewGuid().ToString('N'))
        $script:lt = New-LocalRigTarget -QueueRoot $script:q
        Mock Invoke-RigSsh { Invoke-RigRemoteLocally -Command $Command }
    }
    $idA = '20261031-100000-aaaa'; $idB = '20261031-110000-bbbb'; $idC = '20261031-120000-cccc'
    $idD = '20261031-130000-dddd'; $idE = '20261031-140000-eeee'

    function Read-Q([string]$Area, [string]$Id, [string]$File) { Join-Path (Join-Path (Join-Path $script:q $Area) $Id) $File }

    Context '-OpenJobs' {
        It 'returns an empty list when the jobs folder does not exist' {
            @(Get-JobState -Target $script:lt -OpenJobs).Count | Should Be 0
        }

        It 'lists open (job.json / job.claimed.json without done.json) and skips claimed+done, withdrawn and empty ones' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'package.zip', 'job.json'
            New-LocalQueueJob -QueueRoot $script:q -JobId $idB -JobFile 'package.zip', 'job.claimed.json', 'state.json'
            New-LocalQueueJob -QueueRoot $script:q -JobId $idC -JobFile 'package.zip', 'job.claimed.json' -ResultFile 'done.json'
            New-LocalQueueJob -QueueRoot $script:q -JobId $idD -JobFile 'package.zip', 'job.withdrawn.json'
            New-LocalQueueJob -QueueRoot $script:q -JobId $idE -JobFile 'package.zip'
            $r = @(Get-JobState -Target $script:lt -OpenJobs)
            ($r -join ',') | Should Be "$idA,$idB"
        }

        It 'returns a single open job as a one-element list' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.json'
            $r = @(Get-JobState -Target $script:lt -OpenJobs)
            $r.Count | Should Be 1
            $r[0] | Should Be $idA
        }
    }

    Context 'Get-JobState -JobId' {
        It 'reports an unclaimed job without state.json (state = null)' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.json'
            $s = Get-JobState -Target $script:lt -JobId $idA
            $s.jobJson | Should Be $true
            $s.claimed | Should Be $false
            $s.withdrawn | Should Be $false
            $s.done | Should Be $false
            $s.state | Should BeNullOrEmpty
        }

        It 'parses state.json and reports claimed' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.claimed.json'
            [IO.File]::WriteAllText((Read-Q jobs $idA 'state.json'), '{"schema":1,"jobId":"x","beat":17,"state":"running","runId":"r1"}')
            $s = Get-JobState -Target $script:lt -JobId $idA
            $s.jobJson | Should Be $false
            $s.claimed | Should Be $true
            $s.state.beat | Should Be 17
            $s.state.state | Should Be 'running'
        }

        It 'treats an unreadable (half-written) state.json as null' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.claimed.json'
            [IO.File]::WriteAllText((Read-Q jobs $idA 'state.json'), '{"beat":1')
            (Get-JobState -Target $script:lt -JobId $idA).state | Should BeNullOrEmpty
        }

        It 'reports done when results\<jobId>\done.json exists, and withdrawn' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.withdrawn.json' -ResultFile 'done.json'
            $s = Get-JobState -Target $script:lt -JobId $idA
            $s.done | Should Be $true
            $s.withdrawn | Should Be $true
        }

        It 'works when neither the job nor the result folder exist' {
            $s = Get-JobState -Target $script:lt -JobId $idA
            $s.jobJson | Should Be $false
            $s.claimed | Should Be $false
            $s.done | Should Be $false
        }
    }

    Context 'Send-JobAbort' {
        It 'creates an empty abort file in the job folder' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'job.claimed.json'
            Send-JobAbort -Target $script:lt -JobId $idA
            $f = Read-Q jobs $idA 'abort'
            Test-Path -LiteralPath $f | Should Be $true
            (Get-Item -LiteralPath $f).Length | Should Be 0
        }

        It '-Withdraw renames job.json to job.withdrawn.json and reports withdrawn' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'package.zip', 'job.json'
            $r = Send-JobAbort -Target $script:lt -JobId $idA -Withdraw
            $r.withdrawn | Should Be $true
            $r.jobJsonPresent | Should Be $false
            $r.claimed | Should Be $false
            Test-Path -LiteralPath (Read-Q jobs $idA 'job.json') | Should Be $false
            Test-Path -LiteralPath (Read-Q jobs $idA 'job.withdrawn.json') | Should Be $true
        }

        It '-Withdraw with job.json held open: not withdrawn, not claimed, job.json still present' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'package.zip', 'job.json'
            $path = Read-Q jobs $idA 'job.json'
            # a reader that does not share Delete blocks the rename, like an antivirus scanner would
            $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $r = Send-JobAbort -Target $script:lt -JobId $idA -Withdraw
            } finally { $fs.Dispose() }
            $r.withdrawn | Should Be $false
            $r.jobJsonPresent | Should Be $true
            $r.claimed | Should Be $false
            Test-Path -LiteralPath $path | Should Be $true
            # once the reader is gone, the retry succeeds
            (Send-JobAbort -Target $script:lt -JobId $idA -Withdraw).withdrawn | Should Be $true
        }

        It '-Withdraw after the agent claimed the job: claimed = true, nothing withdrawn' {
            New-LocalQueueJob -QueueRoot $script:q -JobId $idA -JobFile 'package.zip', 'job.claimed.json'
            $r = Send-JobAbort -Target $script:lt -JobId $idA -Withdraw
            $r.withdrawn | Should Be $false
            $r.jobJsonPresent | Should Be $false
            $r.claimed | Should Be $true
        }
    }

    Context 'Publish-Job' {
        BeforeEach {
            $script:local = Join-Path $TestDrive ('l' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:local
            [IO.File]::WriteAllText((Join-Path $script:local 'package.zip'), 'ZIP')
            [IO.File]::WriteAllText((Join-Path $script:local 'job.json'), 'NEW')
            # scp stand-in: "user@host:C:/path" -> local copy
            Mock Invoke-RigScp {
                $dest = ($Destination -replace '^[^@]+@[^:]+:', '') -replace '/', '\'
                Copy-Item -LiteralPath $Source -Destination $dest
                if ($dest.EndsWith('job.json.tmp') -and $script:preexistingJob) {
                    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $dest) 'job.json'), 'OLD')
                }
            }
            $script:preexistingJob = $false
        }

        It 'creates the job folder, copies the files and renames job.json.tmp last' {
            Publish-Job -Target $script:lt -JobId $idA -JobDirectory $script:local
            [IO.File]::ReadAllText((Read-Q jobs $idA 'job.json')) | Should Be 'NEW'
            [IO.File]::ReadAllText((Read-Q jobs $idA 'package.zip')) | Should Be 'ZIP'
            Test-Path -LiteralPath (Read-Q jobs $idA 'job.json.tmp') | Should Be $false
        }

        It 'refuses to publish into an existing job folder' {
            Publish-Job -Target $script:lt -JobId $idA -JobDirectory $script:local
            { Publish-Job -Target $script:lt -JobId $idA -JobDirectory $script:local } | Should Throw 'already exists'
        }

        It 'never overwrites an existing job.json when renaming' {
            $script:preexistingJob = $true
            { Publish-Job -Target $script:lt -JobId $idA -JobDirectory $script:local } | Should Throw
            [IO.File]::ReadAllText((Read-Q jobs $idA 'job.json')) | Should Be 'OLD'
        }
    }
}
