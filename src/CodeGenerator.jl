#=
Module for code generation
=#
module CodeGenerator

export init_code_generator, finalize_code_generator, set_generation_target,
        generate_all_files, add_generated_file,
        # generate_main, generate_config, generate_prob, generate_mesh, generate_genfunction, 
        # generate_bilinear, generate_linear, generate_stepper, generate_output,
        generate_code_layer, generate_assembly_loops
        #, generate_code_layer_surface, generate_code_layer_fv

# See finch_import_symbols.jl for a list of all imported symbols.
import ..Finch: @import_finch_symbols
@import_finch_symbols()

genDir = "";
genFileName = "";
gen_file_extension = "";
comment_char = "";
block_comment_char = [""; ""];
headerText = "";
genfiles = [];
external_get_language_elements_function = nothing;
external_generate_code_layer_function = nothing;
external_generate_code_files_function = nothing;

# for custom targets
using_custom_target = false;
# Temporary placeholders for external code gen functions that must be provided.
# These are reassigned in set_custom_target()
function default_language_elements_function() return (".jl", "#", ["#=", "=#"]) end;
function default_code_layer_function(var, entities, terms, lorr, vors) return ("","") end;
function default_code_files_function(var, lhs_vol, lhs_surf, rhs_vol, rhs_surf) return 0 end;

# general code generator functions
include("code_generator_utils.jl");
include("generate_code_layer.jl");

# code gen functions for each solver type and target
include("generate_code_layer_cg_julia.jl");
include("generate_code_layer_dg_julia.jl");
include("generate_code_layer_fv_julia.jl");

# # target specific code gen functions
# include("generate_code_layer_dendro.jl");
# include("generate_code_layer_homg.jl");
# include("generate_code_layer_matlab.jl");
include("generate_code_layer_cachesim.jl");

# Surface integrals should be handled in the same place TODO
#include("generate_code_layer_surface.jl");

#Matlab
# include("generate_matlab_utils.jl");
# include("generate_matlab_files.jl");
# include("generate_homg_files.jl");
# #C++
# include("generate_cpp_utils.jl");
# include("generate_dendro_files.jl");


#### Note
# default Dendro parameters
# parameters = (5, 1, 0.3, 0.000001, 100);#(maxdepth, wavelet_tol, partition_tol, solve_tol, solve_max_iters)
####

function init_code_generator(dir, name, header)
    global gen_file_extension = ".jl";
    global comment_char = "#";
    global block_comment_char = ["#="; "=#"];
    global genDir = dir;
    global genFileName = name;
    global headerText = header;
    
    global external_get_language_elements_function = default_language_elements_function;
    global external_generate_code_layer_function = default_code_layer_function;
    global external_generate_code_files_function = default_code_files_function;
end

# Sets the functions to be used during external code generation
function set_generation_target(lang_elements, code_layer, file_maker)
    global external_get_language_elements_function = lang_elements;
    global external_generate_code_layer_function = code_layer;
    global external_generate_code_files_function = file_maker;
    global using_custom_target = true;
    global gen_file_extension;
    global comment_char;
    global block_comment_char;
    (gen_file_extension, comment_char, block_comment_char) = Base.invokelatest(external_get_language_elements_function);
end

function add_generated_file(filename; dir="", make_header_text=true)
    if length(dir) > 0
        code_dir = genDir*"/"*dir;
        if !isdir(code_dir)
            mkdir(code_dir);
        end
    else
        code_dir = genDir;
    end
    newfile = open(code_dir*"/"*filename, "w");
    push!(genfiles, newfile);
    if make_header_text
        generate_head(newfile, headerText);
    end
    
    return newfile;
end

function generate_all_files(var, lhs_vol, lhs_surf, rhs_vol, rhs_surf; parameters=0)
    if using_custom_target
        external_generate_code_files_function(var, lhs_vol, lhs_surf, rhs_vol, rhs_surf);
    end
end

