#
# Code for quadratic programming regulaziation of Leighton-Rao LP relaxation
# for sparsest cut.
#

include("DykstraSC_Helper.jl")

# DYKSTRA_SC
#
# Dykstra-based projection method for solving a quadratic program which is the
# regularized version of the Leighton-Rao Linear Programming relaxation for
# sparsest cut.
#
# Paramters:
#
# A = adjacency matrix of an undirected, unweighted graph
# GapTol = the desired relative duality gap tolerance we wish to achieve for convergence
# ConTol = tolerance for constraint violations
# lam, gam = paramters controlling the relationship between the original LP
#               and the quadratic program which is solved in practice here.
# statusFreqcuency = controls how often we perform a full convergence check,
#                       which involves a full check for the maximum constraint violations
#                       and includes the "entrywise rounding step" (see paper)
# maxits = maximum number of iterations to run before terminating
# stagnationTol = if the QP objective score doesn't change by at least this much in one pass
#               through the constraints, terminate early. This isn't very useful and can be ignored.
#               It was only useful for catching bugs in early stages of the development of this code, and
#               shouldn't come into play unless perhaps you want to stop the code
#               early if Dykstra's method isn't making progress fast enough for it to
#               be worthwhile.
function ParallelDykstraSC(A::SparseMatrixCSC{Float64,Int64},GapTol::Float64=1e-3,ConTol::Float64=1e-5,
                lam::Float64=0.1,filename::String="DykstraLeightonRaoOutput",gam::Float64=10.0,
                maxits::Int64=1000,statusFrequency::Int64=5,stagnationTol::Float64=1e-12)

        n = size(A,1)
        nthds::Int = Threads.nthreads()
        open(filename, "w") do f
                write(f, "Output from Hildreths lamCC TFA\n")
                write(f, "Lambda = $lam, gamma = $gam, tol = $GapTol, ConTol = $ConTol \n")
        end

        # Initialize X = -gam*A,
        # Wij = 1 if A_ij = 1
        # Wij = lam is A_ij = 0
        X,W = LeightonRaoQP_Initialize(A,lam,gam)

        # Matrices for double-loop correction terms (purposely dense)
        P = zeros(n,n)

        # Correction variable for constraint sum_ij xij = n
        SumCorrection = 0.0

        # Constant used in performing projections
        InvSumWeights = 0.0
        for i = 1:n-1
            for j = i+1:n
                InvSumWeights += 1/W[j,i]
            end
        end

        # Allocate space for the output
        LPobjs = Vector{Float64}()
        duals = Vector{Float64}()
        primals = Vector{Float64}()
        gaps = Vector{Float64}()
        ConViolation = Vector{Float64}()

        # Correction term vector (i.e. dual varialbes) for triangle constraints
        current_corrections = Vector{Vector{Tuple{Int64, Float64}}}()
        next_corrections = Vector{Vector{Tuple{Int64, Float64}}}()

        current_corrections = Vector{Vector{Tuple{Int64, Float64}}}()
        for i in 1:nthds
            Ac = Vector{Tuple{Int64, Float64}}()
            push!(Ac, (0, 0.0))
            push!(current_corrections, Ac)
        end


        next_corrections = Vector{Vector{Tuple{Int64, Float64}}}()
        for i in 1:nthds
            Ac = Vector{Tuple{Int64, Float64}}()
            push!(next_corrections, Ac)
        end

        # First time through constraints
        cyclic_triple_loop!(X,W,current_corrections,next_corrections)
        SumCorrection = the_sum_constraint!(X,W,SumCorrection,InvSumWeights)
        box_constraints!(X,W,P)

        iter = 0
        lastConCheck = 1.0

        # Make these variables global so they exist outside the while loop
        objective = 0.0
        R = 0.0
        FinalGap = 0.0
        FinalCon = 0.0
        Finalobj = 0.0
        Finalits = 0.0
        Bty = 0.0

        while true
                iter += 1

                # An empty vector to fill future correction terms in
                current_corrections = next_corrections
      #death
                next_corrections = Vector{Vector{Tuple{Int64, Float64}}}()

                for i in 1:nthds
                    Ac = Vector{Tuple{Int64, Float64}}()
                    push!(next_corrections, Ac)
                end

                for i in 1:nthds
                    Ac = current_corrections[i]
                    push!(Ac, (0, 0.0))
                end

                tic()
                cyclic_triple_loop!(X,W,current_corrections,next_corrections)
                SumCorrection = the_sum_constraint!(X,W,SumCorrection,InvSumWeights)
                box_constraints!(X,W,P)
                TriTime = toq()

                num_corrections = 0
                for i in 1:length(current_corrections)
                    num_corrections += length(current_corrections[i])
                end


                tricheck, lastConCheck, objective, LPobjs, primals, duals, gaps,
                ConViolation, gap, stagnated, roundconverge, roundR, R, roundedGap, roundTri, Bty = report_progress_DykstraLR(A,X,W,P,num_corrections,filename,iter,
                ConTol,GapTol,lam,lastConCheck,TriTime,SumCorrection,gam,LPobjs,primals,duals,gaps,ConViolation,stagnationTol,statusFrequency)

                # Return if the gap is less than tolerance and constraints
                # are satisfied to within a given tolerance
                if abs(gap) < GapTol && tricheck
                  open(filename,"a") do f
                     write(f, "Converged without rounding procedure.\n")
                  end
                  FinalCon = FullTriangleCheck(X)
                  Finalobj = LR_obj(A,X)
                  Finalits = iter
                  FinalGap = gap
                  break
                end

                # If progress stagnates, return
                if stagnated
                        println("Progress stagnated, returned early")
                        open(filename,"a") do f
                            write(f, "Progress stagnated, returned early.\n")
                        end
                        FinalCon = FullTriangleCheck(X)
                        Finalobj = LR_obj(A,X)
                        Finalits = iter
                        FinalGap = gap
                        break
                end

                # If rounding the current iterate produces a solution, stop and
                # return that rounded solution
                if roundconverge
                        println("\t Converged to within desired tolerance by rounding the solution to $roundR decimals")
                        open(filename,"a") do f
                            write(f, "\t Converged to within desired tolerance by rounding the solution to $roundR decimals\n")
                        end
                        Xr = round.(X,roundR)
                        adjust = n/sum(tril(Xr))
                        Xr = adjust*Xr
                        X = Xr
                        FinalCon = FullTriangleCheck(X)
                        Finalobj = LR_obj(A,X)
                        Finalits = iter
                        FinalGap = roundedGap
                        break
                end

                if iter >= maxits
                        println("Maximum number of iterations reached")
                        open(filename,"a") do f
                            write(f, "Maximum number of iterations reached\n")
                        end
                        FinalCon = FullTriangleCheck(X)
                        Finalobj = LR_obj(A,X)
                        Finalits = iter
                        FinalGap = gap
                        break
                end

        end

        # Output final statistics and iterates
        return X, FinalCon, FinalGap, Finalobj, Finalits, R, LPobjs, duals, primals, gaps, ConViolation, Bty
