#### General Assumptions of these TNEP Models ####
#
#

export run_tnep

type TNEPDataSets
    branches
    branch_indexes
    arcs_from
    arcs_to
    arcs
    bus_branches
    buspairs
    buspair_indexes
end

function run_tnep(file, model_constructor, solver; kwargs...)
    return run_generic_model(file, model_constructor, solver, post_tnep; solution_builder = get_tnep_solution, kwargs...) 
end

# the general form of the tnep optimization model
function post_tnep{T}(pm::GenericPowerModel{T})
    build_tnep_sets(pm) ## create the data sets we need
    
    variable_line_tnep(pm) 

    variable_complex_voltage(pm)
    variable_complex_voltage_tnep(pm)

    variable_active_generation(pm)
    variable_reactive_generation(pm)

    variable_active_line_flow(pm)
    variable_reactive_line_flow(pm)
    variable_active_line_flow_tnep(pm)
    variable_reactive_line_flow_tnep(pm)
                
    objective_tnep_cost(pm)
    
    constraint_theta_ref(pm)
    
    constraint_complex_voltage(pm)    
    constraint_complex_voltage_tnep(pm)

    for (i,bus) in pm.set.buses
        constraint_active_kcl_shunt_tnep(pm, bus)
        constraint_reactive_kcl_shunt_tnep(pm, bus)
    end

    for (i,branch) in pm.data["tnep_branches"].branches
        constraint_active_ohms_yt_tnep(pm, branch)
        constraint_reactive_ohms_yt_tnep(pm, branch) 
        constraint_phase_angle_difference_tnep(pm, branch)
        constraint_thermal_limit_from_tnep(pm, branch)
        constraint_thermal_limit_to_tnep(pm, branch)
    end
    
    for (i,branch) in pm.set.branches
        constraint_active_ohms_yt(pm, branch)
        constraint_reactive_ohms_yt(pm, branch)
        constraint_phase_angle_difference(pm, branch)
        constraint_thermal_limit_from(pm, branch)
        constraint_thermal_limit_to(pm, branch)
    end    
end

function get_tnep_solution{T}(pm::GenericPowerModel{T})
    sol = Dict{AbstractString,Any}()
    add_bus_voltage_setpoint(sol, pm)
    add_generator_power_setpoint(sol, pm)
    add_branch_flow_setpoint(sol, pm)
    add_branch_flow_setpoint_tnep(sol, pm)    
    add_branch_tnep_setpoint(sol, pm)
    return sol
end

#### TNEP specific variables

## Variables associated with building new lines
function variable_line_tnep{T}(pm::GenericPowerModel{T})
    branches = pm.data["tnep_data"].branches
    @variable(pm.model, 0 <= line_tnep[l in pm.data["tnep_data"].branch_indexes] <= 1, Int, start = getstart(branches, l, "line_tnep_start", 1.0))
    return line_tnep
end

# By default there is nothing to add that is specific to tnep since most of those variables
# are bus level, and not line level
function variable_complex_voltage_tnep{T}(pm::GenericPowerModel{T}; kwargs...)
end

function variable_complex_voltage_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T}; kwargs...)
    variable_voltage_magnitude_sqr_from_tnep(pm; kwargs...)
    variable_voltage_magnitude_sqr_to_tnep(pm; kwargs...)
    variable_complex_voltage_product_tnep(pm; kwargs...)
end


function variable_voltage_magnitude_sqr_from_tnep{T}(pm::GenericPowerModel{T})
    buses = pm.set.buses
    branches = pm.data["tnep_data"].branches
    @variable(pm.model, 0 <= w_from[i in pm.data["tnep_data"].branch_indexes] <= buses[branches[i]["f_bus"]]["vmax"]^2, start = getstart(pm.set.buses, i, "w_from_start", 1.001))
    return w_from
end

function variable_voltage_magnitude_sqr_to_on_off{T}(pm::GenericPowerModel{T})
    buses = pm.set.buses
    branches = pm.data["tnep_data"].branches
    @variable(pm.model, 0 <= w_to[i in pm.data["tnep_data"].branch_indexes] <= buses[branches[i]["t_bus"]]["vmax"]^2, start = getstart(pm.set.buses, i, "w_to", 1.001))
    return w_to
