

############################
#          SOLVE           #
############################
function solve!(prob::Problem, solver::ProjectedNewtonSolver)
    to = solver.stats[:timer]
    for i = 1:solver.opts.n_steps
        @timeit to "newton step" V_ = newton_step!(prob, solver)
        @timeit to "copy" begin
            copyto!(prob.X, V_.X)
            copyto!(prob.U, V_.U)
        end

        record_iteration!(prob,solver)
        solver.stats[:c_max][end] <= solver.opts.feasibility_tolerance ? break : nothing
    end

    return solver
end

function record_iteration!(prob::Problem, solver::ProjectedNewtonSolver)
    J = cost(prob)
    c_max = max_violation(prob)

    solver.stats[:iterations] += 1
    push!(solver.stats[:cost],J)
    push!(solver.stats[:c_max],c_max)
end


cost(prob::Problem, V::Union{PrimalDual,PrimalDualVars}) = cost(prob.obj, V.X, V.U, get_dt_traj(prob,V.U))

############################
#       CONSTRAINTS        #
############################
function dynamics_constraints!(prob::Problem, solver::DirectSolver, V=solver.V)
    N = prob.N
    X,U,dt = V.X, V.U, get_dt_traj(prob, V.U)
    solver.fVal[1] .= V.X[1] - prob.x0
    for k = 1:N-1
         evaluate!(solver.fVal[k+1], prob.model, X[k], U[k], dt[k])
         solver.fVal[k+1] .-= X[k+1]
     end
 end


function dynamics_jacobian!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    n,m,N = size(prob)
    X,U, dt = V.X, V.U, get_dt_traj(prob,V.U)
    solver.∇F[1].xx .= Diagonal(I,n)
    solver.Y[1:n,1:n] .= Diagonal(I,n)
    part = (x=1:n, u =n .+ (1:m), x1=n+m .+ (1:n))
    p = num_constraints(prob)
    off1 = n
    off2 = 0
    for k = 1:N-1
        jacobian!(solver.∇F[k+1], prob.model, X[k], U[k], dt[k])
        solver.Y[off1 .+ part.x, off2 .+ part.x] .= solver.∇F[k+1].xx
        solver.Y[off1 .+ part.x, off2 .+ part.u] .= solver.∇F[k+1].xu
        solver.Y[off1 .+ part.x, off2 .+ part.x1] .= -Diagonal(I,n)
        off1 += n + p[k]
        off2 += n+m
    end
end


function update_constraints!(prob::Problem, solver::DirectSolver, V=solver.V)
    n,m,N = size(prob)
    for k = 1:N-1
        evaluate!(solver.C[k], prob.constraints[k], V.X[k], V.U[k])
    end
    evaluate!(solver.C[N], prob.constraints[N], V.X[N])
end

function active_set!(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    P = sum(num_constraints(prob)) + n*N
    a0 = copy(solver.a)
    for k = 1:N
        active_set!(solver.active_set[k], solver.C[k], solver.opts.active_set_tolerance)
    end
    if solver.opts.verbose && a0 != solver.a
        println("active set changed")
    end
end

function active_set!(a::AbstractVector{Bool}, c::AbstractArray{T}, tol::T=0.0) where T
    a0 = copy(a)
    equality, inequality = c.parts[:equality], c.parts[:inequality]
    a[equality] .= true
    a[inequality] .= c.inequality .>= -tol
end


######################################
#       CONSTRAINT JACBOBIANS        #
######################################
function constraint_jacobian!(prob::Problem, ∇C::Vector, X, U)
    n,m,N = size(prob)
    for k = 1:N-1
        jacobian!(∇C[k], prob.constraints[k], X[k], U[k])
    end
    jacobian!(∇C[N], prob.constraints[N], X[N])
end
constraint_jacobian!(prob::Problem, solver::DirectSolver, V=solver.V) =
    constraint_jacobian!(prob, solver.∇C, V.X, V.U)
# constraint_jacobian!(prob::Problem, Y::KKTJacobian, V=solver.V) =
#     constraint_jacobian!(prob, Y.∇C, V.X, V.U)

function active_constraints(prob::Problem, solver::ProjectedNewtonSolver)
    n,m,N = size(prob)
    a = solver.a.duals
    # return view(solver.Y, a, :), view(solver.y, a)
    return solver.Y.blocks[a,:], solver.y[a]
end


############################
#      COST EXPANSION      #
############################
function cost_expansion!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V) where T
    n,m,N = size(prob)
    NN = N*n + (N-1)*m
    H = solver.H
    g = solver.g
    dt = get_dt_traj(prob,V.U)

    part = (x=1:n, u=n .+ (1:m), z=1:n+m)
    part2 = (xx=(part.x, part.x), uu=(part.u, part.u), ux=(part.u, part.x), xu=(part.x, part.u))
    off = 0
    for k = 1:N-1
        # H[off .+ part.x, off .+ part.x] = Q[k].xx
        # H[off .+ part.x, off .+ part.u] = Q[k].ux'
        # H[off .+ part.u, off .+ part.x] = Q[k].ux
        # H[off .+ part.u, off .+ part.u] = Q[k].uu
        hess = PartedMatrix(view(H, off .+ part.z, off .+ part.z), part2)
        grad = PartedVector(view(g, off .+ part.z), part)
        hessian!(hess, prob.obj[k], V.X[k], V.U[k],dt[k])
        gradient!(grad, prob.obj[k], V.X[k], V.U[k],dt[k])

        off += n+m
    end

    hess = PartedMatrix(view(H, off .+ part.x, off .+ part.x), part2)
    grad = PartedVector(view(g, off .+ part.x), part)
    hessian!(hess, prob.obj[N], V.X[N])
    gradient!(grad, prob.obj[N], V.X[N])
