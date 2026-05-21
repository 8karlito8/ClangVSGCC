# ── VARIABLES──────────────────────────────────────
.DEFAULT_GOAL := help
COMPILER    ?= clang
OPT         ?= O3
WORKLOAD    ?= particle
VARIANT     ?= aos
MODE        ?= counter
INVOCATIONS ?= 1
RESULTS_ROOT ?= results
# Build modes (used by meson): counter | perf
# bench.sh modes:              counter | perf | sampling
#   sampling reuses the 'perf' binary — no separate meson build is needed.

MESON_OPTS :=
ifeq ($(MODE),perf)
  MESON_OPTS += -Ddisable_perf_counter=true
endif

BUILDDIR = build/$(COMPILER)/$(WORKLOAD)/$(VARIANT)/$(OPT)/$(MODE)
TARGET   = $(WORKLOAD)_$(VARIANT)

COMPILERS         = gcc clang
OPTS              = O2 O3 O3_native
MODES             = counter perf
# Note: 'sampling' is a bench.sh-only mode — it reuses the 'perf' binary (no separate build needed).
PARTICLE_VARIANTS = aos soa aligned
MATRIX_VARIANTS   = row_major tile_contiguous

# ── SINGLE-CONFIGURATION TARGETS ─────────────────────────────────────────────

$(BUILDDIR)/build.ninja:
	meson setup $(BUILDDIR) \
		--native-file config/$(COMPILER).ini \
		--native-file config/$(OPT).ini \
		-Dworkload=$(WORKLOAD) \
		-Dvariant=$(VARIANT) \
		$(MESON_OPTS)

.PHONY: setup
setup: $(BUILDDIR)/build.ninja


list-build-dir:
	@tree -d build --filelimit=3

.PHONY: reconfigure
reconfigure:
	meson setup --reconfigure $(BUILDDIR) \
		--native-file config/$(COMPILER).ini \
		--native-file config/$(OPT).ini \
		-Dworkload=$(WORKLOAD) \
		-Dvariant=$(VARIANT) \
		$(MESON_OPTS)

.PHONY: build
build: $(BUILDDIR)/build.ninja
	meson compile -C $(BUILDDIR) $(TARGET)

.PHONY: run
run: build
	./$(BUILDDIR)/$(TARGET)

# ── PARTICLE SHORTCUTS ────────────────────────────────────────────────────────

.PHONY: build-particle-bench
build-particle-bench: $(BUILDDIR)/build.ninja
	meson compile -C $(BUILDDIR) particle_$(VARIANT)

.PHONY: run-particle-bench
run-particle-bench: build-particle-bench
	./$(BUILDDIR)/particle_$(VARIANT)

.PHONY: build-particle-runner
build-particle-runner: $(BUILDDIR)/build.ninja
	meson compile -C $(BUILDDIR) particle_runner_$(VARIANT)

.PHONY: run-particle-runner
run-particle-runner: build-particle-runner
	./$(BUILDDIR)/particle_runner_$(VARIANT)

# ── MATRIX SHORTCUTS ──────────────────────────────────────────────────────────

.PHONY: build-matrix-bench
build-matrix-bench: $(BUILDDIR)/build.ninja
	meson compile -C $(BUILDDIR) matrix_$(VARIANT)

.PHONY: run-matrix-bench
run-matrix-bench: build-matrix-bench
	./$(BUILDDIR)/matrix_$(VARIANT)

.PHONY: build-matrix-runner
build-matrix-runner: $(BUILDDIR)/build.ninja
	meson compile -C $(BUILDDIR) matrix_runner_$(VARIANT)

.PHONY: run-matrix-runner
run-matrix-runner: build-matrix-runner
	./$(BUILDDIR)/matrix_runner_$(VARIANT)

# ── BULK TARGETS ──────────────────────────────────────────────────────────────

.PHONY: setup-all
setup-all:
	@for c in $(COMPILERS); do \
		for m in $(MODES); do \
			for o in $(OPTS); do \
				for v in $(PARTICLE_VARIANTS); do \
					$(MAKE) --no-print-directory setup WORKLOAD=particle VARIANT=$$v OPT=$$o MODE=$$m COMPILER=$$c; \
				done; \
				for v in $(MATRIX_VARIANTS); do \
					$(MAKE) --no-print-directory setup WORKLOAD=matrix VARIANT=$$v OPT=$$o MODE=$$m COMPILER=$$c; \
				done; \
			done; \
		done; \
	done

.PHONY: build-particle
build-particle:
	@for c in $(COMPILERS); do \
		for m in $(MODES); do \
			for o in $(OPTS); do \
				for v in $(PARTICLE_VARIANTS); do \
					$(MAKE) --no-print-directory build WORKLOAD=particle VARIANT=$$v OPT=$$o MODE=$$m COMPILER=$$c; \
				done; \
			done; \
		done; \
	done

