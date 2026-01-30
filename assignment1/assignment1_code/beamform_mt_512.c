#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/time.h>
#include <stdint.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#include <immintrin.h>

#define ALIGNMENT 64

static const float idx_const_inv = 1.0f / 0.000009625f;
static const int filter_delay = 140;

typedef struct {
    int point_start;
    int point_end;
    int data_len;
    int rx_total;

    const float *rx_x;
    const float *rx_y;

    const float *point_x;
    const float *point_y;
    const float *point_z;
    const float *dist_tx;
    const float *rx_data;

    float *image;
    int thread_id;
} Task;

// Use hardware sqrt for correctness (AVX-512 has fast sqrt)
#define fast_sqrt_512(x) _mm512_sqrt_ps(x)

#define BLOCK_SIZE 32768

static void *worker(void *arg)
{
    Task *t = (Task *)arg;

    // Pin thread to core
    int num_cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (num_cores > 0) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        CPU_SET(t->thread_id % num_cores, &cpuset);
        pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    }

    const float * __restrict__ point_x = t->point_x;
    const float * __restrict__ point_y = t->point_y;
    const float * __restrict__ point_z = t->point_z;
    const float * __restrict__ dist_tx = t->dist_tx;
    const float * __restrict__ rx_x = t->rx_x;
    const float * __restrict__ rx_y = t->rx_y;
    const float * __restrict__ rx_data = t->rx_data;
    float * __restrict__ image = t->image;

    const int data_len = t->data_len;
    const int rx_total = t->rx_total;
    const int point_start = t->point_start;
    const int point_end = t->point_end;

    const __m512 v_idx_const_inv = _mm512_set1_ps(idx_const_inv);
    const __m512 v_filter_delay = _mm512_set1_ps((float)filter_delay + 0.5f);
    const __m512 v_zero = _mm512_setzero_ps();

    // Align to cache line
    float image_buffer[BLOCK_SIZE] __attribute__((aligned(64)));

    for (int p_base = point_start; p_base < point_end; p_base += BLOCK_SIZE) {
        int p_limit = (p_base + BLOCK_SIZE < point_end) ? p_base + BLOCK_SIZE : point_end;
        int block_len = p_limit - p_base;

        // Zero the buffer
        memset(image_buffer, 0, block_len * sizeof(float));

        // Process all transducers for this block - 4 at a time for balance between registers and ILP
        int it_rx = 0;
        for (; it_rx + 3 < rx_total; it_rx += 4) {
            const __m512 v_rxx0 = _mm512_set1_ps(rx_x[it_rx]);
            const __m512 v_rxy0 = _mm512_set1_ps(rx_y[it_rx]);
            const __m512 v_rxx1 = _mm512_set1_ps(rx_x[it_rx + 1]);
            const __m512 v_rxy1 = _mm512_set1_ps(rx_y[it_rx + 1]);
            const __m512 v_rxx2 = _mm512_set1_ps(rx_x[it_rx + 2]);
            const __m512 v_rxy2 = _mm512_set1_ps(rx_y[it_rx + 2]);
            const __m512 v_rxx3 = _mm512_set1_ps(rx_x[it_rx + 3]);
            const __m512 v_rxy3 = _mm512_set1_ps(rx_y[it_rx + 3]);

            const float *rx_base0 = rx_data + (size_t)it_rx * data_len;
            const float *rx_base1 = rx_data + (size_t)(it_rx + 1) * data_len;
            const float *rx_base2 = rx_data + (size_t)(it_rx + 2) * data_len;
            const float *rx_base3 = rx_data + (size_t)(it_rx + 3) * data_len;

            int k = 0;
            // Main loop: 32 points at a time (2 groups of 16)
            for (; k + 31 < block_len; k += 32) {
                int p = p_base + k;

                // Load first 16 points
                __m512 v_px_a = _mm512_loadu_ps(&point_x[p]);
                __m512 v_py_a = _mm512_loadu_ps(&point_y[p]);
                __m512 v_pz_a = _mm512_loadu_ps(&point_z[p]);
                __m512 v_dtx_a = _mm512_loadu_ps(&dist_tx[p]);
                __m512 v_dz_a = _mm512_sub_ps(v_zero, v_pz_a);
                __m512 v_dz2_a = _mm512_mul_ps(v_dz_a, v_dz_a);

                // Load second 16 points
                __m512 v_px_b = _mm512_loadu_ps(&point_x[p + 16]);
                __m512 v_py_b = _mm512_loadu_ps(&point_y[p + 16]);
                __m512 v_pz_b = _mm512_loadu_ps(&point_z[p + 16]);
                __m512 v_dtx_b = _mm512_loadu_ps(&dist_tx[p + 16]);
                __m512 v_dz_b = _mm512_sub_ps(v_zero, v_pz_b);
                __m512 v_dz2_b = _mm512_mul_ps(v_dz_b, v_dz_b);

                __m512 v_acc_a = _mm512_loadu_ps(&image_buffer[k]);
                __m512 v_acc_b = _mm512_loadu_ps(&image_buffer[k + 16]);

                // Process all 4 transducers x 2 point groups
                #define PROCESS_TX_512(N, base) \
                { \
                    __m512 dx_a = _mm512_sub_ps(v_rxx##N, v_px_a); \
                    __m512 dy_a = _mm512_sub_ps(v_rxy##N, v_py_a); \
                    __m512 sum_a = _mm512_fmadd_ps(dx_a, dx_a, _mm512_fmadd_ps(dy_a, dy_a, v_dz2_a)); \
                    __m512 dist_a = _mm512_add_ps(v_dtx_a, fast_sqrt_512(sum_a)); \
                    __m512i idx_a = _mm512_cvttps_epi32(_mm512_fmadd_ps(dist_a, v_idx_const_inv, v_filter_delay)); \
                    v_acc_a = _mm512_add_ps(v_acc_a, _mm512_i32gather_ps(idx_a, base, 4)); \
                    __m512 dx_b = _mm512_sub_ps(v_rxx##N, v_px_b); \
                    __m512 dy_b = _mm512_sub_ps(v_rxy##N, v_py_b); \
                    __m512 sum_b = _mm512_fmadd_ps(dx_b, dx_b, _mm512_fmadd_ps(dy_b, dy_b, v_dz2_b)); \
                    __m512 dist_b = _mm512_add_ps(v_dtx_b, fast_sqrt_512(sum_b)); \
                    __m512i idx_b = _mm512_cvttps_epi32(_mm512_fmadd_ps(dist_b, v_idx_const_inv, v_filter_delay)); \
                    v_acc_b = _mm512_add_ps(v_acc_b, _mm512_i32gather_ps(idx_b, base, 4)); \
                }

                PROCESS_TX_512(0, rx_base0)
                PROCESS_TX_512(1, rx_base1)
                PROCESS_TX_512(2, rx_base2)
                PROCESS_TX_512(3, rx_base3)
                #undef PROCESS_TX_512

                _mm512_storeu_ps(&image_buffer[k], v_acc_a);
                _mm512_storeu_ps(&image_buffer[k + 16], v_acc_b);
            }

            // Handle remaining 16-point chunks
            for (; k + 15 < block_len; k += 16) {
                int p = p_base + k;

                __m512 v_px = _mm512_loadu_ps(&point_x[p]);
                __m512 v_py = _mm512_loadu_ps(&point_y[p]);
                __m512 v_pz = _mm512_loadu_ps(&point_z[p]);
                __m512 v_dtx = _mm512_loadu_ps(&dist_tx[p]);
                __m512 v_dz = _mm512_sub_ps(v_zero, v_pz);
                __m512 v_dz2 = _mm512_mul_ps(v_dz, v_dz);

                #define COMPUTE_TX_512(N) \
                    __m512 v_dx##N = _mm512_sub_ps(v_rxx##N, v_px); \
                    __m512 v_dy##N = _mm512_sub_ps(v_rxy##N, v_py); \
                    __m512 v_sum##N = _mm512_fmadd_ps(v_dx##N, v_dx##N, _mm512_fmadd_ps(v_dy##N, v_dy##N, v_dz2)); \
                    __m512 v_dist##N = _mm512_add_ps(v_dtx, fast_sqrt_512(v_sum##N)); \
                    __m512i v_idx##N = _mm512_cvttps_epi32(_mm512_fmadd_ps(v_dist##N, v_idx_const_inv, v_filter_delay));

                COMPUTE_TX_512(0)
                COMPUTE_TX_512(1)
                COMPUTE_TX_512(2)
                COMPUTE_TX_512(3)
                #undef COMPUTE_TX_512

                __m512 v_data0 = _mm512_i32gather_ps(v_idx0, rx_base0, 4);
                __m512 v_data1 = _mm512_i32gather_ps(v_idx1, rx_base1, 4);
                __m512 v_data2 = _mm512_i32gather_ps(v_idx2, rx_base2, 4);
                __m512 v_data3 = _mm512_i32gather_ps(v_idx3, rx_base3, 4);

                __m512 v_acc = _mm512_loadu_ps(&image_buffer[k]);
                v_acc = _mm512_add_ps(v_acc, _mm512_add_ps(v_data0, v_data1));
                v_acc = _mm512_add_ps(v_acc, _mm512_add_ps(v_data2, v_data3));
                _mm512_storeu_ps(&image_buffer[k], v_acc);
            }
        }

        // Handle remaining transducers (< 4)
        for (; it_rx < rx_total; ++it_rx) {
            const __m512 v_rxx = _mm512_set1_ps(rx_x[it_rx]);
            const __m512 v_rxy = _mm512_set1_ps(rx_y[it_rx]);
            const float *rx_base = rx_data + (size_t)it_rx * data_len;

            for (int k = 0; k + 15 < block_len; k += 16) {
                int p = p_base + k;
                __m512 v_px = _mm512_loadu_ps(&point_x[p]);
                __m512 v_py = _mm512_loadu_ps(&point_y[p]);
                __m512 v_pz = _mm512_loadu_ps(&point_z[p]);
                __m512 v_dtx = _mm512_loadu_ps(&dist_tx[p]);
                __m512 v_dx = _mm512_sub_ps(v_rxx, v_px);
                __m512 v_dy = _mm512_sub_ps(v_rxy, v_py);
                __m512 v_dz = _mm512_sub_ps(v_zero, v_pz);
                __m512 v_sum = _mm512_fmadd_ps(v_dx, v_dx, _mm512_fmadd_ps(v_dy, v_dy, _mm512_mul_ps(v_dz, v_dz)));
                __m512 v_dist = _mm512_add_ps(v_dtx, fast_sqrt_512(v_sum));
                __m512i v_idx = _mm512_cvttps_epi32(_mm512_fmadd_ps(v_dist, v_idx_const_inv, v_filter_delay));
                __m512 v_data = _mm512_i32gather_ps(v_idx, rx_base, 4);
                __m512 v_acc = _mm512_loadu_ps(&image_buffer[k]);
                _mm512_storeu_ps(&image_buffer[k], _mm512_add_ps(v_acc, v_data));
            }
        }

        // Handle remaining points that don't fit in 16-element vectors (scalar fallback)
        int remaining_start = (block_len / 16) * 16;
        for (int k = remaining_start; k < block_len; ++k) {
            int p = p_base + k;
            float acc = 0.0f;
            float px = point_x[p];
            float py = point_y[p];
            float pz = point_z[p];
            float dtx = dist_tx[p];
            
            for (int rx = 0; rx < rx_total; ++rx) {
                float dx = rx_x[rx] - px;
                float dy = rx_y[rx] - py;
                float dz = 0.0f - pz;
                float dist = dtx + sqrtf(dx * dx + dy * dy + dz * dz);
                int idx = (int)(dist * idx_const_inv + (float)filter_delay + 0.5f);
                acc += rx_data[(size_t)rx * data_len + idx];
            }
            image_buffer[k] = acc;
        }

        memcpy(&image[p_base], image_buffer, block_len * sizeof(float));
    }

    return NULL;
}

static void *aligned_malloc(size_t bytes)
{
    void *ptr = NULL;
    if (posix_memalign(&ptr, ALIGNMENT, bytes) != 0) {
        return NULL;
    }
    return ptr;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        printf("Usage: %s N I\n", argv[0]);
        printf("N = threads (1,2,4,8,16)\n");
        printf("I = input size (16,32,64)\n");
        return -1;
    }

    int n_threads = atoi(argv[1]);
    int size = atoi(argv[2]);

    if (!(size == 16 || size == 32 || size == 64)) {
        printf("Invalid input size.\n");
        return -1;
    }

    if (n_threads < 1) {
        printf("Invalid thread count.\n");
        return -1;
    }

    const int trans_x = 32;
    const int trans_y = 32;
    const int data_len = 12308;
    const int pts_r = 1560;
    const int sls_t = size;
    const int sls_p = size;
    const int total_pts = pts_r * sls_t * sls_p;
    const int rx_total = trans_x * trans_y;

    float *rx_x = aligned_malloc((size_t)rx_total * sizeof(float));
    float *rx_y = aligned_malloc((size_t)rx_total * sizeof(float));
    float *rx_data = aligned_malloc((size_t)data_len * rx_total * sizeof(float));

    float *point_x = aligned_malloc((size_t)total_pts * sizeof(float));
    float *point_y = aligned_malloc((size_t)total_pts * sizeof(float));
    float *point_z = aligned_malloc((size_t)total_pts * sizeof(float));
    float *dist_tx = aligned_malloc((size_t)total_pts * sizeof(float));
    float *image = aligned_malloc((size_t)total_pts * sizeof(float));

    if (!rx_x || !rx_y || !rx_data || !point_x || !point_y || !point_z || !dist_tx || !image) {
        printf("Allocation failed.\n");
        return -1;
    }

    memset(image, 0, (size_t)total_pts * sizeof(float));

    char buff[128];
#ifdef __MIC__
    sprintf(buff, "/beamforming_input_%d.bin", size);
#else
    sprintf(buff, "/cad2/ece1755s/assignment1_data/beamforming_input_%d.bin", size);
#endif

    FILE *input = fopen(buff, "rb");
    if (!input) {
        printf("Unable to open input file %s.\n", buff);
        return -1;
    }

    fread(rx_x, sizeof(float), rx_total, input);
    fread(rx_y, sizeof(float), rx_total, input);
    fread(point_x, sizeof(float), total_pts, input);
    fread(point_y, sizeof(float), total_pts, input);
    fread(point_z, sizeof(float), total_pts, input);
    fread(rx_data, sizeof(float), (size_t)data_len * rx_total, input);
    fclose(input);

    const float tx_x = 0.0f;
    const float tx_y = 0.0f;
    const float tx_z = -0.001f;

    // Vectorized dist_tx computation with AVX-512
    int p = 0;
    __m512 v_tx_x = _mm512_set1_ps(tx_x);
    __m512 v_tx_y = _mm512_set1_ps(tx_y);
    __m512 v_tx_z = _mm512_set1_ps(tx_z);
    for (; p + 15 < total_pts; p += 16) {
        __m512 v_px = _mm512_loadu_ps(&point_x[p]);
        __m512 v_py = _mm512_loadu_ps(&point_y[p]);
        __m512 v_pz = _mm512_loadu_ps(&point_z[p]);
        __m512 v_dx = _mm512_sub_ps(v_tx_x, v_px);
        __m512 v_dy = _mm512_sub_ps(v_tx_y, v_py);
        __m512 v_dz = _mm512_sub_ps(v_tx_z, v_pz);
        __m512 v_sum = _mm512_fmadd_ps(v_dx, v_dx, _mm512_fmadd_ps(v_dy, v_dy, _mm512_mul_ps(v_dz, v_dz)));
        __m512 v_dist = _mm512_sqrt_ps(v_sum);
        _mm512_storeu_ps(&dist_tx[p], v_dist);
    }
    // Scalar fallback for remaining
    for (; p < total_pts; ++p) {
        float dx = tx_x - point_x[p];
        float dy = tx_y - point_y[p];
        float dz = tx_z - point_z[p];
        dist_tx[p] = sqrtf(dx * dx + dy * dy + dz * dz);
    }

    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t start = tv.tv_sec * (uint64_t)1000000 + tv.tv_usec;

    pthread_t *threads = aligned_malloc((size_t)n_threads * sizeof(pthread_t));
    Task *tasks = aligned_malloc((size_t)n_threads * sizeof(Task));

    if (!threads || !tasks) {
        printf("Thread allocation failed.\n");
        return -1;
    }

    int pts_per_thread = total_pts / n_threads;
    int pts_left = total_pts % n_threads;

    int pt_cursor = 0;
    for (int i = 0; i < n_threads; ++i) {
        int chunk = pts_per_thread + (i < pts_left ? 1 : 0);
        tasks[i].point_start = pt_cursor;
        tasks[i].point_end = pt_cursor + chunk;
        pt_cursor += chunk;

        tasks[i].rx_x = rx_x;
        tasks[i].rx_y = rx_y;
        tasks[i].point_x = point_x;
        tasks[i].point_y = point_y;
        tasks[i].point_z = point_z;
        tasks[i].dist_tx = dist_tx;
        tasks[i].rx_data = rx_data;
        tasks[i].image = image;
        tasks[i].data_len = data_len;
        tasks[i].rx_total = rx_total;
        tasks[i].thread_id = i;

        pthread_create(&threads[i], NULL, worker, &tasks[i]);
    }

    for (int i = 0; i < n_threads; ++i) {
        pthread_join(threads[i], NULL);
    }

    gettimeofday(&tv, NULL);
    uint64_t end = tv.tv_sec * (uint64_t)1000000 + tv.tv_usec;
    printf("@@@ Elapsed time (usec): %lu\n", end - start);

    FILE *output = fopen("beamforming_output.bin", "wb");
    fwrite(image, sizeof(float), total_pts, output);
    fclose(output);

    free(tasks);
    free(threads);
    free(rx_x);
    free(rx_y);
    free(rx_data);
    free(point_x);
    free(point_y);
    free(point_z);
    free(dist_tx);
    free(image);

    return 0;
}
