#=
# 3D Poisson, Dirichlet bc
=#

### If the Finch package has already been added, use this line #########
using Finch # Note: to add the package, first do: ]add "https://github.com/paralab/Finch.git"

### If not, use these four lines (working from the examples directory) ###
# if !@isdefined(Finch)
#     include("../Finch.jl");
#     using .Finch
# end
##########################################################################

initFinch("poisson3d");
useLog("poisson3dlog", level=3)

n = 20;
ord = 1;

domain(3)
functionSpace(order=ord)

mesh(HEXMESH, elsperdim=n)

u = variable("u")
testSymbol("v")

boundary(u, 1, DIRICHLET, 0)

# Write the weak form 
coefficient("f", "-3*pi*pi*sin(pi*x)*sin(pi*y)*sin(pi*z)")
weakForm(u, "dot(grad(u), grad(v)) + f*v")

exportCode("poisson3dcode");
# importCode("poisson3dcode");

solve(u);

# outputValues(u, "p3dout", format="vtk", asci=false);

# exact solution is sin(pi*x)*sin(pi*y)*sin(pi*z)
# check error
maxerr = 0;
exact(x,y,z) = sin(pi*x)*sin(pi*y)*sin(pi*z);

for i=1:size(Finch.finch_state.grid_data.allnodes,2)
    x = Finch.finch_state.grid_data.allnodes[1,i];
    y = Finch.finch_state.grid_data.allnodes[2,i];
    z = Finch.finch_state.grid_data.allnodes[3,i];
    err = abs(u.values[i] - exact(x,y,z));
    global maxerr;
    maxerr = max(err,maxerr);
end
println("max error = "*string(maxerr));

finalizeFinch()