end


function report_progress_DykstraLR(A::SparseMatrixCSC{Float64,Int64},X::Matrix{Float64},W::Matrix{Float64},P::Matrix{Float64},current_corrections::Int,
    filename::String,iter::Int64,ConTol::Float64,GapTol::Float64,lam::Float64,lastConCheck::Float64,triTime::Float64,SumCorrection::Float64,gam::Float64,
    LPobjs::Vector{Float64},primals::Vector{Float64},duals::Vector{Float64},gaps::Vector{Float64},ConViolation::Vector{Float64},stagnationTol::Float64,statusFrequency::Int64)

        n = size(X,1)

        # True or false convergence check
        tricheck = TriangleCheck(X,ConTol)

        sumcheck = abs(n-sum(tril(X)))

        tricheck = tricheck*(sumcheck<ConTol)

        # nonzeros in dual vector
        nnzDelta = current_corrections

        # Compute primal and dual objectives
        objective = LR_obj(A,X)
        xWx = xWnorm(W,X)
        BtDual = (n*SumCorrection)
        PrimalQP = xWx/(2*gam) + objective
        R = xWx/(2*gam*objective)
        DualQP = -BtDual/(gam) - xWx/(2*gam)
        gap = (PrimalQP-DualQP)/DualQP

        # Check if progress has "stagnated", or if Dykstra just isn't making
        # fast enough progress for you to bother waiting until convergence.
        if iter > 2
                stagnated = stagnationCheck(primals[end],PrimalQP,duals[end],DualQP,stagnationTol)
        else
                stagnated = false
        end

        # Every "statusFrequency" number of iterations, fully check constraints
        # to find the magnitude of the worst violation.
        # Also, try rounding the current solution if we are close to convergence
        roundconverge = false
        specialPrint = false
        PrimalRound = 1.0
        roundTri = 1.0
        roundedGap = 1.0
        GapRoundTol = 1e-1
        ConRoundTol = 1e-1
        roundR = 0
        #R = 0
        if iter%statusFrequency == statusFrequency-1
          lastConCheck = max(sumcheck,FullTriangleCheck(X))

          #tic()
          if abs(gap) < GapRoundTol && lastConCheck < ConRoundTol
                # Round to a few decimals. If any one is good enough, stop
                for r = 6:-1:2
                        Xr = round.(X,r)
                        adjust = n/sum(tril(Xr))
                        Xr = adjust*Xr  # make sure sum of entries equals n
                        objr = LR_obj(A,Xr)
                        xWxr = xWnorm(W,Xr)
                        PrimalRound = xWxr/(2*gam) + objr
                        roundTri = FullTriangleCheck(Xr)
                        roundedGap = (PrimalRound-DualQP)/DualQP
                        R = xWxr/(2*gam*objr)
                        if roundTri < ConTol && abs(roundedGap) < GapTol
                                roundR = r
                                roundconverge = true
                                break
                        end
                end
                specialPrint = true
          end
          #timeRound = toc()
          #@show timeRound
        end

        # Save current progress
        push!(primals,PrimalQP)
        push!(duals,DualQP)
        push!(gaps,gap)
        push!(ConViolation,lastConCheck)
        push!(LPobjs,objective)

        # Round things to print out results nicely
        gapround = round(gap,5)
        PriRound = round(PrimalQP,5)
        DuRound = round(DualQP,5)
        ob = round(objective,3)
        time = round(triTime,3)
        tr = round(lastConCheck,5)
        Bty =  round(-BtDual/(gam),4)
        println("Iter $iter: Dual = $DuRound, Primal = $PriRound, gap = $gapround, ConVio = $tr, 3Loop = $time, Obj: $ob")
        open(filename,"a") do f
            write(f, "Iter $iter: Dual = $DuRound, Primal = $PriRound, gap = $gapround, ConVio = $tr, 3Loop = $time, Obj: $ob \n")
        end

        # Print something extra if you perform the entrywise rounding step
        if specialPrint
                PR = round(PrimalRound,5); rgap = round(roundedGap,5); rTri = round(roundTri,5)
                println("\t Rounded: \tNewPrimal = $PR, gap = $rgap, ConVio = $rTri")
                open(filename,"a") do f
                    write(f, "\t Rounded: \tNewPrimal = $PR, gap = $rgap, ConVio = $rTri \n")
                end
        end

        return tricheck, lastConCheck, objective, LPobjs, primals, duals, gaps, ConViolation, gap, stagnated, roundconverge, roundR,R, roundedGap, roundTri,Bty