function finalize_code_generator()
    for f in genfiles
        close(f);
    end
    log_entry("Closed generated code files.");
end

#### Utilities ####

function comment(file,line)
    println(file, comment_char * line);
end

function commentBlock(file,text)
    print(file, "\n"*block_comment_char[1]*"\n"*text*"\n"*block_comment_char[2]*"\n");
end

function generate_head(file, text)
    comment(file,"This file was generated by Finch.");
    commentBlock(file, text);
end

# for writing structs to binary files
# format is | number of structs[Int64] | sizes of structs[Int64*num] | structs |
function write_binary_head(f, num, szs)
    Nbytes = 0;
    write(f, num);
    Nbytes += sizeof(num)
    for i=1:length(szs)
        write(f, szs[i])
        Nbytes += sizeof(szs[i])
    end
    return Nbytes;
end

# Write an array to a binary file.
# Return number of bytes written.
function write_binary_array(f, a, with_counts=false)
    Nbytes = 0;
    if with_counts
        write(f, Int64(length(a)));
        if length(a) > 0 && isbits(a[1])
            write(f, Int64(sizeof(a[1])));
        else # empty aray or array of arrays has element size = 0
            write(f, Int64(0));
        end
    end
    for i=1:length(a)
        if isbits(a[i])
            write(f, a[i]);
            Nbytes += sizeof(a[i]);
        else
            Nbytes += write_binary_array(f,a[i], with_counts);
        end
    end
    return Nbytes;
end

# Assumes that the struct only has isbits->true types or arrays.
# Returns number of bytes written.
# with_counts=true will add number of pieces and size of pieces before each piece.(Int64, Int64)
function write_binary_struct(f, s, with_counts=false)
    Nbytes = 0;
    for fn in fieldnames(typeof(s))
        comp = getfield(s, fn);
        if isbits(comp)
            if with_counts
                write(f, Int64(1));
                write(f, Int64(sizeof(comp)));
            end
            write(f, comp);
            Nbytes += sizeof(comp)
        else
            Nbytes += write_binary_array(f,comp, with_counts);
        end
    end
    return Nbytes;
end

# Write the grid to a binary file intended to be imported in C++
# This includes various extra numbers to size the arrays.
function write_grid_to_file(file, grid)
    # various numbers
    write(file, Int(size(grid.allnodes,1)));    # dimension
    write(file, Int(size(grid.loc2glb,2)));     # This is local nel (owned + ghost)
    write(file, Int(size(grid.allnodes,2)));    # nnodes
    
    write(file, Int(size(grid.loc2glb,1)));     # nodes per element
    write(file, Int(size(grid.glbvertex,1)));   # vertices per element
    write(file, Int(size(grid.element2face,1)));# faces per element
    
    write(file, Int(size(grid.face2element,2)));# nfaces
    write(file, Int(size(grid.face2glb,1)));    # nodes per face
    
    # Now the data in grid
    write_binary_array(file, grid.allnodes, true);
    write_binary_array(file, grid.bdry, true);
    write_binary_array(file, grid.bdryface, true);
    write_binary_array(file, grid.bdrynorm, true);
    write_binary_array(file, grid.bids, true);
    write_binary_array(file, grid.loc2glb, true);
    write_binary_array(file, grid.glbvertex, true);
    write_binary_array(file, grid.face2glb, true);
    write_binary_array(file, grid.element2face, true);
    write_binary_array(file, grid.face2element, true);
    write_binary_array(file, grid.facenormals, true);
    write_binary_array(file, grid.faceRefelInd, true);
    write_binary_array(file, grid.facebid, true);
    
    write(file, Int(grid.is_subgrid));
    write(file, grid.nel_owned);
    write(file, grid.nel_ghost);
    write(file, grid.nface_owned);
    write(file, grid.nface_ghost);
    write(file, grid.nnodes_shared);
    write_binary_array(file, grid.grid2mesh, true);
    
    if grid.nel_ghost == 0 # FE only
        write_binary_array(file, grid.partition2global, true);
    end
    
    if grid.nel_ghost > 0 # FV only
        write_binary_array(file, grid.element_owner, true);
        write(file, grid.num_neighbor_partitions);
        write_binary_array(file, grid.neighboring_partitions, true);
        write_binary_array(file, grid.ghost_counts, true);
        write_binary_array(file, grid.ghost_index, true);
    end
    
