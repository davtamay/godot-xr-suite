# Runs an XR suite headlessly and FAILS on a script error as well as a
# non-zero exit. A suite's own PASS line is not sufficient: a test that hits
# a runtime error aborts silently, the runner continues, and the summary
# still says PASS. Verified on Godot 4.7.stable.
#
# Godot writes "SCRIPT ERROR:" / "ERROR:" to stderr, not stdout. Plain
# `$out = & $Godot ...` in Windows PowerShell 5.1 only captures stdout --
# stderr passes straight to the console and is invisible to $out, so the
# scripterrors check below would silently never fire. Confirmed empirically
# with a probe script that crashes and still prints its own PASS line: with
# a plain capture, scripterrors=0 and exit=0 even though the crash happened.
# Piping through `cmd /c "... 2>&1"` merges stderr into stdout at the OS
# level before PowerShell sees it, so the merged text lands in $out. Do not
# "fix" this by adding `2>&1` directly on the native call instead -- in
# PowerShell 5.1 that wraps each stderr line as an ErrorRecord and can flip
# $? to failure even on a clean exit; the OS-level cmd merge avoids that.
param(
	[Parameter(Mandatory = $true)][string[]]$Suite,
	[string]$Godot = 'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe',
	[string]$Demo = 'C:\Users\davta\Repos\Godot_WebXR_gh\demo'
)
# -Suite is [string[]], which binds correctly when PowerShell itself builds the
# array (e.g. `& '.\run_tests.ps1' -Suite a,b,c`). But `-File` (the documented,
# process-launching invocation) hands every argument to the child process as a
# single string, so `-Suite a,b,c` arrives as ONE element "a,b,c" and binds to
# a one-item array -- silently. The runner then "tests" one nonexistent path
# and reports one failure, not four suites' worth of evidence. Split on commas
# here so both invocation forms behave identically; this is deliberately safe
# to run twice (splitting "a" on "," still yields "a").
$suites = @($Suite | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
$failed = 0
foreach ($s in $suites) {
	$cmdLine = "`"$Godot`" --headless --xr-mode off --path `"$Demo`" --script res://addons/$s.gd 2>&1"
	$out = cmd /c $cmdLine
	$code = $LASTEXITCODE
	# NOTE: some suites report assertion failures via push_error, whose output
	# also starts with "ERROR:", so a nonzero count here can mean either a real
	# crash OR an ordinary test failure. Both must fail the gate, so the count
	# stays -- but read the verdict column before concluding the suite crashed.
	$errors = ($out | Select-String -Pattern 'SCRIPT ERROR|^ERROR:' -AllMatches).Count
	# 'FAIL' as well as 'FAILURE': suites word their verdict differently
	# ("XR eye height: FAIL (1)" vs "XR poke fidelity: 2 FAILURE(S)"), and a
	# blank verdict column sent this reader chasing a phantom crash twice.
	$verdict = ($out | Select-String -Pattern 'PASS|FAIL' | Select-Object -First 1)
	"{0,-58} exit={1} scripterrors={2}  {3}" -f $s.Split('/')[-1], $code, $errors, $verdict
	if ($code -ne 0 -or $errors -gt 0) { $failed += 1 }
}
if ($failed -gt 0) { Write-Error "$failed suite(s) failed or emitted script errors"; exit 1 }
exit 0
