#=
1D Euler equations
=#

### If the Finch package has already been added, use this line #########
using Finch # Note: to add the package, first do: ]add "https://github.com/paralab/Finch.git"

### If not, use these four lines (working from the examples directory) ###
# if !@isdefined(Finch)
#     include("../Finch.jl");
#     using .Finch
# end
##########################################################################

initFinch("FVeuler1d");

useLog("FVeuler1dlog", level=3)

# Configuration setup
domain(1) # 1D
solverType(FV)
timeStepper(RK4)
timeInterval(0.2)

# Mesh
ord = 2 # order used for flux
n = Int(ceil(150/ord)) # number of elements scaled for subdividing for higher orders
mesh(LINEMESH, elsperdim=n) # A uniform 1D mesh of the unit interval.

if ord > 1
    finiteVolumeOrder(ord)
end

# Primitive variables
r = variable("r", location=CELL)
u = variable("u", location=CELL)
p = variable("p", location=CELL)
U = [r, u, p];

# Conserved variables
q1 = variable("q1", location=CELL)
q2 = variable("q2", location=CELL)
q3 = variable("q3", location=CELL)
Q = [q1, q2, q3];

# Transformations between the variable sets
U2Q = variableTransform(U, Q, 
(U) -> (
    gamma = 1.4;
    Q = [U[1],
         U[1] * U[2],
         U[3] / (gamma-1) + 0.5 * U[1] * U[2] * U[2]];
    return Q;
))
Q2U = variableTransform(Q, U, 
(Q) -> (
    gamma = 1.4;
    U = [Q[1],
         Q[2] / Q[1],
         (gamma-1) * (Q[3] - 0.5 * Q[2] * Q[2] / Q[1])];
    return U;
))

# Shock tube initial conditions
initial(r, "x<0.3 ? 1 : 0.125")
initial(u, "x<0.3 ? 0.75 : 0")
initial(p, "x<0.3 ? 1 : 0.1")
evalInitialConditions(); # set U initial conditions
transformVariable(U2Q); # set Q initial conditions

# Boundary conditions
boundary(q1, 1, NO_BC) # equivalent to transmissive bdry
boundary(q2, 1, NO_BC)
boundary(q3, 1, NO_BC)

# The flux function
@callbackFunction(
    function flux_u2(r1,u1,p1, r2,u2,p2, comp, normal)
        gamma = 1.4;
        # The normal points from cell 1 to cell 2
        # So "left" is currently cell 1
        if normal < 0
            # swap left and right
            tmpr = r1; tmpu = u1; tmpp = p1;
            r1 = r2;   u1 = u2;   p1 = p2;
            r2 = tmpr; u2 = tmpu; p2 = tmpp;
        end
        c1 = sqrt(gamma*p1/r1);
        M1 = u1/c1;
        c2 = sqrt(gamma*p2/r2);
        M2 = u2/c2;
        
        if comp == 1 # rho
            if M1 < -1
                Fp = 0;
            elseif M1 > 1
                Fp = r1 * u1;
            elseif M1 >= -1 && M1 < 0
                Fp = r1*(u1+c1)/(2*gamma);
            else # 0 < M < 1
                Fp = r1*u1 - r1*(u1-c1)/(2*gamma);
            end
            
            if M2 < -1
                Fm = r2*u2;
            elseif M2 > 1
                Fm = 0;
            elseif M2 >= -1 && M2 < 0
                Fm = r2*u2 - r2*(u2+c2)/(2*gamma);
            else # 0 < M < 1
                Fm = r2*(u2-c2)/(2*gamma);
            end
            
        elseif comp == 2 # u
            if M1 < -1
                Fp = 0;
            elseif M1 > 1
                Fp = p1 + r1 * u1*u1;
            elseif M1 >= -1 && M1 < 0
                Fp = r1*(u1+c1)/(2*gamma) * (u1+c1);
            else # 0 < M < 1
                Fp = p1 + r1 * u1*u1 - r1*(u1-c1)/(2*gamma) * (u1-c1);
            end
            
            if M2 < -1
                Fm = p2 + r2 * u2*u2;
            elseif M2 > 1
                Fm = 0;
            elseif M2 >= -1 && M2 < 0
                Fm = p2 + r2 * u2*u2 - r2*(u2+c2)/(2*gamma) * (u2+c2);
            else # 0 < M < 1
                Fm = r2*(u2-c2)/(2*gamma) * (u2-c2);
            end
            
        elseif comp == 3 # p
            if M1 < -1
                Fp = 0;
            elseif M1 > 1
                Fp = u1 * (p1 + p1/(gamma-1) + r1*u1*u1*0.5);
            elseif M1 >= -1 && M1 < 0
                Fp = r1*(u1+c1)/(2*gamma) * ((u1+c1)^2/2+(3-gamma)/(gamma-1)*c1^2/2);
            else # 0 < M < 1
                Fp = u1 * (p1 + p1/(gamma-1) + r1*u1*u1*0.5) - (r1*(u1-c1)/(2*gamma) * ((u1-c1)^2/2+(3-gamma)/(gamma-1)*c1^2/2));
            end
            
            if M2 < -1
                Fm = u2 * (p2 + p2/(gamma-1) + r2*u2*u2*0.5);
            elseif M2 > 1
                Fm = 0;
            elseif M2 >= -1 && M2 < 0
                Fm = u2 * (p2 + p2/(gamma-1) + r2*u2*u2*0.5) - (r2*(u2+c2)/(2*gamma) * ((u2+c2)^2/2+(3-gamma)/(gamma-1)*c2^2/2));
            else # 0 < M < 1
                Fm = r2*(u2-c2)/(2*gamma) * ((u2-c2)^2/2+(3-gamma)/(gamma-1)*c2^2/2);
            end
        end
        return (Fp + Fm) * normal;
    end
)

# Need to update primitive variables each time conserved variables are changed.
@postStepFunction(
    transformVariable(Q2U)
);

# Everything has been set. Now write the equation and generate code.
conservationForm(Q, ["surface(flux_u2(left(r),left(u),left(p), right(r),right(u),right(p), $i, normal()))" for i in 1:3])

#= Note:
To get a reconstructed value for a variable r,
    "r"         -> A centered interpolation
    "left(r)"   -> extrapolated from cells on side 1 of the face (the normal vector points from side 1 to side 2)
    "right(r)"  -> similar, but for side 2
    "central(r)"-> similar to "r"
In all cases, neighborhoods that are truncated by a boundary will simply use fewer cells.
Boundary faces will use one ghost cell identical to the interior cell.
The side1/2 orientation is tied to the normal vector. The normal points from 1 to 2.
=#

# For inspecting the generated code, look in "fveuler1dcode.jl"
# If you wish to modify it and reimport, use importCode("fveuler1dcode") instead.
# Importing will override anything previously generated.
exportCode("fveuler1dcode")
# importCode("fveuler1dcode")

# Solve for the conserved variables because the equations were defined for them.
# Since primitive variables are also updated in the post-step function,
# they are implicitly being solved for.
solve(Q)

finalizeFinch()

##### Uncomment below to plot

# x = Finch.finch_state.fv_info.cellCenters[:];

# using Plots
# pyplot();
# display(plot([x x x], [r.values[:] u.values[:] p.values[:]], markershape=:circle, label=["density" "speed" "pressure"]))