.PHONY: build-matrix
build-matrix:
	@for c in $(COMPILERS); do \
		for m in $(MODES); do \
			for o in $(OPTS); do \
				for v in $(MATRIX_VARIANTS); do \
					$(MAKE) --no-print-directory build WORKLOAD=matrix VARIANT=$$v OPT=$$o MODE=$$m COMPILER=$$c; \
				done; \
			done; \
		done; \
	done

.PHONY: build-all
build-all: build-particle build-matrix

.PHONY: build-particle-runners
build-particle-runners:
	@for o in $(OPTS); do \
		for v in $(PARTICLE_VARIANTS); do \
			$(MAKE) --no-print-directory build-particle-runner WORKLOAD=particle VARIANT=$$v OPT=$$o MODE=counter; \
		done; \
	done

.PHONY: build-matrix-runners
build-matrix-runners:
	@for o in $(OPTS); do \
		for v in $(MATRIX_VARIANTS); do \
			$(MAKE) --no-print-directory build-matrix-runner WORKLOAD=matrix VARIANT=$$v OPT=$$o MODE=counter; \
		done; \
	done

.PHONY: build-runners
build-runners: build-particle-runners build-matrix-runners

.PHONY: validate-particle
validate-particle:
	@for v in $(PARTICLE_VARIANTS); do \
		$(MAKE) --no-print-directory build-particle-runner COMPILER=gcc OPT=O2 WORKLOAD=particle VARIANT=$$v MODE=counter; \
		printf "\n--- particle_runner_$$v ---\n"; \
		./build/gcc/particle/$$v/O2/counter/particle_runner_$$v; \
	done

.PHONY: validate-matrix
validate-matrix:
	@for v in $(MATRIX_VARIANTS); do \
		$(MAKE) --no-print-directory build-matrix-runner COMPILER=gcc OPT=O2 WORKLOAD=matrix VARIANT=$$v MODE=counter; \
		printf "\n--- matrix_runner_$$v ---\n"; \
		./build/gcc/matrix/$$v/O2/counter/matrix_runner_$$v; \
	done

.PHONY: validate
validate: validate-particle validate-matrix

# ── PIPELINE ──────────────────────────────────────────────────────────────────

# Configure OS for benchmarking: governor, turbo, NMI watchdog, perf paranoid.
# Requires passwordless sudo for sysfs writes. Called automatically by run-all.
.PHONY: system-setup
system-setup:
	bash -c 'source scripts/bench_common.sh && setup_system_state'

# Walk-away orchestrator: system-setup → build matrix → run all phases → aggregate → plot.
.PHONY: run-all
run-all:
	./run_all.sh

# Re-aggregate and re-plot from existing results without rebuilding or re-running.
.PHONY: reanalyze
reanalyze:
	SKIP_BUILD=1 SKIP_RUN=1 ./run_all.sh

# Run aggregate_all.py over the results tree → results/master.csv.
.PHONY: aggregate
aggregate:
	cd scripts && uv run python aggregate_all.py ../$(RESULTS_ROOT) -o ../$(RESULTS_ROOT)/master.csv

# Generate all plot families from results/master.csv → results/figures/.
.PHONY: plot
plot:
	cd scripts && uv run python plot_all.py ../$(RESULTS_ROOT)/master.csv

# Aggregate + plot in one step.
.PHONY: analyze
analyze: aggregate plot

# ── SINGLE-WORKLOAD BENCH RUNS (development) ──────────────────────────────────
# Builds the target binary if stale, then runs bench.sh for that one variant.
# Uses: COMPILER, OPT, MODE, VARIANT, INVOCATIONS

.PHONY: bench-particle
bench-particle: build
	src/particle/bench.sh $(COMPILER) $(OPT) $(MODE) $(INVOCATIONS)

.PHONY: bench-matrix
bench-matrix: build
	src/matrix/bench.sh $(COMPILER) $(OPT) $(MODE) $(INVOCATIONS)

# ── KEEP THINGS TIDY ──────────────────────────────────────────────────────────────
#
.PHONY: clean
clean:
	rm -rf build/

.PHONY: clean-results
clean-results:
	rm -rf results/

