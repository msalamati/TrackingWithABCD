Random.seed!(7)

# model
T = Float64
integration = :rk4
model = Dynamics.quadrotor
model_d = discretize_model(model,integration)
n = model.n; m = model.m

# cost
Q = (1.0e-2)*Diagonal(I,n)
R = (1.0e-2)*Diagonal(I,m)
Qf = 1000.0*Diagonal(I,n)

# -initial state
x0 = zeros(n)
x0[1:3] = [0.; 0.; 0.]
q0 = [1.;0.;0.;0.]
x0[4:7] = q0

# -final state
xf = copy(x0)
xf[1:3] = [0.;50.;0.] # xyz position
xf[4:7] = q0

# options
verbose=false
opts_ilqr = iLQRSolverOptions{T}(verbose=verbose,cost_tolerance=1.0e-5)
opts_al = AugmentedLagrangianSolverOptions{T}(verbose=verbose,opts_uncon=opts_ilqr,constraint_tolerance=1.0e-3,cost_tolerance=1.0e-5,cost_tolerance_intermediate=1e-4)
opts_altro = ALTROSolverOptions{T}(verbose=verbose,opts_al=opts_al)

N = 101
dt = 0.05
U0 = [0.5*9.81/4.0*ones(m) for k = 1:N-1]
obj = TrajectoryOptimization.LQRObjective(Q,R,Qf,xf,N)


# unconstrained
prob = Problem(model_d, obj, x0=x0, N=N, dt=dt)
initial_controls!(prob, U0)
solve!(prob, opts_ilqr)
@test norm(prob.X[N] - xf) < 5.0e-3

# constrained w/ final position
goal_con = goal_constraint(xf)
con = [goal_con]
prob = Problem(model_d, obj,constraints=Constraints(con,N), x0=x0, N=N, dt=dt)
initial_controls!(prob, U0)
solve!(prob, opts_al)
@test norm(prob.X[N] - xf,Inf) < opts_al.constraint_tolerance
@test max_violation(prob) < opts_al.constraint_tolerance

# constrained w/ final position and control limits
bnd = BoundConstraint(n,m,u_min=0.0,u_max=15.0,trim=true)
con = [bnd,goal_con]
prob = Problem(model_d, obj, constraints=Constraints(con,N), x0=x0, N=N, dt=dt)
initial_controls!(prob, U0)
solve!(prob, opts_al)
@test norm(prob.X[N] - xf) < opts_al.constraint_tolerance
@test max_violation(prob) < opts_al.constraint_tolerance

# constrained w/ final position, control limits, obstacles
r_quad = 1.0
r_sphere = 3.0
spheres = ((0.,10.,0.,r_sphere),(0.,20.,0.,r_sphere),(0.,30.,0.,r_sphere))
n_spheres = 3

function sphere_obs3(c,x,u)
    for i = 1:n_spheres
        c[i] = TrajectoryOptimization.sphere_constraint(x,spheres[i][1],spheres[i][2],spheres[i][3],spheres[i][4]+r_quad)
    end
    return nothing
end

obs = Constraint{Inequality}(sphere_obs3,n,m,n_spheres,:obs)
con = [bnd,obs,goal_con]
prob_con = Constraints(con,N)
prob = Problem(model_d, obj, constraints=Constraints(con,N),x0=x0, N=N, dt=dt)
initial_controls!(prob, U0)
opts_al.constraint_tolerance=1.0e-3
opts_al.constraint_tolerance_intermediate=1.0e-3
solve!(prob, opts_al)
@test norm(prob.X[N] - xf,Inf) < opts_al.constraint_tolerance
@test max_violation(prob) < opts_al.constraint_tolerance