end

function variable_complex_voltage_product_tnep{T}(pm::GenericPowerModel{T})
    wr_min, wr_max, wi_min, wi_max = compute_voltage_product_bounds(pm)
    bi_bp = Dict([(i, (b["f_bus"], b["t_bus"])) for (i,b) in pm.data["tnep_data"].branches])
    @variable(pm.model, min(0, wr_min[bi_bp[b]]) <= wr[b in pm.data["tnep_data"].branch_indexes] <= max(0, wr_max[bi_bp[b]]), start = getstart(pm.data["tnep_data"].buspairs, bi_bp[b], "wr_start", 1.0))
    @variable(pm.model, min(0, wi_min[bi_bp[b]]) <= wi[b in pm.data["tnep_data"].branch_indexes] <= max(0, wi_max[bi_bp[b]]), start = getstart(pm.data["tnep_data"].buspairs, bi_bp[b], "wr_start"))
    return wr, wi
end

function variable_active_line_flow_tnep{T}(pm::GenericPowerModel{T}; bounded = true)
    branches = pm.data["tnep_data"].branches  
    if bounded
        @variable(pm.model, -branches[l]["rate_a"] <= p[(l,i,j) in pm.data["tnep_data"].arcs] <= branches[l]["rate_a"], start = getstart(branches, l, "p_start"))
    else
        @variable(pm.model, p[(l,i,j) in pm.data["tnep_data"].arcs], start = getstart(branches, l, "p_start"))
    end
    return p
end

function variable_active_line_flow_tnep{T <: StandardDCPForm}(pm::GenericPowerModel{T}; bounded = true)
    branches = pm.data["tnep_data"].branches    
    if bounded
        @variable(pm.model, -branches[l]["rate_a"] <= p[(l,i,j) in pm.data["tnep_data"].arcs_from] <= branches[l]["rate_a"], start = getstart(pm.data["tnep_data"].branches, l, "p_start"))
    else
        @variable(pm.model, p[(l,i,j) in pm.data["tnep_data"].arcs_from], start = getstart(branches, l, "p_start"))
    end

    p_expr = Dict([((l,i,j), 1.0*p[(l,i,j)]) for (l,i,j) in pm.data["tnep_data"].arcs_from])
    p_expr = merge(p_expr, Dict([((l,j,i), -1.0*p[(l,i,j)]) for (l,i,j) in pm.data["tnep_data"].arcs_from]))

    pm.model.ext[:p_expr] = p_expr
end

function variable_reactive_line_flow_tnep{T}(pm::GenericPowerModel{T}; bounded = true)
    branches = pm.data["tnep_data"].branches      
    if bounded
        @variable(pm.model, -branches[l]["rate_a"] <= q[(l,i,j) in pm.data["tnep_data"].arcs] <= branches[l]["rate_a"], start = getstart(branches, l, "q_start"))
    else
        @variable(pm.model, q[(l,i,j) in pm.data["tnep_data"].arcs], start = getstart(branches, l, "q_start"))
    end
    return q
end

function variable_reactive_line_flow_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}; bounded = true)
    # do nothing, this model does not have reactive variables
end



#### TNEP specific objectives

### Cost of building lines
function objective_tnep_cost{T}(pm::GenericPowerModel{T})
    line_tnep = getvariable(pm.model, :line_tnep)
    branches = pm.data["tnep_data"].branches
    return @objective(pm.model, Min, sum{ branches[i]["construction_cost"]*line_tnep[i], (i,branch) in branches} )
end

#### TNEP specific constraints

function constraint_active_ohms_yt_tnep{T}(pm::GenericPowerModel{T}, branch)
    return constraint_active_ohms_yt(pm, branch)
end

function constraint_reactive_ohms_yt_tnep{T}(pm::GenericPowerModel{T}, branch)
    return constraint_reactive_ohms_yt(pm, branch)
end

function constraint_phase_angle_difference_tnep{T}(pm::GenericPowerModel{T}, branch)
    return constraint_phase_angle_difference(pm, branch)
end