end

# Enforce the constraint \sum_ij x_ij = n
function the_sum_constraint!(X::Matrix{Float64},W::Matrix{Float64},SumCorrection::Float64,InvSumW::Float64)

    n = size(X,1)
    # Correction step
    sumX = 0
    for i = 1:n-1
        for j = i+1:n
            X[j,i] = X[j,i] + SumCorrection/W[j,i]
            sumX += X[j,i]
        end
    end

    constant = (sumX - n)/InvSumW
    for i = 1:n-1
        for j = i+1:n
            X[j,i] = X[j,i] - constant/W[j,i]
        end
    end
    return constant

end


# Enforce constraint X_ij >= 0
function box_constraints!(X::Matrix{Float64},W::Matrix{Float64},P::Matrix{Float64})

    n = size(X,1)
    for i = 1:n-1
        for j = i+1:n
            X[j,i] -= P[j,i]/W[j,i]

            thetaIplus = -X[j,i]*W[j,i]
            if thetaIplus > 0
                X[j,i] = 0.0
                P[j,i] = thetaIplus
            else
                P[j,i] = 0.0
            end

        end
    end
end

# Enforce triangle inequality constraints


function cyclic_triple_loop!(X::Matrix{Float64},W::Matrix{Float64},
      Bookshelf::Vector{Vector{Tuple{Int64, Float64}}}, newBookshelf::Vector{Vector{Tuple{Int64, Float64}}})
   #cyclic_triple_loop(D, E, W, now_corrections, next_corrections)
    n::Int = size(X,1)
    o::Int = 10
    nthds::Int = Threads.nthreads()
    epsi = 0
    # Construct the initial dissimilarity matrix, set X_0 = D essentially
    # We only edit the lower triangular part of the matrix. Inside of loops,
    # whenever possible we iterate through columns first, then rows.

    # This is an array of arrays of size nThreads, each thread gets it's own update array.


    #These arrays are used to store information about block size, e.g. index ranges in blocks of size 10
    A::Vector{Tuple{Int, Int}} = Vector{Tuple{Int, Int}}()
    B::Vector{Tuple{Int, Int}} = Vector{Tuple{Int, Int}}()
    for k in n:-o:1
        a = k-o+1
        b = k
        if a < 1
            a = 1
        end
        unshift!(B, (a,b))
    end

        A=B

    # Now perform Dykstra's method and plot intermediate steps
    # Each global iteration visits every constraint once



    indexing = Vector{Int}()
    for i in 1:nthds
        push!(indexing, 1)
    end




    begin
        r_endpoint::Int = round(Int64, ceil(n/o))
        for m::Int in r_endpoint:-1:1
            #@threads
            Threads.@threads for threadholder in 1:nthds
                c::Int64 = Threads.threadid()

                nowInd = indexing[c]
                old_triplet_corrections::Vector{Tuple{Int64, Float64}} = Bookshelf[c]
                new_triplet_corrections::Vector{Tuple{Int64, Float64}} = newBookshelf[c]

                numthreads::Int64 = Threads.nthreads()
                threadnum::Int64 = c
                start::Int64 = 1
                endpoint::Int64 = round(Int64, ceil(m/2))
                interval::Int = endpoint-start+1

                threadrange::Int = ceil(Int64, interval/numthreads)
                s::Int = start + threadrange*(threadnum-1)
                e::Int = min(start + threadrange*threadnum -1, endpoint)

                for iIter in s:e    #iIter::Int in 1:round(Int64, ceil(m/2))
                    kIter::Int = m-iIter+1
                    nowInd = iterate(X, W, iIter, kIter, o, n, A, B, old_triplet_corrections, new_triplet_corrections, nowInd)
                end
                indexing[c] = nowInd
            end
        end
    end

    begin
        r_endpoint = round(Int64, ceil(n/o))
        for m::Int in 2:r_endpoint
            #Threads.@threads
            Threads.@threads for threadholder in 1:nthds
                c::Int64 = Threads.threadid()
                nowInd::Int64 = indexing[c]
                #new_triplet_corrections = nothing#::Array{Tuple, 1} = Tuple[]#Bookshelf[c]
                old_triplet_corrections::Vector{Tuple{Int64, Float64}} = Bookshelf[c]
                new_triplet_corrections::Vector{Tuple{Int64, Float64}} = newBookshelf[c]

                numthreads::Int = Threads.nthreads()
                threadnum::Int = c
                start::Int = m
                endpoint::Int = round(Int64,floor((m+r_endpoint)/2))
                interval::Int = endpoint-start+1

                threadrange::Int = ceil(Int64, interval/numthreads)
                s::Int = start + threadrange*(threadnum-1)
                e::Int = min(start + threadrange*threadnum -1, endpoint)

                for iIter::Int in s:e #m:round(Int64,floor((m+r_endpoint)/2)) #thread shplit
                    kIter::Int = r_endpoint-iIter+m
                    nowInd = iterate(X, W, iIter, kIter, o, n, A, B, old_triplet_corrections, new_triplet_corrections, nowInd)
                end
                indexing[c] = nowInd
            end
        end
    end