end



######################
#     FUNCTIONS      #
######################
function update!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V, active_set=true)
    to = solver.stats[:timer]
    @timeit to "dynamics"       dynamics_constraints!(prob, solver, V)
    @timeit to "constraints"    update_constraints!(prob, solver, V)
    @timeit to "dyn jacobian"   dynamics_jacobian!(prob, solver, V)
    @timeit to "con jacobian"   constraint_jacobian!(prob, solver, V)
    @timeit to "cost expansion" cost_expansion!(prob, solver, V)
    if active_set
        @timeit to "active set" active_set!(prob, solver)
    end
end

function max_violation(solver::DirectSolver{T}) where T
    c_max = 0.0
    C = solver.C
    N = length(C)
    for k = 1:N
        if length(C[k].equality) > 0
            c_max = max(norm(C[k].equality,Inf), c_max)
        end
        if length(C[k].inequality) > 0
            c_max = max(pos(maximum(C[k].inequality)), c_max)
        end
        c_max = max(norm(solver.fVal[k], Inf), c_max)
    end
    return c_max
end

function calc_violations(solver::ProjectedNewtonSolver{T}) where T
    C = solver.C
    N = length(C)
    v = [zero(c) for c in C]
    v = zeros(N)
    for k = 1:N
        if length(C[k].equality) > 0
            v[k] = norm(C[k].equality,Inf)
        end
        if length(C[k].inequality) > 0
            v[k] = max(pos(maximum(C[k].inequality)), v[k])
        end
    end
    return v
end

function projection_solve!(prob, solver, V=solver.V, active_set_update=true)
    eps_feasible = solver.opts.feasibility_tolerance
    viol = norm(solver.y[solver.a.duals], Inf)
    max_projection_iters = 10

    count = 0
    while count < max_projection_iters && viol > eps_feasible
        viol = _projection_solve!(prob, solver, V, active_set_update)
        count += 1
    end
    return viol
end


function _projection_solve!(prob::Problem, solver::ProjectedNewtonSolver,
        V=solver.V, active_set_update=true)
    to = solver.stats[:timer]

    Z = primals(V)
    λ = duals(V)
    a = solver.a.duals
    max_refinements = 10
    convergence_rate_threshold = 1.1
    ρ = 1e-2

    # cost_expansion!(prob, solver, V)
    H = Diagonal(solver.H)

    @timeit to "dynamics"     dynamics_constraints!(prob, solver, V)
    @timeit to "constraints"  update_constraints!(prob, solver, V)
    @timeit to "dyn jacobian" dynamics_jacobian!(prob, solver, V)
    @timeit to "con jacobian" constraint_jacobian!(prob, solver, V)
    if active_set_update
        @timeit to "active set" active_set!(prob, solver)
    end
    Y,y = active_constraints(prob, solver)
    viol0 = norm(y,Inf)
    if solver.opts.verbose
        println("feas0: $viol0")
    end

    HinvY = H\Y'
    S = Symmetric(Y*HinvY)
    @timeit to "cholesky" Sreg = cholesky(S + ρ*I)
    viol_prev = viol0
    count = 0
    while count < max_refinements
        @timeit to "linesearch" viol = _projection_linesearch!(prob, solver, V, (S,Sreg), HinvY)
        convergence_rate = log10(viol)/log10(viol_prev)
        viol_prev = viol
        count += 1

        if solver.opts.verbose
            println("conv rate: $convergence_rate")
        end

        if convergence_rate < convergence_rate_threshold ||
                       viol < solver.opts.feasibility_tolerance
            break
        end
    end

    solver.stats[:S] = Sreg
    return viol_prev