function constraint_active_ohms_yt_tnep{T <: AbstractACPForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    p_to = getvariable(pm.model, :p)[t_idx]
    v_fr = getvariable(pm.model, :v)[f_bus]
    v_to = getvariable(pm.model, :v)[t_bus]
    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    g = branch["g"]
    b = branch["b"]
    c = branch["br_b"]
    tr = branch["tr"]
    ti = branch["ti"]
    tm = tr^2 + ti^2 

    c1 = @NLconstraint(pm.model, p_fr == z*(g/tm*v_fr^2 + (-g*tr+b*ti)/tm*(v_fr*v_to*cos(t_fr-t_to)) + (-b*tr-g*ti)/tm*(v_fr*v_to*sin(t_fr-t_to))) )
    c2 = @NLconstraint(pm.model, p_to ==    z*(g*v_to^2 + (-g*tr-b*ti)/tm*(v_to*v_fr*cos(t_to-t_fr)) + (-b*tr+g*ti)/tm*(v_to*v_fr*sin(t_to-t_fr))) )
    return Set([c1, c2])
end

function constraint_active_ohms_yt_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    b = branch["b"]
    t_min = branch["off_angmin"]
    t_max = branch["off_angmax"]

    c1 = @constraint(pm.model, p_fr <= -b*(t_fr - t_to + t_max*(1-z)) )
    c2 = @constraint(pm.model, p_fr >= -b*(t_fr - t_to + t_min*(1-z)) )
    return Set([c1, c2])
end

function constraint_active_ohms_yt_tnep{T <: AbstractDCPLLForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    p_to = getvariable(pm.model, :p)[t_idx]
    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    b = branch["b"]
    t_min = branch["off_angmin"]
    t_max = branch["off_angmax"]

    c1 = @constraint(pm.model, p_fr <= -b*(t_fr - t_to + t_max*(1-z)) )
    c2 = @constraint(pm.model, p_fr >= -b*(t_fr - t_to + t_min*(1-z)) )

    t_m = max(abs(t_min),abs(t_max))
    c3 = @constraint(pm.model, p_fr + p_to >= branch["br_r"]*( (-branch["b"]*(t_fr - t_to))^2 - (-branch["b"]*(t_m))^2*(1-z) ) )
    return Set([c1, c2, c3])
end

function constraint_active_ohms_yt_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    p_to = getvariable(pm.model, :p)[t_idx]
    w_fr = getvariable(pm.model, :w_from)[i]
    w_to = getvariable(pm.model, :w_to)[i]
    wr = getvariable(pm.model, :wr)[i]
    wi = getvariable(pm.model, :wi)[i]

    g = branch["g"]
    b = branch["b"]
    c = branch["br_b"]
    tr = branch["tr"]
    ti = branch["ti"]
    tm = tr^2 + ti^2

    c1 = @constraint(pm.model, p_fr == g/tm*w_fr + (-g*tr+b*ti)/tm*(wr) + (-b*tr-g*ti)/tm*( wi) )
    c2 = @constraint(pm.model, p_to ==    g*w_to + (-g*tr-b*ti)/tm*(wr) + (-b*tr+g*ti)/tm*(-wi) )
    return Set([c1, c2])
end

function constraint_reactive_ohms_yt_tnep{T <: AbstractACPForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    q_fr = getvariable(pm.model, :q)[f_idx]
    q_to = getvariable(pm.model, :q)[t_idx]
    v_fr = getvariable(pm.model, :v)[f_bus]
    v_to = getvariable(pm.model, :v)[t_bus]
    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    g = branch["g"]
    b = branch["b"]
    c = branch["br_b"]
    tr = branch["tr"]
    ti = branch["ti"]
    tm = tr^2 + ti^2 

    c1 = @NLconstraint(pm.model, q_fr == z*(-(b+c/2)/tm*v_fr^2 - (-b*tr-g*ti)/tm*(v_fr*v_to*cos(t_fr-t_to)) + (-g*tr+b*ti)/tm*(v_fr*v_to*sin(t_fr-t_to))) )
    c2 = @NLconstraint(pm.model, q_to ==    z*(-(b+c/2)*v_to^2 - (-b*tr+g*ti)/tm*(v_to*v_fr*cos(t_fr-t_to)) + (-g*tr-b*ti)/tm*(v_to*v_fr*sin(t_to-t_fr))) )
    return Set([c1, c2])
end

function constraint_reactive_ohms_yt_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, branch)
    # Do nothing, this model does not have reactive variables
    return Set()
end

function constraint_reactive_ohms_yt_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)
    t_idx = (i, t_bus, f_bus)

    q_fr = getvariable(pm.model, :q)[f_idx]
    q_to = getvariable(pm.model, :q)[t_idx]
    w_fr = getvariable(pm.model, :w_from)[i]
    w_to = getvariable(pm.model, :w_to)[i]
    wr = getvariable(pm.model, :wr)[i]
    wi = getvariable(pm.model, :wi)[i]

    g = branch["g"]
    b = branch["b"]
    c = branch["br_b"]
    tr = branch["tr"]
    ti = branch["ti"]
    tm = tr^2 + ti^2

    c1 = @constraint(pm.model, q_fr == -(b+c/2)/tm*w_fr - (-b*tr-g*ti)/tm*(wr) + (-g*tr+b*ti)/tm*( wi) )
    c2 = @constraint(pm.model, q_to ==    -(b+c/2)*w_to - (-b*tr+g*ti)/tm*(wr) + (-g*tr-b*ti)/tm*(-wi) )
    return Set([c1, c2])
end

function constraint_phase_angle_difference_tnep{T <: AbstractACPForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]

    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    c1 = @constraint(pm.model, z*(t_fr - t_to) <= branch["angmax"])
    c2 = @constraint(pm.model, z*(t_fr - t_to) >= branch["angmin"])
    return Set([c1, c2])
end

function constraint_phase_angle_difference_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]

    t_fr = getvariable(pm.model, :t)[f_bus]
    t_to = getvariable(pm.model, :t)[t_bus]
    z = getvariable(pm.model, :line_tnep)[i]

    t_min = branch["off_angmin"]
    t_max = branch["off_angmax"]

    c1 = @constraint(pm.model, t_fr - t_to <= branch["angmax"]*z + t_max*(1-z))
    c2 = @constraint(pm.model, t_fr - t_to >= branch["angmin"]*z + t_min*(1-z))
    return Set([c1, c2])
