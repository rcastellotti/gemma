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

## la cura (battiato)

adopting a monotonic (strictly non-decrasing) wall-clock fixes every problem above:

```c
#include <stdint.h>
#include <time.h>

static inline uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
```

then:

```c
uint64_t start = now_ns();
gemm(...);
uint64_t elapsed = now_ns() - start;
```

ok, so, good to go? not quite, when running the 16x16x16 case execution takes approximately 1.4 microseconds, reading the clock
itself costs some CPU cycles and it can easily be a non-negligible percentage of the measurement, thus it seems
reasonable to time many calls in batch and then compute the average execution time, a first improvement would be:

```c
#define ITERATIONS 10000
start = now_ns();
for (i = 0; i < ITERATIONS; i++) {
  gemm_kernel(...);
}
end = now_ns();
time_per_call = (end - start) / ITERATIONS;
```

now the execution time is ~14ms and clock-reading error is negligible, however as we scale the dimension of inputs it is
simply unfeasible to run the benchmark 10 thousand times. There simply is not a single call count working for every test
case, so we introduce a _calibration_ loop, in which we increase the count exponentially until we reach a suitable
iteration number:

```c
#define TARGET_TIME 0.05
#define MAX_ITERS ((size_t)1 << 20)

while (1) {
  double elapsed = run_batch(fn, M, N, K, A, B, C, iterations);
  if (elapsed >= TARGET_TIME || iterations >=MAX_ITERS) {
    break;
  }
iterations *= 2;
}
```

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

```python3
#perdoname por mi python loquito
times = [10.2, 10.1, 10.3, 48.7, 10.0, 10.2, 10.1, 25.4, 10.3]
times.sort() # [10.0, 10.1, 10.1, 10.2, 10.2, 10.3, 10.3, 25.4, 48.7]
median = times[len(times) // 2] # 10.20ms
mean = sum(times) / len(times) # 16.14 ms
```

once we put everything together, the final benchmarking methodology looks something like this:

````c
#define TARGET_TIME 0.05
#define MAX_ITERS ((size_t)1 << 20)
#define SAMPLES 9

static double run_batch(gemm_fn fn,
                        size_t M, size_t N, size_t K,
                        const float *A, const float *B, float *C,
                        size_t iterations ) {
    uint64_t start = now_ns();
    for (size_t i = 0; i < iterations; i++) {
      fn(M, N, K, A, B, C);
    }
    return (double)(now_ns() - start) / 1e9;
}

static double benchmark(gemm_fn fn,
                        size_t M, size_t N, size_t K,
                        const float *A, const float *B, float *C ) {
  size_t iterations = 1; double samples[SAMPLES];

  // 1. warm up
  fn(M, N, K, A, B, C);

  // 2. calibrate
  while (1) {
    double elapsed = run_batch( fn, M, N, K, A, B, C, iterations );
    if (elapsed >= TARGET_TIME || iterations >= MAX_ITERS) break;
    iterations *= 2;
  }

  // 3. collect samples (seconds per call)
  for (size_t i = 0; i < SAMPLES; i++) {
    samples[i] = run_batch( fn, M, N, K, A, B, C, iterations ) / iterations;
  }

  // 4. sort and return the median
  qsort(samples, SAMPLES, sizeof(double), compare_double);
  return samples[SAMPLES / 2];
}```

finally, we can compute the execution time in milliseconds and the throughput in GFLOP/s:

``` double seconds = benchmark(fn, M, N, K, A, B, C);

double ms = seconds * 1e3; double gflops = (2.0 * M * N * K) / (seconds * 1e9); ```

so, to recap, we do: calibration loop, execute bench 9 times, sort samples, compute median

### **A few technical corrections to your existing text**

- **Hundreds of microseconds:** you probably mean hundreds of nanoseconds or a few microseconds. A microsecond of
  granularity is relatively insignificant for a kernel taking hundreds of microseconds.

- **Compiler optimizations:** ensure the compiler cannot eliminate redundant kernel invocations, particularly when
  enabling LTO.

The final implementation assumes synchronous CPU kernels and measures steady-state throughput rather than cold-start
latency.
````
