# Concurrency in the `Vector` type

The `Vector` type in `Prometheus.Metric.Vector` uses an `IORef (Map l (Metric m))`.
This is a known antipattern for poor performance.
The proper fix is to use the [`stm-containers`](https://nikita-volkov.github.io/stm-containers/) which allows signifiacntly better concurrent updates to the `Map`.

The problem is that the `Vector` requires a lock on the entire `Map` in order to update a single value.
Suppose you have 200 threads, each wanting to update the `Map`.
The first will do `atomicModifyIORef`, which will grab a lock on the map.
Every other thread is now blocked.
The first thread will update the label `k0` and put the map back in.
The next thread will now lock the whole map for label `k1`.
Rinse and repeat.

With `StmContainers.Map`, the *key* is locked - so there is only contention on specific keys.
If 200 threads want to update the map, and they all have distinct keys, then this can all happen concurrently without any locking or STM retrying.

# Benchmarks

To understand this behavior, I created a benchmark that would concurrently make many writes to a `Vector`.

To measure impact of concurrency, I am going to iterate this with `-with-rtsopts=-Nx`.

I am using an Intel i9 with 32 cores.

NOTE: Oops. This code is not faithful to Hackage/released code.
The released code uses `Data.Atomics.atomicModifyIORefCAS`, which avoids the locking and contention.
However, I'm going to leave the benchmarks here because they're *very* interesting as a way of seeing how `Data.Atomics.atomicModifyIORefCAS` compares to `Data.IORef.atomicModifyIORef'`.

## `-N1`

```
benchmarking Vector/increment all combinations concurrently
time                 474.6 ms   (429.8 ms .. 514.9 ms)
                     0.999 R²   (0.996 R² .. 1.000 R²)
mean                 511.6 ms   (493.2 ms .. 529.9 ms)
std dev              21.50 ms   (18.13 ms .. 24.06 ms)
variance introduced by outliers: 19% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 194.4 ms   (184.5 ms .. 201.0 ms)
                     0.999 R²   (0.994 R² .. 1.000 R²)
mean                 202.3 ms   (197.9 ms .. 206.2 ms)
std dev              5.733 ms   (3.561 ms .. 8.113 ms)
variance introduced by outliers: 14% (moderately inflated)
```

In a single threaded context, `stm-containers` is still over twice as fast.

## `-N2`


```
benchmarking Vector/increment all combinations concurrently
time                 791.9 ms   (780.6 ms .. 800.9 ms)
                     1.000 R²   (1.000 R² .. 1.000 R²)
mean                 789.9 ms   (787.3 ms .. 791.3 ms)
std dev              2.581 ms   (5.418 μs .. 3.169 ms)
variance introduced by outliers: 19% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 110.8 ms   (108.3 ms .. 113.4 ms)
                     0.999 R²   (0.997 R² .. 1.000 R²)
mean                 113.8 ms   (112.3 ms .. 115.4 ms)
std dev              2.452 ms   (1.767 ms .. 3.111 ms)
variance introduced by outliers: 11% (moderately inflated)
```

With two threads, the normal vector encounters contention and becomes significantly slower (1.6x more time).
Meanwhile, the STM vector takes 56% the time.

## `-N4`

```
benchmarking Vector/increment all combinations concurrently
time                 862.9 ms   (812.8 ms .. 918.9 ms)
                     0.999 R²   (0.999 R² .. 1.000 R²)
mean                 849.7 ms   (837.4 ms .. 857.4 ms)
std dev              12.52 ms   (4.446 ms .. 15.37 ms)
variance introduced by outliers: 19% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 67.63 ms   (64.95 ms .. 69.86 ms)
                     0.997 R²   (0.995 R² .. 0.999 R²)
mean                 65.72 ms   (64.07 ms .. 66.88 ms)
std dev              2.405 ms   (1.510 ms .. 3.519 ms)
```

With four threads, contention on the traditional `Vector` is high, and we take even more time - however, it's a modest increase.
The STM vector improves performance significantly again - taking 57% of the time of using 2 threads.

## `-N8`

```
benchmarking Vector/increment all combinations concurrently
time                 1.043 s    (981.4 ms .. 1.099 s)
                     1.000 R²   (0.998 R² .. 1.000 R²)
mean                 954.4 ms   (890.9 ms .. 984.0 ms)
std dev              50.79 ms   (26.11 ms .. 62.92 ms)
variance introduced by outliers: 19% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 43.53 ms   (42.78 ms .. 44.29 ms)
                     0.999 R²   (0.997 R² .. 1.000 R²)
mean                 43.83 ms   (43.26 ms .. 44.58 ms)
std dev              1.254 ms   (919.2 μs .. 1.745 ms)
```

The pattern repeats: contention makes the `IORef` vector slower (120% prior time), while more threads makes STM faster (64% of the time).

## `-N16`

```
benchmarking Vector/increment all combinations concurrently
time                 2.415 s    (2.019 s .. 2.984 s)
                     0.994 R²   (0.982 R² .. 1.000 R²)
mean                 2.603 s    (2.461 s .. 2.805 s)
std dev              191.8 ms   (71.20 ms .. 244.5 ms)
variance introduced by outliers: 21% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 44.69 ms   (43.21 ms .. 46.21 ms)
                     0.998 R²   (0.996 R² .. 0.999 R²)
mean                 48.07 ms   (46.33 ms .. 51.82 ms)
std dev              4.928 ms   (1.915 ms .. 7.111 ms)
variance introduced by outliers: 41% (moderately inflated)
```

With 16 threads, contention has almost doubled the time on the `IORef`.
Meanwhile, the `STM` implementation has stabilized around 45ms.

# Oops

At this point, I realize an error that I have made.
The Hackage version of code uses `Data.Atomics.atomicModifyIORefCAS`, but I have switched it to `atomicModifyIORef'`.
If I switch it back and rerun, I get significantly better results:

## `-N1`

```
benchmarking Vector/increment all combinations concurrently
time                 144.2 ms   (137.9 ms .. 152.0 ms)
                     0.998 R²   (0.995 R² .. 1.000 R²)
mean                 141.7 ms   (140.2 ms .. 143.8 ms)
std dev              2.614 ms   (1.425 ms .. 3.817 ms)
variance introduced by outliers: 12% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 207.0 ms   (182.7 ms .. 230.8 ms)
                     0.994 R²   (0.979 R² .. 1.000 R²)
mean                 203.6 ms   (197.3 ms .. 209.6 ms)
std dev              8.605 ms   (6.082 ms .. 10.73 ms)
variance introduced by outliers: 14% (moderately inflated)
```

With a single threaded implementation, the stock implementation is faster.
STM is about 33% slower.

## `-N2`

```
benchmarking Vector/increment all combinations concurrently
time                 122.5 ms   (120.4 ms .. 124.6 ms)
                     1.000 R²   (1.000 R² .. 1.000 R²)
mean                 119.4 ms   (118.1 ms .. 120.5 ms)
std dev              1.858 ms   (1.325 ms .. 2.617 ms)
variance introduced by outliers: 11% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 110.9 ms   (104.2 ms .. 116.0 ms)
                     0.997 R²   (0.995 R² .. 1.000 R²)
mean                 115.6 ms   (113.3 ms .. 118.4 ms)
std dev              3.859 ms   (2.682 ms .. 5.249 ms)
variance introduced by outliers: 11% (moderately inflated)
```

Stock implementation is slightly faster with two threads. 
STM implemenation is almost twice as fast, and is now slightly faster.

## `-N4`

```
benchmarking Vector/increment all combinations concurrently
time                 99.45 ms   (98.89 ms .. 100.6 ms)
                     1.000 R²   (1.000 R² .. 1.000 R²)
mean                 98.95 ms   (98.27 ms .. 99.38 ms)
std dev              875.4 μs   (576.1 μs .. 1.230 ms)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 58.75 ms   (57.62 ms .. 59.41 ms)
                     1.000 R²   (0.999 R² .. 1.000 R²)
mean                 59.72 ms   (59.11 ms .. 60.80 ms)
std dev              1.487 ms   (589.8 μs .. 2.436 ms)
```

With 4 threads, both see significant performance improvements, with STm gaining more of a lead.

## `-N8`

```
benchmarking Vector/increment all combinations concurrently
time                 105.3 ms   (104.1 ms .. 108.0 ms)
                     0.999 R²   (0.998 R² .. 1.000 R²)
mean                 105.0 ms   (104.0 ms .. 106.1 ms)
std dev              1.664 ms   (1.196 ms .. 2.480 ms)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 39.39 ms   (38.23 ms .. 40.39 ms)
                     0.998 R²   (0.996 R² .. 1.000 R²)
mean                 40.21 ms   (39.74 ms .. 40.54 ms)
std dev              780.2 μs   (546.1 μs .. 1.251 ms)
```

With 8 cores, performance of the `IORef` has stabilized.
The `STM` implementation continues to improve.

## `-N16`

```
benchmarking Vector/increment all combinations concurrently
time                 153.0 ms   (148.8 ms .. 154.1 ms)
                     1.000 R²   (0.999 R² .. 1.000 R²)
mean                 152.8 ms   (151.7 ms .. 153.4 ms)
std dev              1.213 ms   (511.2 μs .. 1.869 ms)
variance introduced by outliers: 12% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 44.94 ms   (43.59 ms .. 47.01 ms)
                     0.995 R²   (0.989 R² .. 0.999 R²)
mean                 45.78 ms   (44.95 ms .. 46.58 ms)
std dev              1.609 ms   (1.311 ms .. 2.102 ms)
```

At 16 cores, contention on the IORef increases overhead.
STM appears stable.

## `-N32`

```
benchmarking Vector/increment all combinations concurrently
time                 3.400 s    (654.0 ms .. 4.890 s)
                     0.921 R²   (NaN R² .. 1.000 R²)
mean                 3.877 s    (3.432 s .. 4.264 s)
std dev              457.1 ms   (376.4 ms .. 523.3 ms)
variance introduced by outliers: 23% (moderately inflated)
                               
benchmarking Vector.STM/increment all combinations concurrently
time                 51.69 ms   (50.44 ms .. 53.48 ms)
                     0.997 R²   (0.994 R² .. 1.000 R²)
mean                 52.45 ms   (51.51 ms .. 55.21 ms)
std dev              2.943 ms   (1.060 ms .. 5.225 ms)
variance introduced by outliers: 14% (moderately inflated)
```

With 32 cores, `STM` is constant and even the atomic IORef runs into significant contention.

# Defaults

Based on these observations, this commit changes the default exported in `Prometheus` to the STM vector.
