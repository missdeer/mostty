#!/usr/bin/env bash
# Linux/macOS only. Compilation is completed before any timed executable runs.
set -euo pipefail
root=$(pwd)
base=$(git rev-parse "${BENCH_BASE:?}^{commit}")
head=$(git rev-parse "${BENCH_HEAD:-HEAD}^{commit}")
out="$root/tmp/runtime-bench"
mkdir -p "$out"
for side in base head; do
  rev=$base; if [[ $side == head ]]; then rev=$head; fi
  tree="$out/$side"
  git worktree add --detach "$tree" "$rev"
  cmp "$root/build.zig.zon" "$tree/build.zig.zon" # Never compare different dependency pins.
  cp "$root/build.zig" "$tree/build.zig"
  cp "$root"/src/runtime_bench*.zig "$tree/src/"
  if [[ $(uname -s) == Darwin ]]; then
    cat "$root/tests/bench/macos-capi.zig" >> "$tree/src/macos/capi.zig"
    printf '\ncomptime { _ = @import("runtime_bench.zig"); }\npub fn runtimeBenchAllocator() @import("std").mem.Allocator { return @import("std").heap.c_allocator; }\n' >> "$tree/src/mosttymacos.zig"
    (cd "$tree" && zig build runtime-bench -Druntime-bench -Doptimize=ReleaseFast -Dcpu=baseline --global-cache-dir "$root/.zig-cache") > "$out/$side-build.log" 2>&1
  else
    (cd "$tree" && zig build runtime-bench -Druntime-bench -Dcore-only -Doptimize=ReleaseFast -Dcpu=baseline --global-cache-dir "$root/.zig-cache") > "$out/$side-build.log" 2>&1
  fi
done
if [[ $(uname -s) == Darwin ]]; then cpu=$(sysctl -n machdep.cpu.brand_string); else cpu=$(lscpu | tr '\n' ' '); fi
jq -n --arg base "$base" --arg head "$head" --arg os "$(uname -a)" --arg cpu "$cpu" --arg zig "$(zig version)" \
  '{base:$base,head:$head,os:$os,cpu:$cpu,compiler:$zig,mode:"ReleaseFast",target_cpu:"baseline",warmup:3,samples_per_process:15,order:["base","head","head","base","head","base","base","head"]}' > "$out/metadata.json"
index=0
for side in base head head base head base base head; do
  "$out/$side/zig-out/bin/runtime-bench" > "$out/$side-$index.log" 2>&1
  index=$((index + 1))
done
