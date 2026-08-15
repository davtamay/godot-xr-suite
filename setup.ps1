# One-command setup for the Godot XR suite.
#
#   .\setup.ps1 -Project C:\path\to\your\project [-Engine C:\path\to\fork\bin]
#
# - Copies every addon into <Project>\addons\ (self-contained, no junctions).
#   XR Suite then resolves which addons each project target needs; Web/APK
#   export filters strip authoring metadata and opposite-platform providers.
#   Re-running this command later is the easiest way to add new capabilities.
# - If -Engine is given (the fork's bin folder with the built web templates),
#   installs web_release.zip + web_nothreads_release.zip into Godot's export
#   templates folder so the Web export "just works" (no custom_template path).
#
# After it runs: open the project in the fork's Godot editor and play
#   addons/godot_webxr_kit/samples/webxr_starter.tscn

param(
	[string]$Project = ".",
	[string]$Engine = "",
	[string]$TemplateVersion = "4.8.dev"
)

$ErrorActionPreference = "Stop"
$suiteAddons = Join-Path $PSScriptRoot "addons"
$projRoot = (Resolve-Path $Project).Path
$projAddons = Join-Path $projRoot "addons"

# 1. Addons -> project.
New-Item -ItemType Directory -Force -Path $projAddons | Out-Null
Write-Output "Installing addons into $projAddons"
Get-ChildItem $suiteAddons -Directory | ForEach-Object {
	Copy-Item $_.FullName -Destination $projAddons -Recurse -Force
	Write-Output "  + $($_.Name)"
}

# 2. Web export templates (optional).
if ($Engine -ne "") {
	$tplDir = Join-Path $env:APPDATA "Godot\export_templates\$TemplateVersion"
	New-Item -ItemType Directory -Force -Path $tplDir | Out-Null
	$pairs = @{
		"godot.web.template_release.wasm32.zip"          = "web_release.zip"           # threaded (needs COOP/COEP)
		"godot.web.template_release.wasm32.nothreads.zip" = "web_nothreads_release.zip" # single-threaded (hosts anywhere)
	}
	Write-Output "Installing web templates into $tplDir"
	foreach ($src in $pairs.Keys) {
		$srcPath = Join-Path $Engine $src
		if (Test-Path $srcPath) {
			Copy-Item $srcPath (Join-Path $tplDir $pairs[$src]) -Force
			Write-Output "  + $($pairs[$src])"
		} else {
			Write-Warning "  missing: $srcPath (skipped)"
		}
	}
}

Write-Output ""
Write-Output "Done. In the fork's Godot editor:"
Write-Output "  1. Open $projRoot"
Write-Output "  2. Enable godot_xr_interaction_toolkit to open XR Suite"
Write-Output "  3. Run Project Validator in the dock and apply its fixes"
Write-Output "  4. Click New XR Scene, or open an existing scene and add blocks"
