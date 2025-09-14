# Quadrotor in Maze
T = Float64

# model
model = Dynamics.quadrotor
model_d = rk3(model)
n = model.n; m = model.m
q0 = [1.;0.;0.;0.] # unit quaternion

x0 = zeros(T,n)
x0[1:3] = [0.; 0.; 10.]
x0[4:7] = q0

xf = zero(x0)
xf[1:3] = [0.;60.; 10.]
xf[4:7] = q0;

# cost
Q = (1.0e-3)*Diagonal(I,n)
Q[4:7,4:7] = (1.0e-2)*Diagonal(I,4)
R = (1.0e-4)*Diagonal(I,m)
Qf = 1000.0*Diagonal(I,n)

# constraints
r_quad_maze = 2.0
r_cylinder_maze = 2.0
maze_cylinders = []
zh = 3
l1 = 5
l2 = 4
l3 = 4
l4 = 10

for i = range(-25,stop=-10,length=l1)
    push!(maze_cylinders,(i, 10,r_cylinder_maze))
end

for i = range(10,stop=25,length=l1)
    push!(maze_cylinders,(i, 10, r_cylinder_maze))
end

for i = range(-5,stop=5,length=l3)
    push!(maze_cylinders,(i, 30, r_cylinder_maze))
end

for i = range(-25,stop=-10,length=l1)
    push!(maze_cylinders,(i, 50, r_cylinder_maze))
end

for i = range(10,stop=25,length=l1)
    push!(maze_cylinders,(i, 50, r_cylinder_maze))
end

for i = range(10+2*r_cylinder_maze,stop=50-2*r_cylinder_maze,length=l4)
    push!(maze_cylinders,(-25, i, r_cylinder_maze))
end

for i = range(10+2*r_cylinder_maze,stop=50-2*r_cylinder_maze,length=l4)
    push!(maze_cylinders,(25, i, r_cylinder_maze))
end

n_maze_cylinders = length(maze_cylinders)

function cI_maze(c,x,u)
    for i = 1:n_maze_cylinders
        c[i] = circle_constraint(x,maze_cylinders[i][1],maze_cylinders[i][2],maze_cylinders[i][3]+r_quad_maze)
    end
end

maze = Constraint{Inequality}(cI_maze,n,m,n_maze_cylinders,:maze)

u_min = 0.
u_max = 50.
x_max = Inf*ones(model.n)
x_min = -Inf*ones(model.n)

x_max[1:3] = [25.0; Inf; 20]
x_min[1:3] = [-25.0; -Inf; 0.]
bnd1 = BoundConstraint(n,m,u_min=u_min,u_max=u_max)
bnd2 = BoundConstraint(n,m,u_min=u_min,u_max=u_max,x_min=x_min,x_max=x_max)

xf_no_quat_U = copy(xf)
xf_no_quat_L = copy(xf)
xf_no_quat_U[4:7] .= Inf
xf_no_quat_L[4:7] .= -Inf
xf_no_quat_U[8:10] .= 0.
xf_no_quat_L[8:10] .= 0.
bnd_xf = BoundConstraint(n,m,x_min=xf_no_quat_L,x_max=xf_no_quat_U)

N = 101 # number of knot points
tf = 5.0
dt = tf/(N-1) # total time

U_hover = [0.5*9.81/4.0*ones(m) for k = 1:N-1] # initial hovering control trajectory
obj = LQRObjective(Q, R, Qf, xf, N) # objective with same stagewise costs

constraints = Constraints(N) # constraint trajectory
constraints[1] += bnd1
for k = 2:N-1
    constraints[k] += bnd2 + maze
end
constraints[N] += bnd_xf

quadrotor_maze = Problem(model_d, obj, constraints=constraints, x0=x0, xf=xf, N=N, dt=dt)
initial_controls!(quadrotor_maze,U_hover); # initialize problem with controls

X_guess = zeros(n,7)
X_guess[:,1] = x0
X_guess[:,7] = xf
X_guess[1:3,2:6] .= [0 -12.5 -20 -12.5 0 ;15 20 30 40 45 ;10 10 10 10 10]

X_guess[4:7,:] .= q0
X0 = interp_rows(N,tf,X_guess);
copyto!(quadrotor_maze.X,X0)

quadrotor_maze_objects = maze_cylinders
