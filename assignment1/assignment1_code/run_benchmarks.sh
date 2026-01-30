#!/bin/bash
cd "/homes/l/lihuan10/ECE1755:parallel/assignment1/assignment1_code"

echo "=========================================="
echo "BASELINE BEAMFORM BENCHMARKS"
echo "=========================================="

for size in 16 32 64; do
    echo ""
    echo "--- Baseline Size $size ---"
    ./beamform $size 2>&1 | grep "Elapsed"
    ./beamform $size 2>&1 | grep "Elapsed"
    ./beamform $size 2>&1 | grep "Elapsed"
    ./solution_check $size
done

echo ""
echo "=========================================="
echo "OPTIMIZED BEAMFORM_MT BENCHMARKS"
echo "=========================================="

for size in 16 32 64; do
    for threads in 1 2 4 8 16; do
        echo ""
        echo "--- beamform_mt $threads threads, Size $size ---"
        ./beamform_mt $threads $size 2>&1 | grep "Elapsed"
        ./beamform_mt $threads $size 2>&1 | grep "Elapsed"
        ./beamform_mt $threads $size 2>&1 | grep "Elapsed"
        ./solution_check $size
    done
done

echo ""
echo "=========================================="
echo "AVX-2 BEAMFORM_AVX2 BENCHMARKS"
echo "=========================================="

for size in 16 32 64; do
    for threads in 1 2 4 8 16; do
        echo ""
        echo "--- beamform_avx2 $threads threads, Size $size ---"
        ./beamform_avx2 $threads $size 2>&1 | grep "Elapsed"
        ./beamform_avx2 $threads $size 2>&1 | grep "Elapsed"
        ./beamform_avx2 $threads $size 2>&1 | grep "Elapsed"
        ./solution_check $size
    done
done

echo ""
echo "=========================================="
echo "BENCHMARKS COMPLETE"
echo "=========================================="
