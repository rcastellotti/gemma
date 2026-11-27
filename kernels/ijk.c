#include <stddef.h>

/* Row-major FP32: A[M,K] x B[K,N] -> C[M,N]. */
void gemm_ijk(size_t m, size_t n, size_t k,
              const float *a, const float *b, float *c)
{
    for (size_t i = 0; i < m; ++i) {
        for (size_t j = 0; j < n; ++j) {
            float sum = 0.0f;
            for (size_t p = 0; p < k; ++p) {
                sum += a[i * k + p] * b[p * n + j];
            }
            c[i * n + j] = sum;
        }
    }
}
