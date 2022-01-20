#=
This will gradually evolve into working BTE code.
=#

if !@isdefined(Finch)
    include("../Finch.jl");
    using .Finch
end

# constants and various functions are in another file
include("bte-parameters.jl")

init_finch("FVbte2d");

useLog("FVbte2dlog", level=3)

# Configuration setup
domain(2)
solverType(FV)
timeStepper(EULER_EXPLICIT)
setSteps(2.5e-12, 200);

# A simple mesh is internally generated for convenience
# This matches the mesh in model_setup_BTE.in
mesh(QUADMESH, # quad elements
    elsperdim=[40,5], # elements in each direction: 20 x 5 uniform grid
    interval=[0, 1e-6, 0, 1e-7],  # interval in each direction: a very small rectangle
    bids=3) # 3 boundary IDs for this mesh correspond to left, right, top/bottom

# Indices, Variables, etc.
ndirs = 8
nbands = 4
direction = index("direction", range = [1,ndirs])
band = index("band", range = [1,nbands])

# These are all set as variables because they are unknown, but only I is solved for in the PDE.
I = variable("I", VAR_ARRAY, CELL, index = [direction, band]) # Intensity
Io = variable("Io", VAR_ARRAY, CELL, index = [band]) # Equilibrium intensity for each band
tau = variable("tau", VAR_ARRAY, CELL, index = [band]) # Relaxation time scale
temperature = variable("temperature", SCALAR, CELL) # temperature of each cell

# Coefficients and related numbers
(dir_x, dir_y) = get_directions_2d(ndirs)
(center_freq, delta_freq) = get_band_frequencies(nbands);
group_v = get_group_speeds(center_freq);

# These are set as coefficients because they have known values.
Sx = coefficient("Sx", dir_x, VAR_ARRAY) # direction x component
Sy = coefficient("Sy", dir_y, VAR_ARRAY) # direction y component
vg = coefficient("vg", group_v, VAR_ARRAY) # group speed

# A set of callback functions for the boundary condition
include("bte-boundary.jl")

boundary(I, 1, FLUX, ["isothermal_bdry(I, vg, Sx, Sy, $b, $d, normal, 99)" for d=1:ndirs, b=1:nbands]) # left (ID=1)
boundary(I, 2, FLUX, ["isothermal_bdry(I, vg, Sx, Sy, $b, $d, normal, 101)" for d=1:ndirs, b=1:nbands]) # right (ID=2)
boundary(I, 3, FLUX, ["isothermal_bdry(I, vg, Sx, Sy, $b, $d, normal, 100)" for d=1:ndirs, b=1:nbands]) # top and bottom (ID=3)

init_temp = 100; # The initial equilibrium temperature everywhere
initial(I, [equilibrium_intensity(center_freq[b], delta_freq, init_temp) for d=1:ndirs, b=1:nbands])
initial(Io, [equilibrium_intensity(center_freq[b], delta_freq, init_temp) for b=1:nbands])
initial(tau, [get_time_scale(center_freq[b], init_temp) for b=1:nbands])
initial(temperature, init_temp);

# The flux and source terms of the conservation equation
# F and S in the following equation:
# Dt(int(u dx)/A) = int(S dx) - int(F.n ds)
# BTE:
# Dt(int(Iij dx)) = int((Io-Iij)/tau dx) ) - vg * int(Iij * Si.n ds)
flux(I, "vg[band] * upwind([Sx[direction];Sy[direction]] , I[direction,band])") 
source(I, "(Io[band] - I[direction,band]) ./ tau[band]")

assemblyLoops(I, [band, direction, "elements"])

# Create an array to hold the values of I from the last step.
# To get initial values we have to manually initialize.
evalInitialConditions();
I_last = deepcopy(I.values);

# After each time step the temperature, equilibrium I, and time scales are updated
@postStepFunction(
    update_temperature(temperature.values, I_last, I.values, center_freq, delta_freq)
);

exportCode("bte2dcode") # uncomment to export generated code to a file
# importCode("bte2dcodein") # uncomment to import code from a file

solve(I)

finalize_finch()

##### Uncomment below to plot
xy = Finch.fv_info.cellCenters

# using Plots
# pyplot();
# p1 = plot(xy[1,:], xy[2,:], I.values[1,:], st=:surface)#, zlims=(0,Inf))
# p2 = plot(xy[1,:], xy[2,:], I.values[2,:], st=:surface)#, zlims=(0,Inf))
# p3 = plot(xy[1,:], xy[2,:], I.values[3,:], st=:surface)#, zlims=(0,Inf))
# p4 = plot(xy[1,:], xy[2,:], I.values[4,:], st=:surface)#, zlims=(0,Inf))
# p5 = plot(xy[1,:], xy[2,:], I.values[5,:], st=:surface)#, zlims=(0,Inf))
# p6 = plot(xy[1,:], xy[2,:], I.values[6,:], st=:surface)#, zlims=(0,Inf))
# p7 = plot(xy[1,:], xy[2,:], I.values[7,:], st=:surface)#, zlims=(0,Inf))
# p8 = plot(xy[1,:], xy[2,:], I.values[8,:], st=:surface)#, zlims=(0,Inf))
# display(plot(p1, p2, p3, p4, p5, p6, p7, p8, layout=8))

# display(plot(xy[1,:], xy[2,:], temperature.values[:], st=:surface));

# display(plot(xy[1,:], xy[2,:], get_integrated_intensity(I.values, ndirs, nbands)[1,:], st=:surface));