end

function constraint_phase_angle_difference_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T}, branch)
    i = branch["index"]

    wr = getvariable(pm.model, :wr)[i]
    wi = getvariable(pm.model, :wi)[i]

    c1 = @constraint(pm.model, wi <= branch["angmax"]*wr)
    c2 = @constraint(pm.model, wi >= branch["angmin"]*wr)
    return Set([c1, c2])
end

# Generic on/off thermal limit constraint
function constraint_thermal_limit_from_tnep{T}(pm::GenericPowerModel{T}, branch; scale = 1.0)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    q_fr = getvariable(pm.model, :q)[f_idx]
    z = getvariable(pm.model, :line_tnep)[i]

    c = @constraint(pm.model, p_fr^2 + q_fr^2 <= branch["rate_a"]^2*z^2*scale)
    return Set([c])
end

function constraint_thermal_limit_from_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, branch; scale = 1.0)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)

    p_fr = getvariable(pm.model, :p)[f_idx]
    z = getvariable(pm.model, :line_tnep)[i]

    c1 = @constraint(pm.model, p_fr <= getupperbound(p_fr)*z)
    c2 = @constraint(pm.model, p_fr >= getlowerbound(p_fr)*z)
    return Set([c1, c2])
end

function constraint_thermal_limit_to_tnep{T}(pm::GenericPowerModel{T}, branch; scale = 1.0)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    t_idx = (i, t_bus, f_bus)

    p_to = getvariable(pm.model, :p)[t_idx]
    q_to = getvariable(pm.model, :q)[t_idx]
    z = getvariable(pm.model, :line_tnep)[i]

    c = @constraint(pm.model, p_to^2 + q_to^2 <= branch["rate_a"]^2*z^2*scale)
    return Set([c])
end

