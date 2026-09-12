param([Parameter(Mandatory=$true)][ValidateSet('d3d12','opengl','pure-opengl','vulkan','native-vulkan')][string]$Renderer)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'pane-acceptance.ps1') -Renderer $Renderer -TestRecovery -VulkanValidation:($Renderer -in @('vulkan','native-vulkan'))
