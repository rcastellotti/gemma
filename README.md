# GEMM{Android, AMD, Apple Silicon}

pardon my french across the entire report, i'd rather have you think i am a skid than have you try to eyeball whether
this was gippity generated

## benchmarking methodology

how do we benchmark some function? is this a good way?

```c
start = clock();
gemm_kernel(...);
end = clock();
time = end - start;
```

well, no, as it turns out it's a very bad idea, and for several different reasons:

1. `clock()` from `time.h` measures CPU time, not actual elapsed time (wall clock)
2. multithreading breaks the interpretation
3. granularity might introduce significant errors for the fastest kernels
4. it does not measure GPU/DSP time

let's cover every case before discussing what to use instead:

### CPU time vs wall clock

CPU time is a measure of how much time the CPU spends executing a process, so, if the OS scheduler decides to pull a
prank on us and deschedule a process for, let's say 2ms, something that ran in 10 ms can be reported as having run for
8ms, that's bad.

### multithreading breaks the interpretation

let's say we break up some operation in mutliple threads and it runs for 10ms per core across 4 cores. on POSIX systems
`clock()` accumulates time across different threads, so an operation that took 10ms in total would be reported as having
run for 40ms. if we were to use that time as a measurement of GFLOPs with the following formula:

$$ \text{GFLOP/s}=\frac{2MNK}{t\cdot10^9} $$

we would be off of a factor of 4, that too is bad.

## granularity might introduce significant errors for the fastest kernels

`clock()` returns a value of type `clock_t`, which can be converted to seconds using `CLOCKS_PER_SEC` (typically defined
at `1_000_000`, one microsecond). for small and very fast GEMM kernels executing in hundreds of microseconds this
introduces significant errors, additionally `CLOCKS_PER_SEC` deos not represent CPU frequency nor actual timer
resolution, you guessed it, that too is bad.

## it does not measure GPU/DSP time

the moment we offload computation to a GPU or DSP we are totally lost, the accelerators might be computing bilions of
floating point operations while the CPU is simply waiting for them, bad bad!!!

adopting a monotonic (always increasing) wall-clock fixes every problem above:

````c #include <stdint.h> #include <time.h> static inline uint64_t now_ns(void) { struct timespec ts;
clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec; } ```

then:

```c uint64_t start = now_ns(); gemm(...); uint64_t elapsed = now_ns() - start; ```

ok, so, good to go? not quite, when running the 16x16x16 case it takes approximately 1.4 microseconds, reading the clock
itself costs some CPU cycles and it can easily be a non-negligible percentage of the measurement, thus it seems
reasonable to time many calls in batch and then compute the average execution time, a first improvement would be:

```c #define ITERATIONS 10000 start = now_ns(); for (i = 0; i < ITERATIONS; i++) gemm_kernel(...); end = now_ns();
time_per_call = (end - start) / ITERATIONS; ```

now the execution time is ~14ms and clock-reading error is negligible, however as we scale the dimension of inputs it is
simply unfeasible to run the benchmark 10 thousand times. There simply is not a single call count working for every test
case, so we introduce a _calibration_ loop, in which we increase the count exponentially until we reach a suitable
iteration number:

```c #define TARGET_TIME 0.05 #define MAX_ITERS ((size_t)1 << 20)

while (1) { double elapsed = run_batch(fn, M, N, K, A, B, C, iterations); if (elapsed >= TARGET_TIME || iterations >=
MAX_ITERS) { break; } iterations *= 2; } ```

`TARGET_TIME` is a constant we can tweak but 0.05 seems reasonable, we add an upper boundary just for good measure, once
we determine the iterations we can use it as we did before.

additionally, many other phenomena could influence our measurements, such as:

- CPU frequency wobble
- OS scheduling
- Cache state
- Background processes

we can mitigate those by simply running a benchmark, for example, 9 times and computing the median execution time, and i
actually mean the median, not the average, to make our measurements more resistant to unfortunate sheduling events and
other outliers, sort and pick the median, that's it.

```python # perdoname por mi python loquito times = [10.2, 10.1, 10.3, 48.7, 10.0, 10.2, 10.1, 25.4, 10.3]