end # function end



function iterate(X::Matrix{Float64},W::Matrix{Float64}, iIter::Int, kIter::Int, o::Int, n::Int, A::Vector{Tuple{Int, Int}}, B::Vector{Tuple{Int, Int}}, now_corrections::Vector{Tuple{Int64, Float64}}, next_corrections::Vector{Tuple{Int64, Float64}}, nowInd::Int)
    epsi = 0
    iRange::Tuple{Int, Int} = A[iIter]
    kRange::Tuple{Int, Int} = B[kIter]

    i::Int = minimum(iRange)
    k::Int = maximum(kRange)

    C = Vector{Tuple{Int, Int}}()
    for j in k-1:-o:i+1
        a::Int = j-o+1
        b::Int = j
        if a < i+1
            a = i+1
        end
        push!(C, (a,b))
    end

    nextKey = now_corrections[nowInd]
    correctionsLength = length(now_corrections)

    for jIter::Int in 1:length(C)
        jRange::Tuple{Int, Int} = C[jIter]

        for i in iRange[1]:iRange[2]
            for j::Int in max(i+1, jRange[1]):jRange[2]


               Wij = W[j,i]

                for k in max(j+1,kRange[1]):kRange[2]
                Xik = X[k,i]
                  Xjk = X[k,j]
                  Xij = X[j,i]
                  Wik = W[k,i]
                  Wjk = W[k,j]

                  ### Check triangle i,j,k
                  ijkKey = (i-1)*n^2+(j-1)*n+k
                  # First see if this is the next triangle with a nonzero correction variable
                  if ijkKey == nextKey[1]

                          cor = nextKey[2]
                    # We need to scale the correction since we're projecting into the minimum
                    # weighted 2-norm direction

                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik

                    X[j,i] = Xij + cor*(Wik*Wjk/denom)
                    X[k,i] = Xik - cor*(Wij*Wjk/denom)
                    X[k,j] = Xjk - cor*(Wik*Wij/denom)
                    Xij = X[j,i]
                    Xik = X[k,i]
                    Xjk = X[k,j]
                    # Move along in the list of triplets with corrections
                    if nowInd < correctionsLength
                            nowInd +=1
                            nextKey = now_corrections[nowInd]
                    end
                  end

                  mu = (Xij - Xjk - Xik)

                  if mu > epsi
                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik

                    X[j,i] = Xij - mu*(Wik*Wjk/denom)
                    X[k,i] = Xik + mu*(Wij*Wjk/denom)
                    X[k,j] = Xjk + mu*(Wik*Wij/denom)
                    # Next time we see this triple we have to correct
                    push!(next_corrections,(ijkKey,mu))
                  end

                  ### Done checking triangle i,j,k

                  ### Check triangle i,k,j
                  Xij = X[j,i]
                  Xik = X[k,i]
                  Xjk = X[k,j]

                  ijkKey = (i-1)*n^2+(k-1)*n+j
                  # First see if this is the next triangle with a nonzero correction variable
                  if ijkKey == nextKey[1]

                          cor = nextKey[2]

                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik
                    X[j,i] = X[j,i] - cor*(Wik*Wjk/denom)
                    X[k,i] = X[k,i] + cor*(Wij*Wjk/denom)
                    X[k,j] = X[k,j] - cor*(Wik*Wij/denom)
                    Xij = X[j,i]
                    Xik = X[k,i]
                    Xjk = X[k,j]
                    # Move along in the list of triplets with corrections
                    if nowInd < correctionsLength
                            nowInd +=1
                            nextKey = now_corrections[nowInd]
                    end
                  else
                    Xij = X[j,i]
                    Xik = X[k,i]
                    Xjk = X[k,j]
                  end
                  mu = (-Xij - Xjk + Xik)
                  if mu > epsi

                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik

                    X[j,i] = Xij + mu*(Wik*Wjk/denom)
                    X[k,i] = Xik - mu*(Wij*Wjk/denom)
                    X[k,j] = Xjk + mu*(Wik*Wij/denom)

                    # Next time we see this triple we have to correct
                    push!(next_corrections,(ijkKey,mu))
                  end
                  ### Done checking triangle i,k,j

                  ### Triangle j,k,i
                  Xij = X[j,i]
                  Xik = X[k,i]
                  Xjk = X[k,j]
                  ijkKey = (j-1)*n^2+(k-1)*n+i
                  # First see if this is the next triangle with a nonzero correction variable
                  if ijkKey == nextKey[1]

                          cor = nextKey[2]

                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik

                    X[j,i] = X[j,i] - cor*(Wik*Wjk/denom)
                    X[k,i] = X[k,i] - cor*(Wij*Wjk/denom)
                    X[k,j] = X[k,j] + cor*(Wik*Wij/denom)
                    Xij = X[j,i]
                    Xik = X[k,i]
                    Xjk = X[k,j]
                    # Move along in the list of triplets with corrections
                    if nowInd < correctionsLength
                            nowInd +=1
                            nextKey = now_corrections[nowInd]
                    end
                  else
                    Xij = X[j,i]
                    Xik = X[k,i]
                    Xjk = X[k,j]
                  end

                  mu = (-Xij + Xjk - Xik)

                  if mu > epsi
                    denom = Wij*Wjk + Wik*Wij + Wjk*Wik

                    X[j,i] = Xij + mu*(Wik*Wjk/denom)
                    X[k,i] = Xik + mu*(Wij*Wjk/denom)
                    X[k,j] = Xjk - mu*(Wik*Wij/denom)

                    # Next time we see this triple we have to correct
                    push!(next_corrections,(ijkKey,mu))
                  end
                  ### Done checking triangle j,k,i

                end
            end
        end
    end
    nowInd
end