.PHONY: help
help:
	@printf "================================================================================\n"
	@printf "VARIABLES (override: make target VAR=value)\n"
	@printf "  COMPILER     gcc | clang                         (default: clang)\n"
	@printf "  OPT          O2 | O3 | O3_native                 (default: O3)\n"
	@printf "  WORKLOAD     particle | matrix                   (default: particle)\n"
	@printf "  VARIANT      particle: aos|soa|aligned           (default: aos)\n"
	@printf "               matrix:   row_major|tile_contiguous\n"
	@printf "  MODE         counter | perf                      (default: counter)\n"
	@printf "               counter  = Phase A binary: in-process PerfCounterGroup\n"
	@printf "               perf     = Phase B/C binary: DISABLE_PERF_COUNTER\n"
	@printf "               sampling = bench.sh only — reuses perf binary, no separate build\n"
	@printf "  INVOCATIONS  independent bench.sh runs per variant (default: 1)\n"
	@printf "  RESULTS_ROOT results tree root for aggregate/plot   (default: results)\n"
	@printf "================================================================================\n"
	@printf "PATHS\n"
	@printf "  build/{compiler}/{workload}/{variant}/{opt}/{mode}/\n"
	@printf "  results/{compiler}/{workload}/{variant}/{opt}/{phase}/\n"
	@printf "    phase=counter   → gbench_*.json + conditions_*.json\n"
	@printf "    phase=perf      → b1_cache/ b2_tlb/ b3_stalls/ (each: perf_*.csv + gbench_*.json)\n"
	@printf "    phase=sampling  → sampling/ (perf_*.data + annotate_*.txt + report_*.csv)\n"
	@printf "  results/master.csv  — aggregated tall-format table (all phases, all cells)\n"
	@printf "  results/figures/    — plots (layout_bars/ scaling_lines/ effect_forest/ timing_overview/)\n"
	@printf "  results/_logs/      — per-cell build and run logs from run_all.sh\n"
	@printf "================================================================================\n"
	@printf "PIPELINE (walk-away — start here)\n"
	@printf "  make system-setup  configure OS: governor=performance, turbo off, NMI off (sudo)\n"
	@printf "  make run-all       full pipeline: setup → build matrix → run → aggregate → plot\n"
	@printf "  make reanalyze     re-aggregate + re-plot from existing results (no build/run)\n"
	@printf "  make aggregate     aggregate_all.py → results/master.csv\n"
	@printf "  make plot          plot_all.py → results/figures/\n"
	@printf "  make analyze       aggregate + plot\n"
	@printf "================================================================================\n"
	@printf "SINGLE-WORKLOAD DEV (build one cell + run bench.sh)\n"
	@printf "  make bench-particle  COMPILER=gcc OPT=O3 MODE=counter VARIANT=soa INVOCATIONS=3\n"
	@printf "  make bench-matrix    COMPILER=clang OPT=O3 MODE=perf  VARIANT=tile_contiguous\n"
	@printf "================================================================================\n"
	@printf "BUILD (low-level meson wrappers)\n"
	@printf "  make setup          meson setup one build dir (sentinel-guarded)\n"
	@printf "  make reconfigure    meson setup --reconfigure\n"
	@printf "  make build          compile one target\n"
	@printf "  make setup-all      set up all build dirs (2 compilers × 3 opts × 5 variants × 2 modes = 60)\n"
	@printf "  make build-all      compile all benchmarks\n"
	@printf "================================================================================\n"
	@printf "PARTICLE / MATRIX SHORTCUTS (single-cell compile + run)\n"
	@printf "  make build-particle-bench    compile benchmark  (uses COMPILER VARIANT OPT MODE)\n"
	@printf "  make run-particle-bench      build + run benchmark\n"
	@printf "  make build-particle-runner   compile correctness runner\n"
	@printf "  make run-particle-runner     build + run correctness runner\n"
	@printf "  make build-particle          compile all particle cells (both compilers)\n"
	@printf "  make build-matrix            compile all matrix cells (both compilers)\n"
	@printf "  make build-matrix-bench      compile matrix benchmark\n"
	@printf "  make run-matrix-bench        build + run matrix benchmark\n"
	@printf "================================================================================\n"
	@printf "VALIDATION\n"
	@printf "  make validate-particle       correctness runners for all particle variants (gcc O2)\n"
	@printf "  make validate-matrix         correctness runners for all matrix variants (gcc O2)\n"
	@printf "  make validate                validate all workloads\n"
	@printf "================================================================================\n"
	@printf "HOUSEKEEPING\n"
	@printf "  make list-build-dir          tree view of build/ directory\n"
	@printf "  make clean                   rm -rf build/\n"
	@printf "  make clean-results           rm -rf results/\n"
	@printf "================================================================================\n"
	@printf "EXAMPLES\n"
	@printf "  # One-time OS setup, then walk away:\n"
	@printf "  make run-all\n"
	@printf "  # Re-run analysis after fixing a plot script:\n"
	@printf "  make reanalyze\n"
	@printf "  # Test one configuration before committing to a full run:\n"
	@printf "  make bench-particle COMPILER=gcc OPT=O3 MODE=counter VARIANT=soa INVOCATIONS=2\n"
	@printf "  # Build a specific binary:\n"
	@printf "  make build COMPILER=gcc WORKLOAD=particle VARIANT=soa OPT=O3 MODE=counter\n"
	@printf "================================================================================\n"
