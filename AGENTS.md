# Project work rules

Read `docs/ARCHITECTURE.md` and `docs/REQUIREMENTS.md` before changing behavior.
Follow the architecture's layer, ownership, cancellation and failure boundaries.
Keep `main.zig` limited to startup. Choose the owning protocol, runtime, analysis
or feature module before adding behavior. The architecture defines those boundaries.

Keep current design and behavior in the existing six `docs/` documents. Update
those documents in place. Do not create another checkpoint, feature narrative or
per-session report there. Put historical reports in `bench/reports/` and raw
measurements in `bench/results/`. Never make production code/build/tests depend
on benchmark evidence or discussion material outside this project.

Run `python3 tools/check_layout.py` after changing project layout or documentation.
Run focused protocol/unit checks for implementation changes. For memory or hot-path
changes, compare diagnostics delay and memory before/after and preserve raw data.
Keep server memory separate from editor memory.

Retired source-rewrite profilers under `bench/history/tools/` are historical.
Do not run them against current sources as supported profiling commands.

Preserve requested large examples and active editor binaries/grammar outputs.
Generated caches, runtime logs and machine metadata are not project source.

Use short sentences, simple words, active voice and consistent technical terms.
Use ASD-STE100 principles for most prose; do not claim formal compliance.

Use the user's configured human Git identity. Never add AI authorship or
co-authorship trailers. Do not change Git identity to an AI name.
