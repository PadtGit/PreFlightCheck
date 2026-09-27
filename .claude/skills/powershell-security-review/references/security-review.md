# Windows PowerShell review guidance

Use these checks where the project's behavior makes them relevant. Verify findings against actual
data flow and the supported environment; do not report every item as a mandatory change.

- Credentials: inspect plaintext parameters, embedded credentials, SecureString conversion sources,
  persisted secrets, ACLs, and transcript output. SecureString wrapping does not undo prior exposure.
- Injection: trace input into Invoke-Expression, scriptblock creation, native shell command strings,
  remoting arguments, and dynamic imports. Prefer command invocation with separate arguments; verify
  quoting against the actual native program and PowerShell version.
- Privilege: check whether elevation is necessary for the entire operation, who controls input files
  and scheduled-task definitions, and whether privileged code loads writable dependencies.
- Remoting and transport: inspect authentication, endpoint authorization, TrustedHosts usage,
  credential delegation, certificate verification, and download origin/integrity checks.
- Filesystem: inspect resolved paths before recursive deletion or moves, literal versus wildcard
  semantics, reparse points, traversal, destination ACLs, and race conditions. Check that ShouldProcess
  guards the state-changing operation where advertised; -WhatIf support alone proves little.
- Logs: check secrets in errors, verbose/debug output, transcripts, command lines, and access to logs.
- Dependencies: examine manifests, module resolution paths, version constraints, signed/pinned
  downloads where relevant, and imports controlled by less privileged users.
- Failures: inspect catch blocks, nonterminating errors, native process exit codes, partial changes,
  cleanup/finally, and whether a failed precondition allows a dangerous later step to run.

For frameworks, discover concrete imports and entrypoints first. For example, review task identity
and writable action paths for ScheduledTasks, remoting identity and transport for CIM/WinRM, and
credential handling and resource behavior for DSC. Inspect .NET/WPF event input only if present.
Follow the framework's official security documentation; avoid imposing unrelated framework rules.

The settings omit four unsupported names. Manually inspect uninitialized variables and control-flow
paths before reads, parameter/member name collisions, and incomplete argument/type usage. Parser
diagnostics and manual checks may overlap these concerns but are not equivalent replacement rules.

Primary references (consult current versions when the task needs them):
- https://learn.microsoft.com/en-us/powershell/scripting/security/overview
- https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/readme
- https://learn.microsoft.com/en-us/powershell/module/psscriptanalyzer/invoke-scriptanalyzer