function constraint_thermal_limit_to_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, branch; scale = 1.0)
  # nothing to do, from handles both sides
  return Set()
end

function constraint_thermal_limit_to_tnep{T <: AbstractDCPLLForm}(pm::GenericPowerModel{T}, branch; scale = 1.0)
    i = branch["index"]
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    t_idx = (i, t_bus, f_bus)

    p_to = getvariable(pm.model, :p)[t_idx]
    z = getvariable(pm.model, :line_tnep)[i]

    c1 = @constraint(pm.model, p_to <= getupperbound(p_to)*z)
    c2 = @constraint(pm.model, p_to >= getlowerbound(p_to)*z)
    return Set([c1, c2])
end

function constraint_complex_voltage_tnep{T <: AbstractACPForm}(pm::GenericPowerModel{T})
    # do nothing, this model does not have complex voltage constraints
    return Set()
end

function constraint_complex_voltage_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T})
    # do nothing, this model does not have complex voltage variables
end

function constraint_complex_voltage_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T})
    buses = pm.set.buses
    branches = pm.data["tnep_data"].branches
    
    wr_min, wr_max, wi_min, wi_max = compute_voltage_product_bounds(pm)
    bi_bp = Dict([(i, (b["f_bus"], b["t_bus"])) for (i,b) in branches])
          
    w = getvariable(pm.model, :w)
    wr = getvariable(pm.model, :wr)
    wi = getvariable(pm.model, :wi)
    z = getvariable(pm.model, :line_tnep)

    w_from = getvariable(pm.model, :w_from)
    w_to = getvariable(pm.model, :w_to)

    cs = Set()
    for (l,i,j) in pm.data["tnep_data"].arcs_from
        c1 = @constraint(pm.model, w_from[l] <= z[l]*buses[branches[l]["f_bus"]]["vmax"]^2)
        c2 = @constraint(pm.model, w_from[l] >= z[l]*buses[branches[l]["f_bus"]]["vmin"]^2)
            
        c3 = @constraint(pm.model, wr[l] <= z[l]*wr_max[bi_bp[l]])
        c4 = @constraint(pm.model, wr[l] >= z[l]*wr_min[bi_bp[l]])
        c5 = @constraint(pm.model, wi[l] <= z[l]*wi_max[bi_bp[l]])
        c6 = @constraint(pm.model, wi[l] >= z[l]*wi_min[bi_bp[l]])
              
        c7 = @constraint(pm.model, w_to[l] <= z[l]*buses[branches[l]["t_bus"]]["vmax"]^2)
        c8 = @constraint(pm.model, w_to[l] >= z[l]*buses[branches[l]["t_bus"]]["vmin"]^2)
         
        c9 = relaxation_complex_product_on_off(pm.model, w[i], w[j], wr[l], wi[l], z[l])
        c10 = relaxation_equality_on_off(pm.model, w[i], w_from[l], z[l])
        c11 = relaxation_equality_on_off(pm.model, w[j], w_to[l], z[l])
        cs = Set([cs, c1, c2, c3, c4, c5, c6, c7, c8,c9, c10, c11])    
    end
    return cs
end


function constraint_active_kcl_shunt_tnep{T <: AbstractACPForm}(pm::GenericPowerModel{T}, bus)
    i = bus["index"]
    bus_branches = union(pm.set.bus_branches[i],pm.data["tnep_data"].bus_branches)
    bus_gens = pm.set.bus_gens[i]

    v = getvariable(pm.model, :v)
    p = getvariable(pm.model, :p)
    pg = getvariable(pm.model, :pg)

    c = @constraint(pm.model, sum{p[a], a in bus_branches} == sum{pg[g], g in bus_gens} - bus["pd"] - bus["gs"]*v[i]^2)
    return Set([c])
end

function constraint_active_kcl_shunt_tnep{T <: AbstractDCPForm}(pm::GenericPowerModel{T}, bus)
    i = bus["index"]
    bus_branches = union(pm.set.bus_branches[i],pm.data["tnep_data"].bus_branches)
    bus_gens = pm.set.bus_gens[i]

    pg = getvariable(pm.model, :pg)
    p_expr = pm.model.ext[:p_expr]

    c = @constraint(pm.model, sum{p_expr[a], a in bus_branches} == sum{pg[g], g in bus_gens} - bus["pd"] - bus["gs"]*1.0^2)
    return Set([c])