times.sort() # [10.0, 10.1, 10.1, 10.2, 10.2, 10.3, 10.3, 25.4, 48.7]

median = times[len(times) // 2] # 10.20 ms mean = sum(times) / len(times) # 16.14 ms ```

GIPPITY SLOP, am tired

You can conclude the section with the following, keeping the same informal style:

once we put everything together, the final benchmarking methodology looks something like this:

``` #define TARGET_TIME 0.05 #define MAX_ITERS ((size_t)1 << 20) #define SAMPLES 9

static double run_batch( gemm_fn fn, size_t M, size_t N, size_t K, const float *A, const float *B, float *C, size_t
iterations ) { uint64_t start = now_ns();

    for (size_t i = 0; i < iterations; i++) { fn(M, N, K, A, B, C); }

    return (double)(now_ns() - start) / 1e9; }

static int compare_double(const void *a, const void *b) { double x = *(const double *)a; double y = *(const double *)b;
return (x > y) - (x < y); }

static double benchmark( gemm_fn fn, size_t M, size_t N, size_t K, const float *A, const float *B, float *C ) { size_t
iterations = 1; double samples[SAMPLES];

    // 1. warm up fn(M, N, K, A, B, C);

    // 2. calibrate while (1) { double elapsed = run_batch( fn, M, N, K, A, B, C, iterations );

        if (elapsed >= TARGET_TIME || iterations >= MAX_ITERS) break;

        iterations *= 2; }

    // 3. collect samples (seconds per call) for (size_t i = 0; i < SAMPLES; i++) { samples[i] = run_batch( fn, M, N, K,
    A, B, C, iterations ) / iterations; }

    // 4. sort and return the median qsort(samples, SAMPLES, sizeof(double), compare_double);

    return samples[SAMPLES / 2]; } ```

finally, we can compute the execution time in milliseconds and the throughput in GFLOP/s:

``` double seconds = benchmark(fn, M, N, K, A, B, C);

double ms = seconds * 1e3; double gflops = (2.0 * M * N * K) / (seconds * 1e9); ```

so, to recap, we do: calibration loop, execute bench 9 times, sort samples, compute median

### **A few technical corrections to your existing text**

- **Hundreds of microseconds:** you probably mean hundreds of nanoseconds or a few microseconds. A microsecond of
  granularity is relatively insignificant for a kernel taking hundreds of microseconds.
- **Monotonic (always increasing):** technically, monotonic means non-decreasing. Two consecutive readings can return
  the same value.
- **Fixes every problem above:** GPU/DSP execution still requires explicit synchronization if operations are
  asynchronous.
- **Cache state:** taking the median does not eliminate systematic cache effects. Repeatedly operating on the same
  matrices primarily measures warmed-up, steady-state performance.
- **Repeated execution:** the code assumes each GEMM invocation overwrites `C`. If your kernel accumulates into `C`, you
  need to account for that when designing the benchmark.
- **Compiler optimizations:** ensure the compiler cannot eliminate redundant kernel invocations, particularly when
  enabling LTO.

The final implementation assumes synchronous CPU kernels and measures steady-state throughput rather than cold-start
latency.

claude slop

# Review of what you have

The structure is right: batch many calls, then divide. The calibration loop is a good idea. A few issues, some small and
some real.

**Mistakes and nitpicks**

- **Math inconsistency.** 10,000 × 1.4 µs = 14 ms, which matches your text. But 14 ms is _below_ your own `TARGET_TIME`
  of 50 ms, so the calibration loop would keep doubling for this case. That's fine, but the "10000 is enough" narrative
  and the calibration narrative don't quite line up. Worth saying "10,000 was an arbitrary guess; calibration replaces
  it."
- **`/ 10000` should be `/ ITERATIONS`.** Hardcoded duplicate of the macro.
- **`clock()` is the wrong clock.** It measures _CPU time_ (and on some platforms has coarse resolution, e.g.
  `CLOCKS_PER_SEC` granularity). You want wall-clock time from a monotonic source: `clock_gettime(CLOCK_MONOTONIC)` on
  Linux/Android, `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` or `mach_absolute_time()` on Apple Silicon, and
  `QueryPerformanceCounter` on Windows. Monotonic matters because `gettimeofday` can jump if NTP adjusts the clock. If
  you want to exclude time your process was descheduled, CPU time is arguably _useful_, but then say so deliberately.
- **Calibration result is noisy.** The `iterations` you land on is "the first power of two that exceeded 50 ms," so
  actual batch time lands anywhere in 50-100 ms. That's fine, but the calibration batches themselves also double as
  warmup, so don't throw that observation away (see below).
- **The calibration measurement is itself a sample.** Don't reuse it as your result; run fresh batches afterward.
- **One batch gives you one number.** The biggest conceptual gap: averaging hides variance. You want multiple batches
  (repetitions) and statistics across them.

**Subtle trap: the compiler**

If `gemm_kernel` is visible in the same translation unit, with the same inputs every iteration and `C` never read, the
optimizer may hoist, merge, or delete the calls. Defenses:

- Put the kernel in a separate translation unit (or mark it `noinline`), and avoid LTO for the benchmark harness.
- Use a compiler barrier / `DoNotOptimize`-style trick: ```c asm volatile("" : : "r"(C) : "memory"); ```
- Consume the output at the end (checksum `C`) and print it.

# Your list, item by item

**Warmup** Run the kernel a few times (or a short batch) before measuring. First calls pay for cold instruction cache,
cold data caches, TLB misses, page faults on first touch of freshly allocated `A/B/C`, lazy dynamic linking, branch
predictor training, and on some chips, wake-up of SIMD/matrix units (AVX-512 and AMX warm-up is a real thing on x86;
Apple's AMX/SME paths can also show first-use latency). Also touch/initialize all buffers _before_ timing so page faults
don't land in the measurement.

**Clock read cost / timer resolution** Batching handles the overhead; the rule of thumb is that the timed region should
be ≥1000× the timer resolution + read cost. Measure it: call the clock in a tight loop to find the minimum delta
(resolution) and the per-call cost. Resolution varies a lot: nanoseconds on Linux/macOS, but coarser on some Android
devices and VMs.

**OS interrupts / scheduling / background processes** These cause outliers: occasional runs that are 2-10× slower.
Mitigations:

- Repeat many batches and report **median** (and min, and spread), not just mean. Mean is dragged by outliers. For "what
  can this code achieve," **min** is often the most informative; for "what will users see," median/percentiles.
- Pin to a core (`taskset`/`sched_setaffinity` on Linux/Android; macOS doesn't support hard pinning, but QoS classes
  help).
- Quiet the machine: close apps, disable indexing/updates, plug in power.
- On Linux, consider `chrt`/real-time priority, isolated cores (`isolcpus`), and disabling SMT for cleaner results.

**CPU frequency scaling / frequency wobble / thermal throttling** This is _the_ big one on your three platforms, and it
differs per platform:

- **Android:** big.LITTLE (or tri-cluster) scheduling. Your thread can migrate between efficiency and performance cores
  mid-run, and the governor ramps frequency up with load (so early runs are slower) and thermally throttles under
  sustained load. Pin to a specific big core, set the governor to `performance` if you have root, check thermal state,
  and let the phone cool between runs. Report which core and frequency you measured on.
- **Apple Silicon:** P-cores vs E-cores, chosen by the scheduler based on QoS. Run at `QOS_CLASS_USER_INTERACTIVE` or
  `USER_INITIATED` to bias toward P-cores. No governor control, but sustained runs on a MacBook Air (no fan) will
  throttle; Mac Studio/Pro less so.
- **AMD:** boost behavior (Precision Boost) varies with temperature, power limit, and how many cores are active. Set the
  governor to `performance`, consider disabling boost for _reproducibility_ (at the cost of realism), and watch for AVX
  frequency effects on some parts.

Whatever you choose, **record the frequency** (via `perf stat` cycles / time, or reading `scaling_cur_freq`) so you can
also report in cycles, not just seconds.

**Cache state** Decide what you're measuring and be explicit:

- **Hot cache** (same buffers every call): measures compute-bound peak. Small matrices will sit entirely in L1/L2, which
  flatters the result.
- **Cold / realistic cache**: rotate through a pool of distinct buffers larger than last-level cache, or flush between
  calls (`clflush` on x86; ARM has `dc civac`, though user-space access is restricted on some systems). This measures
  what you'd see inside a real application.

For GEMM, hot-cache numbers are the standard convention for peak-performance comparison, but say so in the writeup, and
consider running both for small sizes. Also watch **alignment** and **4K aliasing**: allocate with fixed alignment (e.g.
64 bytes or page) so a lucky/unlucky `malloc` doesn't change results between runs.

# What else to consider

1. **Report GFLOP/s, not just time.** For GEMM, FLOPs = 2·M·N·K. That lets you compare across sizes and against the
hardware's theoretical peak (cores × freq × FMA units × SIMD width × 2). "Percent of peak" is the most meaningful
number. 2. **Correctness check.** Verify output against a reference implementation (with a tolerance for floating-point
reordering) _outside_ the timed region. A fast wrong kernel is worthless, and a kernel that skips work can look amazing.
3. **Data values matter.** Denormals can make floating-point 10-100× slower; all-zeros inputs can enable power savings
or shortcuts on some hardware. Use realistic random data in a sane range. Initialize `C` consistently (especially if the
kernel does `C += A·B`, where repeated iterations make values grow toward inf/NaN or denormals). 4. **Sweep sizes
intelligently.** Powers of two can hit cache associativity pathologies; test non-powers of two, odd sizes, and
edge/remainder cases (e.g. 17, 63, 65, 255). 5. **Single-thread vs multi-thread.** State which you're measuring.
Multi-threaded runs add thread-pool startup, synchronization cost, NUMA effects (AMD EPYC/Threadripper especially), and
shared-cache contention. 6. **Compare compiler, flags, and build.** `-O3 -march=native` vs a portable build can differ
massively. Record the compiler version and flags. Make sure you're benchmarking a release build. 7. **Memory/power side
effects.** Long sustained runs hit thermals; very short ones don't. Consider interleaving the implementations you're
comparing (A, B, A, B…) instead of running all of A then all of B, so drift in thermal state or background load affects
both equally. 8. **Report the environment.** CPU model, core used, OS/kernel version, compiler, flags, power mode,
battery vs plugged in. Without this the numbers aren't reproducible. 9. **Statistics, not a single number.** Report
median, min, and a spread (stddev, or p5-p95 / IQR), plus the number of repetitions. A rough rule: if run-to-run
variation exceeds the difference you're trying to detect, you can't claim a win. For A/B comparisons, consider a proper
test or at least non-overlapping confidence intervals. 10. **Use hardware counters when you can.** `perf stat`
(Linux/Android), Instruments (Apple), `uProf` (AMD). Cycles, instructions, cache misses, and IPC explain _why_ something
is fast or slow, and cycle counts are frequency-independent. 11. **Use a proven harness.** Google Benchmark, or
Criterion in Rust, already implement calibration, warmup, optimizer barriers, and statistics. Your hand-rolled version
is great for learning and for keeping the repo dependency-free; just know what it's re-implementing.

# A sketch of the improved loop

```c // 1. setup: allocate aligned buffers, initialize with random data, verify correctness // 2. pin thread / set QoS
// 3. warmup: run kernel for ~100-200 ms // 4. calibrate iterations so one batch ≈ TARGET_TIME // 5. for rep in 0..REPS
(say 15-30): // t[rep] = run_batch(iterations) / iterations // monotonic clock // (interleave with other implementations
if comparing) // 6. report min, median, spread; GFLOP/s = 2*M*N*K / t / 1e9 // 7. consume results (checksum) so the
compiler can't elide work ```

If you want, I can write this out as real C for the three platforms, including the per-platform timer and core-pinning
bits.
````