end

function _projection_linesearch!(prob::Problem, solver::ProjectedNewtonSolver,
        V, S, HinvY)
    to = solver.stats[:timer]

    a = solver.a.duals
    y = solver.y[a]
    viol0 = norm(y,Inf)
    viol = Inf
    ρ = 1e-4

    Z = primals(V)
    V_ = copy(V)
    Z_ = primals(V_)
    α = 1.0
    ϕ = 0.5
    count = 1
    while true
        @timeit to "dual solve" δλ = reg_solve(S[1],y,S[2],1e-8,25)
        @timeit to "primal solve" δZ = -HinvY*δλ
        Z_ .= Z + α*δZ

        @timeit to "dynamics" dynamics_constraints!(prob, solver, V_)
        @timeit to "constraints" update_constraints!(prob, solver, V_)
        y = solver.y[a]
        viol = norm(y,Inf)

        if solver.opts.verbose
            println("feas: $viol")
        end
        if viol < viol0 || count > 10
            break
        else
            count += 1
            α *= ϕ
        end
    end
    copyto!(Z,Z_)
    return viol
end

reg_solve(A, b, reg::Real, tol=1e-10, max_iters=10) = reg_solve(A, b, A + reg*I, tol, max_iters)
function reg_solve(A, b, B, tol=1e-10, max_iters=10)
    x = B\b
    count = 0
    while count < max_iters
        r = b - A*x
        # println("r_norm = $(norm(r))")

        if norm(r) < tol
            break
        else
            x += B\r
            count += 1
        end
    end
    # println("iters = $count")

    return x
end



function projection!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V, active_set_update=true)
    Z = primals(V)
    eps_feasible = solver.opts.feasibility_tolerance
    count = 0
    # cost_expansion!(prob, solver, V)
    H = Diagonal(solver.H)
    while true
        dynamics_constraints!(prob, solver, V)
        update_constraints!(prob, solver, V)
        dynamics_jacobian!(prob, solver, V)
        constraint_jacobian!(prob, solver, V)
        if active_set_update
            active_set!(prob, solver)
        end
        Y,y = active_constraints(prob, solver)
        HinvY = H\Y'

        viol = norm(y,Inf)
        if solver.opts.verbose
            println("feas: ", viol)
        end
        if viol < eps_feasible || count > 10
            break
        else
            δZ = -HinvY*((Y*HinvY)\y)
            Z .+= δZ
            count += 1
        end
    end
end

function primaldual_projection!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V, active_set_update=true)
    Z = primals(V)
    λ = duals(V)
    a = solver.a.duals
    eps_feasible = solver.opts.feasibility_tolerance
    count = 0
    ρ = 1e-6

    # cost_expansion!(prob, solver, V)
    H = Diagonal(solver.H)

    while true
        dynamics_constraints!(prob, solver, V)
        update_constraints!(prob, solver, V)
        dynamics_jacobian!(prob, solver, V)
        constraint_jacobian!(prob, solver, V)
        if active_set_update
            active_set!(prob, solver)
        end
        Y,y = active_constraints(prob, solver)
        HinvY = H\Y'

        viol = norm(y,Inf)
        if solver.opts.verbose
            println("feas: ", viol)
        end
        if viol < eps_feasible || count > 10
            if count == 0
                solver.stats[:S] = cholesky(Symmetric(Y*HinvY) + ρ*I)
            end
            break
        else
            λa = view(λ,a)

            S = cholesky(Symmetric(Y*HinvY) + ρ*I)
            δλ = S\y
            δZ = -HinvY*δλ

            Z .+= δZ
            λa .+= δλ
            count += 1

            solver.stats[:S] = S
        end
    end
end