end

# Write the refel to a binary file intended to be imported in C++
function write_refel_to_file(file, refel)
    write(file, refel.dim);     # dimension
    write(file, refel.N);       # order
    write(file, refel.Np);      # number of nodes
    write(file, refel.Nqp);     # number of quadrature points
    write(file, refel.Nfaces);  # number of faces
    write_binary_array(file, refel.Nfp, true); # number of face points per face
    # nodes and vandermonde
    write_binary_array(file, refel.r, true);
    write_binary_array(file, refel.wr, true);
    write_binary_array(file, refel.g, true);
    write_binary_array(file, refel.wg, true);
    write_binary_array(file, refel.V, true);
    write_binary_array(file, refel.gradV, true);
    write_binary_array(file, refel.invV, true);
    write_binary_array(file, refel.Vg, true);
    write_binary_array(file, refel.gradVg, true);
    write_binary_array(file, refel.invVg, true);
    # quadrature matrices
    write_binary_array(file, refel.Q, true);
    write_binary_array(file, refel.Qr, true);
    write_binary_array(file, refel.Qs, true);
    write_binary_array(file, refel.Qt, true);
    write_binary_array(file, refel.Ddr, true);
    write_binary_array(file, refel.Dds, true);
    write_binary_array(file, refel.Ddt, true);
    
    # surface versions
    write_binary_array(file, refel.face2local, true);
    write_binary_array(file, refel.surf_r, true);
    write_binary_array(file, refel.surf_wr, true);
    write_binary_array(file, refel.surf_g, true);
    write_binary_array(file, refel.surf_wg, true);
    write_binary_array(file, refel.surf_V, true);
    write_binary_array(file, refel.surf_gradV, true);
    write_binary_array(file, refel.surf_Vg, true);
    write_binary_array(file, refel.surf_gradVg, true);
    
    write_binary_array(file, refel.surf_Q, true);
    write_binary_array(file, refel.surf_Qr, true);
    write_binary_array(file, refel.surf_Qs, true);
    write_binary_array(file, refel.surf_Qt, true);
    write_binary_array(file, refel.surf_Ddr, true);
    write_binary_array(file, refel.surf_Dds, true);
    write_binary_array(file, refel.surf_Ddt, true);
end

# Write the geometric factors to a binary file intended to be imported in C++
function write_geometric_factors_to_file(file, geofacs)
    if size(geofacs.detJ,1) > 1
        write(file, Int8(1)); # Constant jacobian
    else
        write(file, Int8(0)); # NOT Constant jacobian
    end
    
    # number of elements
    write(file, Int(size(geofacs.detJ, 2)));
    # number of values per element
    write(file, Int(size(geofacs.detJ, 1)));
    
    write_binary_array(file, geofacs.detJ, true);
    
    for i=1:length(geofacs.J)
        write_binary_array(file, geofacs.J[i].rx, true);
        write_binary_array(file, geofacs.J[i].ry, true);
        write_binary_array(file, geofacs.J[i].rz, true);
        write_binary_array(file, geofacs.J[i].sx, true);
        write_binary_array(file, geofacs.J[i].sy, true);
        write_binary_array(file, geofacs.J[i].sz, true);
        write_binary_array(file, geofacs.J[i].tx, true);
        write_binary_array(file, geofacs.J[i].ty, true);
        write_binary_array(file, geofacs.J[i].tz, true);
    end
    
    write_binary_array(file, geofacs.volume, true);
    write_binary_array(file, geofacs.area, true);
    write_binary_array(file, geofacs.face_detJ, true);
end

end # module