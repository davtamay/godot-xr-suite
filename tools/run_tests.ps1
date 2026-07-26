# Runs an XR suite headlessly and FAILS on a script error as well as a
# non-zero exit. A suite's own PASS line is not sufficient: a test that hits
# a runtime error aborts silently, the runner continues, and the summary
# still says PASS. Verified on Godot 4.7.stable.
param(
	[Parameter(Mandatory = $true)][string[]]$Suite,
	[string]$Godot = 'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe',
	[string]$Demo = 'C:\Users\davta\Repos\Godot_WebXR_gh\demo'
)
$failed = 0
foreach ($s in $Suite) {
	$out = & $Godot --headless --xr-mode off --path $Demo --script "res://addons/$s.gd"
	$code = $LASTEXITCODE
	$errors = ($out | Select-String -Pattern 'SCRIPT ERROR|^ERROR:' -AllMatches).Count
	$verdict = ($out | Select-String -Pattern 'PASS|FAILURE' | Select-Object -First 1)
	"{0,-58} exit={1} scripterrors={2}  {3}" -f $s.Split('/')[-1], $code, $errors, $verdict
	if ($code -ne 0 -or $errors -gt 0) { $failed += 1 }
}
if ($failed -gt 0) { Write-Error "$failed suite(s) failed or emitted script errors"; exit 1 }
exit 0