function multiplier_projection!(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    g = solver.g
    a = solver.a.duals
    Y,y = active_constraints(prob, solver)
    λ = duals(V)[a]

    res0 = g + Y'λ
    δλ = -(Y*Y')\(Y*res0)
    λ_ = λ + δλ
    res = g + Y'*λ_
    copyto!(view(duals(V),a), λ_)
    res = norm(residual(prob, solver, V))
    return res, δλ
end

function solveKKT(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    H,g = solver.H, solver.g
    Pa = length(y)
    A = [H Y'; Y zeros(Pa,Pa)]
    b = [g + Y'λ; y]
    δV[a] = -A\b
    return δV
end

using SuiteSparse
function solveKKT_Shur(prob::Problem, solver::ProjectedNewtonSolver, Hinv, V=solver.V)
    a = solver.a
    δV = zero(V.V)
    λ = duals(V)[a.duals]
    Y,y = active_constraints(prob, solver)
    g = solver.g
    r = g + Y'λ

    YHinv = Y*Hinv
    L = solver.stats[:S]::SuiteSparse.CHOLMOD.Factor{Float64}
    δλ = L\(y-YHinv*r)
    δz = -Hinv*(r+Y'δλ)

    δV[solver.parts.primals] .= δz
    δV[solver.parts.duals[solver.a.duals]] .= δλ
    return δV, δλ
end

function residual(prob::Problem, solver::ProjectedNewtonSolver, V=solver.V)
    a = solver.a
    Y,y = active_constraints(prob, solver)
    λ = duals(V)[a.duals]
    g = solver.g
    res = [g + Y'λ; y]
end


function line_search(prob::Problem, solver::ProjectedNewtonSolver, δV)
    α = 1.0
    s = 0.01
    J0 = cost(prob, solver.V)
    update!(prob, solver)
    res0 = norm(residual(prob, solver))
    count = 0
    solver.opts.verbose ? println("res0: $res0") : nothing
    while count < 10
        V_ = solver.V + α*δV

        # Calculate residual
        projection!(prob, solver, V_)
        # projection_solve!(prob, solver, V_)

        cost_expansion!(prob, solver, V_)
        res, = multiplier_projection!(prob, solver, V_)
        J = cost(prob, V_)

        # Calculate max violation
        viol = max_violation(solver)

        if solver.opts.verbose
            println("cost: $J \t residual: $res \t feas: $viol")
        end
        if res < (1-α*s)*res0
            solver.opts.verbose ? println("α: $α") : nothing
            return V_
        end
        count += 1
        α /= 2
    end
    return solver.V
end




function newton_step!(prob::Problem, solver::ProjectedNewtonSolver)
    V = solver.V
    verbose = solver.opts.verbose

    # Initial stats
    update!(prob, solver)
    J0 = cost(prob, V)
    res0 = norm(residual(prob, solver))
    viol0 = max_violation(solver)
    Hinv = inv(Diagonal(solver.H))

    # Projection
    verbose ? println("\nProjection:") : nothing
    # primaldual_projection!(prob, solver)
    projection_solve!(prob, solver)


    if solver.opts.solve_type == :feasible
        return solver.V
    end

    cost_expansion!(prob, solver)
    multiplier_projection!(prob, solver)

    # Solve KKT
    J1 = cost(prob, V)
    res1 = norm(residual(prob, solver))
    viol1 = max_violation(solver)
    δV, = solveKKT_Shur(prob, solver, Hinv)

    # Line Search
    verbose ? println("\nLine Search") : nothing
    V_ = line_search(prob, solver, δV)
    J_ = cost(prob, V_)
    res_ = norm(residual(prob, solver, V_))
    viol_ = max_violation(solver)

    # Print Stats
    if verbose
        println("\nStats")
        println("cost: $J0 → $J1 → $J_")
        println("res: $res0 → $res1 → $res_")
        println("viol: $viol0 → $viol1 → $viol_")
    end

    return V_
end

function buildL(L::KKTFactors,y_part)
    Pa = sum(y_part)
    S = PseudoBlockArray(zeros(Pa,Pa),y_part,y_part)
    N = length(y_part) ÷ 2

    S[Block(1,1)] = L.G[end].L
    S[Block(2,1)] = L.F[1]
    S[Block(2,2)] = L.G[1].L
    S[Block(3,1)] = L.L[1]
    S[Block(3,2)] = L.M[1]
    S[Block(3,3)] = L.H[1].L
    for k = 2:N-1
        S[Block(2k,2k-2)] = L.E[k]
        S[Block(2k,2k-1)] = L.F[k]
        S[Block(2k,2k  )] = L.G[k].L
        S[Block(2k+1,2k-2)] = L.K[k]
        S[Block(2k+1,2k-1)] = L.L[k]
        S[Block(2k+1,2k-0)] = L.M[k]
        S[Block(2k+1,2k+1)] = L.H[k].L
    end
    S[Block(2N,2N-2)] = L.E[N]
    S[Block(2N,2N-1)] = L.F[N]
    S[Block(2N,2N-0)] = L.G[N].L
    return S
end
buildL(solver::SequentialNewtonSolver) = buildL(solver.L, dual_partition(solver))

function buildY!(Y,solver::SequentialNewtonSolver)
    n,m,N = size(solver)

    # Get Active Jacobians
    xi,ui = 1:n, n .+ (1:m)
    a = solver.active_set
    C = [solver.∇C[k][a[k],1:n] for k = 1:N]
    D = [solver.∇C[k][a[k],n+1:n+m] for k = 1:N-1]


    Y[Block(1,1)] = Diagonal(I,n)
    for k = 1:N-1
        Y[Block(2k,2k-1)] = solver.∇F[k+1].xx
        Y[Block(2k,2k-0)] = solver.∇F[k+1].xu
        Y[Block(2k,2k+1)] = -Diagonal(I,n)
        Y[Block(2k+1,2k-1)] = C[k]
        Y[Block(2k+1,2k-0)] = D[k]
    end
    Y[Block(2N,2N-1)] = C[N]
    return Y
end
function buildY(solver::SequentialNewtonSolver)
    y_part = dual_partition(solver)
    z_part = repeat([n,m],N-1)
    push!(z_part,n)
    NN = sum(z_part)
    Pa = sum(y_part)

    Y = PseudoBlockArray(zeros(Pa,NN),y_part,z_part)
    buildY!(Y,solver)
    return Y
end


function buildS!(S,solver::SequentialNewtonSolver,C,D)
    n,m,N = size(solver)
    Qinv = solver.Qinv
    Rinv = solver.Rinv
    ∇F = view(solver.∇F,2:N)
    p = sum.(solver.active_set)
    pcum = insert!(cumsum(p), 1, 0)

    dinds = 1:n
    cinds = n .+ (1:p[1])
    S[dinds,dinds] = Qinv[1]
    S[dinds,n .+ dinds] = Qinv[1]*∇F[1].xx'
    S[dinds,n .+ cinds] = Qinv[1]*C[1]'

    for k = 1:N-1
        off = pcum[k] + k*n
        dinds = off .+ (1:n)
        cinds = off + n .+ (1:p[k])
        S[dinds,dinds] = ∇F[k].xx*Qinv[k]*∇F[k].xx' + ∇F[k].xu*Rinv[k]*∇F[k].xu' + Qinv[k+1]
        S[dinds,cinds] = ∇F[k].xx*Qinv[k]*C[k]'     + ∇F[k].xu*Rinv[k]*D[k]'
        S[cinds,cinds] = C[k]*Qinv[k]*C[k]'         + D[k]*Rinv[k]*D[k]'
        if k < N-1
            S[dinds,dinds .+ (p[k] + n)] = -Qinv[k+1]*∇F[k+1].xx'
            S[dinds, (off + p[k] + 2n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        else
            S[dinds, (off + p[k] + n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        end
    end
    off = pcum[N] + N*n
    cinds = off .+ (1:p[N])
    S[cinds,cinds] = C[N]*Qinv[N]*C[N]'
    return S
    return Symmetric(S)
end
function buildS(solver::SequentialNewtonSolver)
    y_part = dual_partition(solver)

    Pa = sum(y_part)
    S = zeros(Pa,Pa)

    C = [solver.∇C[k][a[k],1:n] for k = 1:N]
    D = [solver.∇C[k][a[k],n+1:n+m] for k = 1:N-1]

    buildS!(solver,C,D)
    return S
end

function Sinds(solver::SequentialNewtonSolver)
    n,m,N = size(solver)
    y_part = dual_partition(solver)
    inds = create_partition(Tuple(y_part))

    A = [(0:0,0:0) for k = 1:N]
    B = [(0:0,0:0) for k = 1:N]
    C = [(0:0,0:0) for k = 1:N]
    D = [(0:0,0:0) for k = 1:N]
    E = [(0:0,0:0) for k = 1:N]

    n,m,N = size(solver)
    p = sum.(solver.active_set)
    pcum = insert!(cumsum(p), 1, 0)

    dinds = 1:n
    cinds = n .+ (1:p[1])
    A[1] = (dinds,dinds)
    D[1] = (dinds,n .+ dinds)
    E[1] = (dinds,n .+ cinds)

    for k = 1:N-1
        off = pcum[k] + k*n
        dinds = off .+ (1:n)
        cinds = off + n .+ (1:p[k])
        A[k+1] = (dinds,dinds)
        B[k+1] = (dinds,cinds)
        C[k+1] = (cinds,cinds)
        if k < N-1
            D[k+1] = (dinds, dinds .+ (p[k] + n))
            E[k+1] = (dinds, (off + p[k] + 2n) .+ (1:p[k+1]))
        else
            E[k+1] = (dinds, (off + p[k] + n) .+ (1:p[k+1]))
        end
    end
    off = pcum[N] + N*n
    cinds = off .+ (1:p[N])
    C[1,1] = (cinds,cinds)
    S_part = (A=A,B=B,C=C,D=D,E=E)
end

function buildS!(S, solver, A, B, C, D, inds::NamedTuple)
    N = length(solver.Q)
    Qinv = solver.Qinv
    Rinv = solver.Rinv

    S[inds.A[1]...] = Qinv[1]
    S[inds.D[1]...] = Qinv[1]*A[1]'
    S[inds.E[1]...] = Qinv[1]*C[1]'

    for k = 1:N-1
        S[inds.A[k+1]...] = A[k]*Qinv[k]*A[k]' + B[k]*Rinv[k]*B[k]' + Qinv[k+1]
        S[inds.B[k+1]...] = A[k]*Qinv[k]*C[k]'     + B[k]*Rinv[k]*D[k]'
        S[inds.C[k+1]...] = C[k]*Qinv[k]*C[k]'         + D[k]*Rinv[k]*D[k]'
        if k < N-1
            S[inds.D[k+1]...] = -Qinv[k+1]*A[k+1]'
            S[inds.E[k+1]...] = -Qinv[k+1]*C[k+1]'
        else
            S[inds.E[k+1]...] = -Qinv[k+1]*C[k+1]'
        end
    end
    S[inds.C[1]...] = C[N]*Qinv[N]*C[N]'
    Symmetric(S)
    return nothing
    # return Symmetric(S)
end





function buildShurCompliment(prob::Problem, solver::SequentialNewtonSolver)
    n,m,N = size(prob)

    Qinv = solver.Qinv
    Rinv = solver.Rinv

    A = [F.xx for F in solver.∇F[2:end]]  # First jacobian is for initial condition
    B = [F.xu for F in solver.∇F[2:end]]
    C = [Array(F.x[a,:]) for (F,a) in zip(solver.∇C, solver.active_set)]
    D = [Array(F.u[a,:]) for (F,a) in zip(solver.∇C, solver.active_set)]

    P = num_active_constraints(solver)
    S = spzeros(P,P)

    _buildShurCompliment!(S, prob, solver, Qinv, Rinv, A, B, C, D)

    return Symmetric(S)
end

function _buildShurCompliment!(S, prob::Problem, solver::SequentialNewtonSolver, Qinv, Rinv, A, B, C, D)
    n,m,N = size(prob)

    p = sum.(solver.active_set)
    pcum = insert!(cumsum(p), 1, 0)

    dinds = 1:n
    cinds = n .+ (1:p[1])
    S[dinds,dinds] = Qinv[1]
    S[dinds,n .+ dinds] = Qinv[1]*A[1]'
    S[dinds,n .+ cinds] = Qinv[1]*C[1]'

    for k = 1:N-1
        off = pcum[k] + k*n
        dinds = off .+ (1:n)
        cinds = off + n .+ (1:p[k])
        S[dinds,dinds] = A[k]*Qinv[k]*A[k]' + B[k]*Rinv[k]*B[k]' + Qinv[k+1]
        S[dinds,cinds] = A[k]*Qinv[k]*C[k]' + B[k]*Rinv[k]*D[k]'
        S[cinds,cinds] = C[k]*Qinv[k]*C[k]' + D[k]*Rinv[k]*D[k]'
        if k < N-1
            S[dinds,dinds .+ (p[k] + n)] = -Qinv[k+1]*A[k+1]'
            S[dinds, (off + p[k] + 2n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        else
            S[dinds, (off + p[k] + n) .+ (1:p[k+1])] = -Qinv[k+1]*C[k+1]'
        end
    end
    off = pcum[N] + N*n
    cinds = off .+ (1:p[N])
    S[cinds,cinds] = C[N]*Qinv[N]*C[N]'

end
