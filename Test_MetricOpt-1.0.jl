using MAT


mat = matread("Karate.mat")
A = mat["A"]

include("ParallelMetricOpt_1.0.jl")

# Define a few parameters
GapTol = .01
ConTol = .01
filename = "testoutput"
statusFrequency = 10
gam = 10.0
maxits = 1000
lam = .2

# Solve a relaxed Lambda-Correlation Clustering Problem
Xlamcc = Parallel_Dykstra_lamCC_TFA(A,GapTol,ConTol,lam,filename,gam,maxits,statusFrequency)

# Run the sparsest cut relaxation
Xsc = ParallelDykstraSC(A,GapTol,ConTol,lam,filename,gam,maxits,statusFrequency)
