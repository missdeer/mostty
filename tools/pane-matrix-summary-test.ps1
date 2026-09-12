$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$folder=Join-Path $root 'tmp/pane-matrix-summary-tests'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$filter=Join-Path $PSScriptRoot 'pane-matrix-summary.jq'
$keys=@('minimum_size','independent_input','directional_focus','divider_drag','maximize_restore','tab_retention','background_tab_output','maximized_hidden_output','url_hover','mouse_reporting','mouse_capture_tab_switch','ime','bracketed_unicode_paste','selection_copy','hover_scroll','output_divider_responsiveness','output_resize_responsiveness','pty_region_match','async_glyph_delivery','renderer_dpi_change','kitty_isolation','wallpaper_reload','transparency_blur','individual_exit','close_pane','close_tab','close_window')
$names=@('d3d11','d3d12','opengl','pure-opengl','vulkan','native-vulkan')
$cases=@(foreach($name in $names){
    $case=[ordered]@{renderer=$name;status='pass';backend_identity='fixture';executable_sha256=('A'*64);pane_handles=@(1,2,3,4);shell_process_ids=@(10,20,30,40);pty_vt_sizes=@(1,2,3,4);font_reload_sizes=@(1,2,3,4);device_removal_recovery='pass';presentation_failure_recovery='pass';vulkan_validation_errors=0;vulkan_validation_instances=2;vulkan_validation='no validation errors observed'}
    foreach($key in $keys){$case[$key]='pass'}
    $case
})
function Assert-Summary([string]$Expected){
    $cases | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder 'fixture.json') -Encoding utf8
    & jq -f $filter (Join-Path $folder 'fixture.json') | Set-Content -LiteralPath (Join-Path $folder 'summary.json') -Encoding utf8
    if($LASTEXITCODE -ne 0){throw 'Summary filter failed'}
    $actual=& jq -r '.status' (Join-Path $folder 'summary.json')
    if($actual -ne $Expected){throw "Expected $Expected, got $actual"}
}
Assert-Summary 'local-pass-with-limitations'
$cases[0].Remove('url_hover');Assert-Summary 'incomplete';$cases[0]['url_hover']='pass'
$cases[0].Remove('renderer_dpi_change');Assert-Summary 'incomplete';$cases[0]['renderer_dpi_change']='pass'
$cases[1].renderer='d3d11';Assert-Summary 'incomplete';$cases[1].renderer='d3d12'
$cases[2].executable_sha256=('B'*64);Assert-Summary 'incomplete';$cases[2].executable_sha256=('A'*64)
$cases[3].status='unsupported';Assert-Summary 'incomplete';$cases[3].status='pass'
$cases[5].vulkan_validation_instances=1;Assert-Summary 'incomplete';$cases[5].vulkan_validation_instances=2
$cases=$cases[0..4];Assert-Summary 'incomplete'
'8 matrix summary checks passed'
