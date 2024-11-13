"Simulate state trajectory with feedback control"
function rollout!(prob::Problem{T},solver::iLQRSolver{T},alpha::T=1.0) where T
    X = prob.X; U = prob.U
    K = solver.K; d = solver.d; X̄ = solver.X̄; Ū = solver.Ū
    X̄[1] = prob.x0

    for k = 2:prob.N
        # Calculate state trajectory difference
        δx = state_diff(X̄[k-1],X[k-1],prob,solver)

        # Calculate updated control
        Ū[k-1] = U[k-1] + K[k-1]*δx + alpha*d[k-1]

        # Propagate dynamics
        evaluate!(X̄[k], prob.model, X̄[k-1], Ū[k-1], get_dt(prob,Ū[k-1]))

        # Check that rollout has not diverged
        if ~(norm(X̄[k],Inf) < solver.opts.max_state_value && norm(Ū[k-1],Inf) < solver.opts.max_control_value)
            return false
        end
    end
    return true
end

function rollout!(prob::Problem{T}) where T
    N = prob.N
    if !all(isfinite.(to_array(prob.X)))
        prob.X[1] = prob.x0
        rollout!(prob.X, prob.model, prob.U, get_dt_traj(prob))
    end
end

function rollout!(X::AbstractVectorTrajectory, model::Model{M,Discrete}, U::AbstractVectorTrajectory, dt) where {M,T}
    N = length(X)
    for k = 1:N-1
        evaluate!(X[k+1], model, X[k], U[k], dt[k])
    end
end

function rollout(model::Model{M,Discrete}, x0::Vector, U::AbstractVectorTrajectory, dt) where M
    n = model.n
    N = length(U)+1
    X = [zero(x0) for k = 1:N]
    X[1] = x0
    rollout!(X, model, U, dt)
    return X
end
rollout(prob::Problem{T,Discrete}) where T = rollout(prob.model, prob.x0, prob.U, prob.dt)

function state_diff(x̄::Vector{T},x::Vector{T},prob::Problem{T},solver::iLQRSolver{T}) where T
    if true
        x̄ - x
    else
        nothing #TODO quaternion
    end
end
