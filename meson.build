# -----------------------------------------------------------------------------
# PROJECT SETUP
# -----------------------------------------------------------------------------

project('cache_bench', 'cpp',
  default_options: [
    'cpp_std=c++17',
    'warning_level=2',
  ],
)

gbench_dep = dependency('benchmark',
  required: true,
  fallback: ['google-benchmark', 'google_benchmark_dep'],
  default_options: ['tests=disabled'],
)

common_inc = include_directories('src')
perf_src   = 'src/measurement/perf_counter.cpp'

workload      = get_option('workload')
variant       = get_option('variant')
disable_perf  = get_option('disable_perf_counter')

# -----------------------------------------------------------------------------
# PARTICLE WORKLOAD
# -----------------------------------------------------------------------------

if workload == 'particle'

  if variant == 'soa'
    _cpp_args  = ['-DLAYOUT_SOA']
    _layout_src = 'src/particle/variants/soa_layout.cpp'
  elif variant == 'aligned'
    _cpp_args  = ['-DLAYOUT_ALIGNED']
    _layout_src = 'src/particle/variants/aligned_layout.cpp'
  else  # aos (default)
    _cpp_args  = []
    _layout_src = 'src/particle/variants/aos_layout.cpp'
  endif

  if disable_perf
    _cpp_args += ['-DDISABLE_PERF_COUNTER']
  endif

  executable('particle_' + variant,
    sources: [
      perf_src,
      _layout_src,
      'src/particle/benchmarks/particle_bench.cpp',
    ],
    include_directories: common_inc,
    cpp_args: _cpp_args,
    dependencies: gbench_dep,
  )

  executable('particle_runner_' + variant,
    sources: [
      _layout_src,
      'src/particle/simulation/particle_runner.cpp',
    ],
    include_directories: common_inc,
    cpp_args: _cpp_args,
  )

# -----------------------------------------------------------------------------
# MATRIX WORKLOAD
# -----------------------------------------------------------------------------

elif workload == 'matrix'

  if variant == 'row_major'
    _cpp_args  = ['-DLAYOUT_ROW_MAJOR']
    _layout_src = 'src/matrix/variants/row_major.cpp'
  else  # tile_contiguous (default)
    _cpp_args  = []
    _layout_src = 'src/matrix/variants/tile_contiguous.cpp'
  endif

  if disable_perf
    _cpp_args += ['-DDISABLE_PERF_COUNTER']
  endif

  executable('matrix_' + variant,
    sources: [
      perf_src,
      _layout_src,
      'src/matrix/benchmarks/matrix_bench.cpp',
    ],
    include_directories: common_inc,
    cpp_args: _cpp_args,
    dependencies: gbench_dep,
  )

  executable('matrix_runner_' + variant,
    sources: [
      _layout_src,
      'src/matrix/simulation/matrix_runner.cpp',
    ],
    include_directories: common_inc,
    cpp_args: _cpp_args,
  )

endif
