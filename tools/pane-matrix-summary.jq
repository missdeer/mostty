def required_checks: [
  "minimum_size", "independent_input", "directional_focus", "divider_drag",
  "maximize_restore", "tab_retention", "background_tab_output", "maximized_hidden_output",
  "url_hover", "mouse_reporting", "mouse_capture_tab_switch", "ime",
  "bracketed_unicode_paste", "selection_copy", "hover_scroll",
  "output_divider_responsiveness", "output_resize_responsiveness", "pty_region_match",
  "async_glyph_delivery", "renderer_dpi_change", "kitty_isolation", "wallpaper_reload", "transparency_blur",
  "individual_exit", "close_pane", "close_tab", "close_window"
];
def case_complete:
  . as $r |
  .status == "pass" and
  all(required_checks[]; (($r[.] // "") | startswith("pass"))) and
  ((.backend_identity // "") | length > 0) and
  (.pane_handles | length == 4) and (.shell_process_ids | unique | length == 4) and
  (.pty_vt_sizes | length == 4) and (.font_reload_sizes | length == 4) and
  (if .renderer == "d3d11" then true
   elif .renderer == "d3d12" then (.device_removal_recovery // "" | startswith("pass"))
   else (.presentation_failure_recovery // "" | startswith("pass")) end) and
  (if (.renderer == "vulkan" or .renderer == "native-vulkan") then
     (.vulkan_validation_errors == 0 and .vulkan_validation_instances >= 2 and .vulkan_validation == "no validation errors observed")
   else true end);
. as $cases |
(["d3d11","d3d12","opengl","pure-opengl","vulkan","native-vulkan"] | sort) as $expected |
((map(.renderer) | sort) == $expected) as $all_backends |
(all(.[]; (.executable_sha256 // "" | test("^[0-9A-Fa-f]{64}$"))) and (map(.executable_sha256) | unique | length == 1)) as $same_build |
{
  status: (if $all_backends and $same_build and all(.[]; case_complete) then "local-pass-with-limitations" else "incomplete" end),
  all_backends: $all_backends,
  same_build: $same_build,
  local_cases_passed: [.[] | select(case_complete) | .renderer],
  results: $cases,
  unverified: [
    "Physical mixed-DPI transitions require suitable monitors; see per-case DPI observations.",
    "RDP and physical GPU resets were not exercised; research-backend failures are diagnostic cases.",
    "Opaque-only and legacy no-present-wait Vulkan hardware are outside this local matrix."
  ]
}