end

function constraint_active_kcl_shunt_tnep{T <: AbstractDCPLLForm}(pm::GenericPowerModel{T}, bus)
    i = bus["index"]
    bus_branches = union(pm.set.bus_branches[i],pm.data["tnep_data"].bus_branches)
    bus_gens = pm.set.bus_gens[i]

    pg = getvariable(pm.model, :pg)
    p = getvariable(pm.model, :p)

    c = @constraint(pm.model, sum{p[a], a in bus_branches} == sum{pg[g], g in bus_gens} - bus["pd"] - bus["gs"]*1.0^2)
    return Set([c])
end

function constraint_active_kcl_shunt_tnep{T <: AbstractWRForm}(pm::GenericPowerModel{T}, bus)
    i = bus["index"]
    bus_branches = union(pm.set.bus_branches[i],pm.data["tnep_data"].bus_branches)
    bus_gens = pm.set.bus_gens[i]

    w = getvariable(pm.model, :w)
    p = getvariable(pm.model, :p)
    pg = getvariable(pm.model, :pg)

    c = @constraint(pm.model, sum{p[a], a in bus_branches} == sum{pg[g], g in bus_gens} - bus["pd"] - bus["gs"]*w[i])
    return Set([c])
end

function constraint_active_kcl_shunt_tnep{T <: AbstractWRMForm}(pm::GenericPowerModel{T}, bus)
    i = bus["index"]
    bus_branches = union(pm.set.bus_branches[i],pm.data["tnep_data"].bus_branches)
    bus_gens = pm.set.bus_gens[i]

    WR = getvariable(pm.model, :WR)
    w_index = pm.model.ext[:lookup_w_index][i]
    w_i = WR[w_index, w_index]

    p = getvariable(pm.model, :p)
    pg = getvariable(pm.model, :pg)

    c = @constraint(pm.model, sum{p[a], a in bus_branches} == sum{pg[g], g in bus_gens} - bus["pd"] - bus["gs"]*w_i)
    return Set([c])
end




##### TNEP specific solution extractors
function add_branch_tnep_setpoint{T}(sol, pm::GenericPowerModel{T})
  add_setpoint(sol, pm, "new_branch", "index", "built", :line_tnep; default_value = (item) -> 1)
end

#### create some tnep specific sets
function build_tnep_sets{T}(pm::GenericPowerModel{T})    
    branch_data = Dict()
    if haskey(pm.data, "new_branch")
        branch_data = pm.data["new_branch"]
    end  
        
    branch_lookup = Dict([(Int(branch["index"]), branch) for branch in branch_data])

    # filter turned off stuff
    branch_lookup = filter((i, branch) -> branch["br_status"] == 1 && branch["f_bus"] in pm.set.bus_indexes && branch["t_bus"] in pm.set.bus_indexes, branch_lookup)

    arcs_from = [(i,branch["f_bus"],branch["t_bus"]) for (i,branch) in branch_lookup]
    arcs_to   = [(i,branch["t_bus"],branch["f_bus"]) for (i,branch) in branch_lookup]
    arcs = [arcs_from; arcs_to]

    bus_branches = Dict([(i, []) for (i,bus) in pm.set.buses])
    for (l,i,j) in arcs_from
        push!(bus_branches[i], (l,i,j))
        push!(bus_branches[j], (l,j,i))
    end

    branch_idxs = collect(keys(branch_lookup))

    buspair_indexes = collect(Set([(i,j) for (l,i,j) in arcs_from]))
    buspairs = buspair_parameters(buspair_indexes, branch_lookup, pm.set.buses)
    
    for (i, branch) in branch_lookup
        if !haskey(branch, "construction_cost")
            branch["construction_cost"] = 0
        end
    end
    
    pm.data["tnep_data"] = TNEPDataSets(branch_lookup, branch_idxs, arcs_from, arcs_to, arcs, bus_branches, buspairs, buspair_indexes)
end
      
      
      
      
      
      
      
      


