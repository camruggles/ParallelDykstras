# ParallelDykstras

Code for metric-constrained optimization problems using a parallelized version of Dykstra's projection algorithms, specifically for metric constraints. 

This is a parallelized version of previous code for projection methods for metric-constrained optimization: https://github.com/nveldt/MetricOptimization


The test file Test_MetricOpt-1.0.jl gives a simple example for how to use this code on the 34 node Karate network, in Julia 1.0.

ParallelCC.jl and ParallelSC.jl provide code that works for Julia version 0.6.
