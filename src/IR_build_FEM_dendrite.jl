#=
Functions for building an IR from the DSL for FEM type problems.
This version is specific to dendrite because dendrite does
things so different that the regular IR would not work


=#
function build_IR_fem_dendrite(input_exprs, var, indices, config, prob, time_stepper)
    lhs_vol = input_exprs[1];
    rhs_vol = input_exprs[2];
    lhs_surf = input_exprs[3];
    rhs_surf = input_exprs[4];
    lhs_bdry = input_exprs[5];
    rhs_bdry = input_exprs[6];
    lhs_dbdry = input_exprs[7];
    rhs_dbdry = input_exprs[8];
    lhs_nbdry = input_exprs[9];
    rhs_nbdry = input_exprs[10];
    
    dimension = config.dimension;
    refel = finch_state.refel;
    # Count variables, dofs, and store offsets
    varcount = 1;
    dofsper = 0;
    dofsper_loop = 0;
    offset_ind = [0];
    if typeof(var) <:Array
        varcount = length(var);
        offset_ind = zeros(Int, varcount);
        dofsper = var[1].total_components;
        dofsper_loop = length(var[1].symvar);
        for i=2:length(var)
            offset_ind[i] = dofsper;
            dofsper = dofsper + var[i].total_components;
            dofsper_loop = dofsper_loop + length(var[i].symvar);
        end
    else
        var = [var]; # put it in an array for consistency
        offset_ind = zeros(Int, 1);
        dofsper = var[1].total_components;
        dofsper_loop = length(var[1].symvar);
    end
    
    IRtypes = IR_entry_types();
    
    # These blocks will hold the IR
    allocate_block = IR_block_node([],"allocation");
    
    # coefficient prep
    vec_coefficient_block = IR_block_node([],"prepare vector");
    mat_coefficient_block = IR_block_node([],"prepare matrix");
    vec_face_coefficient_block = IR_block_node([],"prepare vector face");
    mat_face_coefficient_block = IR_block_node([],"prepare matrix face");
    vec_bdry_coefficient_block = IR_block_node([],"prepare vector boundary");
    mat_bdry_coefficient_block = IR_block_node([],"prepare matrix boundary");
    vec_dbdry_coefficient_block = IR_block_node([],"prepare vector Dirichlet");
    mat_dbdry_coefficient_block = IR_block_node([],"prepare matrix Dirichlet");
    vec_nbdry_coefficient_block = IR_block_node([],"prepare vector Neumann");
    mat_nbdry_coefficient_block = IR_block_node([],"prepare matrix Neumann");
    
    # elemental computation
    matrix_block = IR_block_node([],"elemental matrix");
    vector_block = IR_block_node([],"elemental vector");
    matrix_face_block = IR_block_node([],"face matrix");
    vector_face_block = IR_block_node([],"face vector");
    matrix_bdry_block = IR_block_node([],"boundary matrix");
    vector_bdry_block = IR_block_node([],"boundary vector");
    matrix_dbdry_block = IR_block_node([],"Dirichlet matrix");
    vector_dbdry_block = IR_block_node([],"Dirichlet vector");
    matrix_nbdry_block = IR_block_node([],"Neumann matrix");
    vector_nbdry_block = IR_block_node([],"Neumann vector");
    
    # coefficient prep
    # a list of all entities and rhs only ones
    separate_entities = [[],[],[],[],[],[],[],[],[],[]];
    
    # extract entities for each piece
    for i=1:10
        if !(input_exprs[i] === nothing)
            separate_entities[i] = extract_entities(input_exprs[i]);
        end
    end
    
    # coefficient perparation
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[1], var, dimension, 1); # LHS volume
    push!(mat_coefficient_block.parts, IR_comment_node("Evaluate coefficients for volume matrix."));
    append!(mat_coefficient_block.parts, coef);
    
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[2], var, dimension, 2); # RHS volume
    push!(vec_coefficient_block.parts, IR_comment_node("Evaluate coefficients for volume vector."));
    append!(vec_coefficient_block.parts, coef);
    
    # surface coefficients
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[3], var, dimension, 3); # LHS surface
    push!(mat_face_coefficient_block.parts, IR_comment_node("Evaluate coefficients for surface matrix."));
    append!(mat_face_coefficient_block.parts, coef);
    
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[4], var, dimension, 4); # RHS surface
    push!(vec_face_coefficient_block.parts, IR_comment_node("Evaluate coefficients for surface vector."));
    append!(vec_face_coefficient_block.parts, coef);
    
    # bdry coefficients
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[5], var, dimension, 5); # LHS bdry
    push!(mat_bdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for boundary matrix."));
    append!(mat_bdry_coefficient_block.parts, coef);
    
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[6], var, dimension, 6); # RHS bdry
    push!(vec_bdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for boundary vector."));
    append!(vec_bdry_coefficient_block.parts, coef);
    
    # dirichlet bdry coefficients
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[7], var, dimension, 7); # LHS bdry
    push!(mat_dbdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for Dirichlet boundary matrix."));
    append!(mat_dbdry_coefficient_block.parts, coef);
    
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[8], var, dimension, 8); # RHS bdry
    push!(vec_dbdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for Dirichlet boundary vector."));
    append!(vec_dbdry_coefficient_block.parts, coef);
    
    # neumann bdry coefficients
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[9], var, dimension, 9); # LHS bdry
    push!(mat_nbdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for Neumann boundary matrix."));
    append!(mat_nbdry_coefficient_block.parts, coef);
    
    coef = prepare_coefficient_values_fem_dendrite(separate_entities[10], var, dimension, 10); # RHS bdry
    push!(vec_nbdry_coefficient_block.parts, IR_comment_node("Evaluate coefficients for Neumann boundary vector."));
    append!(vec_nbdry_coefficient_block.parts, coef);
    
    
    # computation
    if !(lhs_vol === nothing)
        lhsvol_terms = process_terms(lhs_vol);
        push!(matrix_block.parts, make_elemental_computation_fem_dendrite(lhsvol_terms, var, dofsper, offset_ind, LHS, "volume"));
    end
    if !(rhs_vol === nothing)
        rhsvol_terms = process_terms(rhs_vol);
        push!(vector_block.parts, make_elemental_computation_fem_dendrite(rhsvol_terms, var, dofsper, offset_ind, RHS, "volume"));
    end
    if !(lhs_surf === nothing) 
        lhssurf_terms = process_terms(lhs_surf);
        push!(matrix_face_block.parts, make_elemental_computation_fem_dendrite(lhssurf_terms, var, dofsper, offset_ind, LHS, "surface"));
    end
    if !(rhs_surf === nothing)
        rhssurf_terms = process_terms(rhs_surf);
        push!(vector_face_block.parts, make_elemental_computation_fem_dendrite(rhssurf_terms, var, dofsper, offset_ind, RHS, "surface"));
    end
    if !(lhs_bdry === nothing) 
        lhs_bdry_terms = process_terms(lhs_bdry);
        push!(matrix_bdry_block.parts, make_elemental_computation_fem_dendrite(lhs_bdry_terms, var, dofsper, offset_ind, LHS, "boundary"));
    end
    if !(rhs_bdry === nothing)
        rhs_bdry_terms = process_terms(rhs_bdry);
        push!(vector_bdry_block.parts, make_elemental_computation_fem_dendrite(rhs_bdry_terms, var, dofsper, offset_ind, RHS, "boundary"));
    end
    if !(lhs_dbdry === nothing) 
        lhs_dbdry_terms = process_terms(lhs_dbdry);
        push!(matrix_dbdry_block.parts, make_elemental_computation_fem_dendrite(lhs_dbdry_terms, var, dofsper, offset_ind, LHS, "dirichlet"));
    end
    if !(rhs_dbdry === nothing)
        rhs_dbdry_terms = process_terms(rhs_dbdry);
        push!(vector_dbdry_block.parts, make_elemental_computation_fem_dendrite(rhs_dbdry_terms, var, dofsper, offset_ind, RHS, "dirichlet"));
    end
    if !(lhs_nbdry === nothing) 
        lhs_nbdry_terms = process_terms(lhs_nbdry);
        push!(matrix_nbdry_block.parts, make_elemental_computation_fem_dendrite(lhs_nbdry_terms, var, dofsper, offset_ind, LHS, "neumann"));
    end
    if !(rhs_nbdry === nothing)
        rhs_nbdry_terms = process_terms(rhs_nbdry);
        push!(vector_nbdry_block.parts, make_elemental_computation_fem_dendrite(rhs_nbdry_terms, var, dofsper, offset_ind, RHS, "neumann"));
    end
    
    # Put them all together in a master block
    # For this target they can just be put in directly like this
    # because the code generator will just insert these pieces where needed.
    master_block = IR_block_node([
        allocate_block,
        
        mat_coefficient_block,
        vec_coefficient_block,
        mat_face_coefficient_block,
        vec_face_coefficient_block,
        mat_bdry_coefficient_block,
        vec_bdry_coefficient_block,
        mat_dbdry_coefficient_block,
        vec_dbdry_coefficient_block,
        mat_nbdry_coefficient_block,
        vec_nbdry_coefficient_block,
        
        matrix_block,
        vector_block,
        matrix_face_block,
        vector_face_block,
        matrix_bdry_block,
        vector_bdry_block,
        matrix_dbdry_block,
        vector_dbdry_block,
        matrix_nbdry_block,
        vector_nbdry_block,
    ],"master");
    
    return master_block;
end

# Allocate, compute, or fetch all needed values
# group determines lhs_vol=1, rhs_vol=2, lhs_surf=3, rhs_surf=4
# for constant coefficients: value__f_1 = 2
# for genfunction coefficients: value__f_1 = genfunction_1(pt)
# for known variables: value__u_1 = ??????????????
function prepare_coefficient_values_fem_dendrite(entities, var, dimension, group)
    IRtypes = IR_entry_types();
    row_col_matrix_index = IR_operation_node(IRtypes.named_op, [:ROWCOL_TO_INDEX, :row, :col, :nodes_per_element]);
    col_row_matrix_index = IR_operation_node(IRtypes.named_op, [:ROWCOL_TO_INDEX, :col, :row, :nodes_per_element]);
    
    # These parts will be returned
    coef_part = Vector{IR_part}(undef,0); # Coefficient evaluation/preparation inside elemental loop
    
    # Check to see if derivative matrices are needed
    # needed_derivative_matrices = fill(false, 8); # 1,2,3 = x,y,z quadrature points, 5,6,7 = nodes
    need_normals = false;
    
    unique_entity_names = []; # avoid duplicate names
    
    # Is it LHS or RHS
    if group in [1,3,5,7,9]
        leftOrRight = LHS;
    else
        leftOrRight = RHS;
    end
    
    # What kind of integral is it?
    if group < 3
        integral = "volume";
    elseif group < 5
        integral = "surface";
    elseif group < 7
        integral = "boundary";
    elseif group < 9
        integral = "dirichlet";
    else 
        integral = "neumann";
    end
    
    # Loop over entities to perpare for each one
    for i=1:length(entities)
        if is_test_function(entities[i])
            # Do nothing
        elseif is_unknown_var(entities[i], var) && leftOrRight == LHS
            # Do nothing
        else  # It is a coefficient(number or function) or known variable(array)
            cname = make_entity_name(entities[i]);
            is_unique = true;
            for n in unique_entity_names
                if cname == n && is_unique
                    is_unique = false;
                    break;
                end
            end
            if is_unique
                push!(unique_entity_names, cname); # 
            else
                continue;
            end
            
            (ctype, cval) = get_coef_val(entities[i]);
            if ctype == -1
                # It was a special symbol like dt or normal or something
                if entities[i].name == "FACENORMAL1" || entities[i].name == "FACENORMAL2"
                    need_normals = true;
                end
                
            elseif ctype == 0
                # It was a number. Do nothing.
                
            elseif ctype == 1 # a constant wrapped in a coefficient will be replaced by a number
                push!(coef_part, IR_operation_node(IRtypes.assign_op,[
                    IR_data_node(IRtypes.float_data, Symbol(cname)), cval]))
                
            elseif ctype == 2 || ctype == 4 # a coefficient function or indexed coefficient function
                # Build the index IR
                if typeof(entities[i].index) <: Array
                    # It is an indexed variable
                    if length(entities[i].index) == 1
                        indstr = "INDEX_VAL_"*entities[i].index[1];
                        index_IR = Symbol(indstr);
                    else
                        # There is more than one index. Need to form an expression for it.
                        indstr = "(INDEX_VAL_"*entities[i].index[1];
                        index_IR = Symbol(indstr);
                        indices = finch_state.variables[cval].indexer;
                        for indi=2:length(entities[i].index)
                            indstr *= " + ("*string(length(indices[indi-1].range))*"*(INDEX_VAL_"*entities[i].index[indi]*"-1)";
                            this_ind = "INDEX_VAL_"*entities[i].index[indi];
                            index_IR = IR_operation_node(IRtypes.math_op, [:+, index_IR,
                                IR_operation_node(IRtypes.math_op, [:*, length(indices[indi-1].range),
                                    IR_operation_node(IRtypes.math_op, [:-, Symbol(this_ind), 1])])]);
                        end
                        for indi=1:length(entities[i].index)
                            indstr *= ")";
                        end
                    end
                    
                else
                    indstr = string(entities[i].index);
                    index_IR = entities[i].index;
                end
                # Assign the value
                if integral in ["volume","surface","boundary","dirichlet","neumann"]
                    coef_index = get_coef_index(entities[i]);
                    
                    push!(coef_part, IR_operation_node(IRtypes.assign_op,[
                        IR_data_node(IRtypes.float_data, Symbol(cname)),
                        IR_operation_node(IRtypes.named_op, [:COEF_EVAL, coef_index, index_IR, :x, :y, :z, :t, :nodeID, 0, :index_values])
                    ]));
                    
                else # other integral types
                    # 
                    println("unexpected integral type: "*integral);
                end
                
            elseif ctype == 3 # a known variable value
                # Build the index IR
                if typeof(entities[i].index) <: Array
                    # It is an indexed variable
                    if length(entities[i].index) == 1
                        indstr = "INDEX_VAL_"*entities[i].index[1];
                        index_IR = Symbol(indstr);
                    else
                        # There is more than one index. Need to form an expression for it.
                        indstr = "(INDEX_VAL_"*entities[i].index[1];
                        index_IR = Symbol(indstr);
                        indices = finch_state.variables[cval].indexer;
                        for indi=2:length(entities[i].index)
                            indstr *= " + ("*string(length(indices[indi-1].range))*"*(INDEX_VAL_"*entities[i].index[indi]*"-1)";
                            this_ind = "INDEX_VAL_"*entities[i].index[indi];
                            index_IR = IR_operation_node(IRtypes.math_op, [:+, index_IR,
                                IR_operation_node(IRtypes.math_op, [:*, length(indices[indi-1].range),
                                    IR_operation_node(IRtypes.math_op, [:-, Symbol(this_ind), 1])])]);
                        end
                        for indi=1:length(entities[i].index)
                            indstr *= ")";
                        end
                    end
                    
                else
                    indstr = string(entities[i].index);
                    index_IR = entities[i].index;
                end
                
                if integral in ["volume","surface","boundary","dirichlet","neumann"]
                    # This should only happen when refering to the value from a previous time step
                    # in which case it should be in prev_solution.
                    # Need to figure out the dofind
                    varcount = length(var);
                    dofind = 0;
                    for i=1:length(var)
                        if var[i].index == cval
                            if typeof(index_IR) <: Number
                                dofind += index_IR;
                            else
                                dofind = IR_operation_node(IRtypes.math_op, [:+, dofind, index_IR]);
                            end
                            break;
                        end
                        dofind += var[i].total_components;
                    end
                    dofsper = 0;
                    for i=1:length(var)
                        dofsper += var[i].total_components;
                    end
                    
                    if "PREV2" in entities[i].flags
                        push!(coef_part, IR_operation_node(IRtypes.assign_op,[
                            IR_data_node(IRtypes.float_data, Symbol(cname)),
                            IR_operation_node(IRtypes.named_op, [:KNOWN_VAR, dofind, index_IR, 2])
                        ]));
                    else
                        push!(coef_part, IR_operation_node(IRtypes.assign_op,[
                            IR_data_node(IRtypes.float_data, Symbol(cname)),
                            IR_operation_node(IRtypes.named_op, [:KNOWN_VAR, dofind, index_IR, 1])
                        ]));
                    end
                    
                else # If another integral type is different
                    #
                    println("unexpected integral type: "*integral);
                end
            end
        end # if coefficient
    end # entity loop
    
    return coef_part;
end

#=
This is just the inner loop statements in
for row=...
    for col=...
        double N = 0;
        N += (COMPUTATION)     <- These parts
        ...
        
        A[row, col] += N;
    end
end

for row=...
    double N = 0;
    N += (COMPUTATION)     <- These parts
    ...
    
    b[row] += N;
end
=#
function make_elemental_computation_fem_dendrite(terms, var, dofsper, offset_ind, leftOrRight, integral)
    # Here is where I make some assumption about the form of the expression.
    # Since it was expanded by the parser it should look like a series of terms: t1 + t2 + t3...
    # Where each term is multiplied by one test function component, and if LHS, involves one unknown component.
    # The submatrix modified by a term is determined by these, so go through the terms and divide them
    # into their submatrix expressions. 
    # Each term will look something like 
    # LHS: test_part * weight_part * coef_part * trial_part
    # RHS: test_part * weight_part * coef_part
    
    # LINALG_MATRIX_BLOCK and LINALG_VECTOR_BLOCK are special named ops that include these args
    # matrix: n_blocks, blockwidth, matrixname, i,j,term_IR, k,l,term_IR, ... up to n_blocks
    # vector: similar but one index per block
    
    IRtypes = IR_entry_types();
    
    # This will be returned
    compute_block = IR_block_node([],"elemental compute");
    comment_block = IR_block_node([IR_comment_node("Computation before simplifying. For inspection."), IR_comment_node("#=")], "compute comments");
    
    # Separate the factors of each term into test, trial, coef and form the calculation
    if dofsper > 1
        # # Submatrices or subvectors for each component
        # if leftOrRight == LHS
        #     submatrices = Array{Vector{IR_part}, 2}(undef, dofsper, dofsper);
        #     for i=1:dofsper
        #         for j=1:dofsper
        #             submatrices[i,j] = [];
        #         end
        #     end
        # else # RHS
        #     submatrices = Array{Vector{IR_part}, 1}(undef, dofsper);
        #     for j=1:dofsper
        #         submatrices[j] = [];
        #     end
        # end
        
        # if typeof(var) <: Array
        #     for vi=1:length(var) # variables
        #         # Process the terms for this variable
        #         for ci=1:length(terms[vi]) # components
        #             for i=1:length(terms[vi][ci])
        #                 (test_part, trial_part, coef_part, test_ind, trial_ind) = generate_term_calculation_fem_dendrite(terms[vi][ci][i], var, leftOrRight, integral, finch_state.config, finch_state.refel);
                        
        #                 # Turn these three parts into an expression like A'DB or A'Dv = A'd
        #                 # Where D is a diagonal matrix specified by a vector in the IR
        #                 if leftOrRight == LHS
        #                     term_IR = IR_operation_node(IRtypes.named_op, [:LINALG_TDM, test_part, coef_part, trial_part]);
        #                 else
        #                     term_IR = IR_operation_node(IRtypes.named_op, [:LINALG_Tv, test_part, coef_part]);
        #                 end
                        
        #                 # Find the appropriate submatrix for this term
        #                 submati = offset_ind[vi] + test_ind;
        #                 submatj = trial_ind;
        #                 if leftOrRight == LHS
        #                     submat_ind = submati + dofsper * (submatj-1);
        #                 else
        #                     submat_ind = submati;
        #                 end
                        
        #                 push!(submatrices[submat_ind], term_IR);
        #             end
        #         end
                
        #     end # vi
            
        # else # only one variable
        #     # Process the terms for this variable
        #     for ci=1:length(terms) # components
        #         for i=1:length(terms[ci])
        #             (test_part, trial_part, coef_part, test_ind, trial_ind) = generate_term_calculation_fem_dendrite(terms[ci][i], var, leftOrRight, integral, finch_state.config, finch_state.refel);
                    
        #             # Turn these three parts into an expression like A'DB or A'Dv = A'd
        #             # Where D is a diagonal matrix specified by a vector in the IR
        #             if leftOrRight == LHS
        #                 term_IR = IR_operation_node(IRtypes.named_op, [:LINALG_TDM, test_part, coef_part, trial_part]);
        #             else
        #                 term_IR = IR_operation_node(IRtypes.named_op, [:LINALG_Tv, test_part, coef_part]);
        #             end
                    
        #             # Find the appropriate submatrix for this term
        #             if leftOrRight == LHS
        #                 submat_ind = test_ind + dofsper * (trial_ind-1);
        #             else
        #                 submat_ind = test_ind;
        #             end
                    
        #             push!(submatrices[submat_ind], term_IR);
        #         end
        #     end
            
        # end
        
        # # Put the submatrices together into element_matrix or element_vector
        # num_nonzero_blocks = 0;
        
        # if leftOrRight == LHS
        #     linalg_matrix_block_args = [];
        #     push!(linalg_matrix_block_args, :LINALG_MATMAT_BLOCKS);
        #     push!(linalg_matrix_block_args, 0);
        #     push!(linalg_matrix_block_args, :nodes_per_element);
        #     push!(linalg_matrix_block_args, :element_matrix);
        #     for smi=1:dofsper
        #         for smj=1:dofsper
        #             submat_ind = smj + (smi-1)*dofsper;
        #             if length(submatrices[smi,smj]) > 0
        #                 if length(submatrices[smi,smj]) > 1
        #                     new_term_vec = [];
        #                     push!(new_term_vec, :+);
        #                     append!(new_term_vec, submatrices[smi,smj]);
        #                     submat_rhs = IR_operation_node(IRtypes.math_op, new_term_vec);
        #                 else
        #                     submat_rhs = submatrices[smi,smj][1];
        #                 end
        #                 # push!(compute_block.parts, IR_operation_node(IRtypes.named_op, [
        #                 #                             :LINALG_MATMAT_BLOCKS, 
        #                 #                             smi, smj, :nodes_per_element, :element_matrix, submat_rhs]));
        #                 push!(linalg_matrix_block_args, smi);
        #                 push!(linalg_matrix_block_args, smj);
        #                 push!(linalg_matrix_block_args, submat_rhs);
                        
        #                 num_nonzero_blocks += 1;
        #             end
        #         end
        #     end
        #     linalg_matrix_block_args[2] = num_nonzero_blocks;
        #     push!(compute_block.parts, IR_operation_node(IRtypes.named_op, linalg_matrix_block_args));
            
        # else # RHS
        #     linalg_vector_block_args = [];
        #     push!(linalg_vector_block_args, :LINALG_MATVEC_BLOCKS);
        #     push!(linalg_vector_block_args, 0);
        #     push!(linalg_vector_block_args, :nodes_per_element);
        #     push!(linalg_vector_block_args, :element_vector);
        #     for smj=1:dofsper
        #         if length(submatrices[smj]) > 0
        #             if length(submatrices[smj]) > 1
        #                 new_term_vec = [];
        #                 push!(new_term_vec, :+);
        #                 append!(new_term_vec, submatrices[smj]);
        #                 submat_rhs = IR_operation_node(IRtypes.math_op, new_term_vec);
        #             else
        #                 submat_rhs = submatrices[smj][1];
        #             end
                    
        #             # push!(compute_block.parts, IR_operation_node(IRtypes.named_op, [
        #             #                             :LINALG_MATVEC_BLOCKS, 
        #             #                             smj, :nodes_per_element, :element_vector, submat_rhs]));
        #             push!(linalg_vector_block_args, smj);
        #             push!(linalg_vector_block_args, submat_rhs);
                    
        #             num_nonzero_blocks += 1;
        #         end
        #     end
        #     linalg_vector_block_args[2] = num_nonzero_blocks;
        #     push!(compute_block.parts, IR_operation_node(IRtypes.named_op, linalg_vector_block_args));
        # end
        
        
    else # one dof
        terms = terms[1][1];
        term_vec = Vector{IR_part}(undef,0);
        
        # N = 0;
        push!(compute_block.parts, IR_operation_node(IRtypes.assign_op,[
            IR_data_node(IRtypes.float_data, :N), 0.0]));
        
        #process each term
        for i=1:length(terms)
            (test_part, trial_part, coef_part, test_ind, trial_ind) = generate_term_calculation_fem_dendrite(terms[i], var, leftOrRight, integral, finch_state.config, finch_state.refel);
            
            # Turn these three parts into an expression like A'DB or A'Dv = A'd
            # Where D is a diagonal matrix specified by a vector in the IR
            # Note T=transpose matrix, D=diagonal matrix, M=matrix, v=vector, t=transpose vector
            if leftOrRight == LHS
                # N += fe.XX(row...) * wdetj * coef_part * fe.YY(col...)
                term_IR = IR_operation_node(IRtypes.math_op, [:*, test_part, coef_part, trial_part]);
            else
                # N += fe.XX(row...) * wdetj * coef_part
                term_IR = IR_operation_node(IRtypes.math_op, [:*, test_part, coef_part]);
            end
            
            push!(term_vec, term_IR);
            
        end
        
        # Make a separate N += ... line for each term
        for i=1:length(term_vec)
            push!(compute_block.parts, IR_operation_node(IRtypes.math_assign_op,[:+, 
                IR_data_node(IRtypes.float_data, :N), term_vec[i]]));
            push!(comment_block.parts, IR_operation_node(IRtypes.math_assign_op,[:+, 
                IR_data_node(IRtypes.float_data, :N), term_vec[i]]));
        end
        
        if leftOrRight == LHS
            # Ae(row,col) += N
            push!(compute_block.parts, IR_operation_node(IRtypes.math_assign_op,[:+,
                #IR_data_node(IRtypes.float_data, :Ae, [:?,:?], [:row, :col]),
                IR_operation_node(IRtypes.function_op, [:Ae, :row, :col]),
                IR_data_node(IRtypes.float_data, :N)
            ]));
        else
            #be(row) += N
            push!(compute_block.parts, IR_operation_node(IRtypes.math_assign_op,[:+,
                #IR_data_node(IRtypes.float_data, :be, [:?], [:row]),
                IR_operation_node(IRtypes.function_op, [:be, :row]),
                IR_data_node(IRtypes.float_data, :N)
            ]));
        end
    end
    
    push!(comment_block.parts, IR_comment_node("=#"));
    
    return compute_block;
end

# This takes a term expression that should have a form like test_part * (coef_parts) * trial_part
# The parts are separated, test and trial parts are translated into quadrature matrices (refel.Q or RQn)
# and they are returned as IR_parts
function generate_term_calculation_fem_dendrite(term, var, leftOrRight, integral, config, refel)
    IRtypes = IR_entry_types();
    
    if leftOrRight == LHS
        (test_ex, trial_ex, coef_ex, test_ind, trial_ind) = separate_factors(term, var);
    else
        (test_ex, trial_ex, coef_ex, test_ind, trial_ind) = separate_factors(term);
    end
    
    test_negative = false;
    if (typeof(test_ex) == Expr) && (test_ex.head == :call && (test_ex.args[1] == :- || test_ex.args[1] == :.-) && length(test_ex.args) == 2)
        test_ex = test_ex.args[2];
        test_negative = true;
    end
    trial_negative = false;
    if (typeof(trial_ex) == Expr) && (trial_ex.head == :call && (trial_ex.args[1] == :- || trial_ex.args[1] == :.-) && length(trial_ex.args) == 2)
        trial_ex = trial_ex.args[2];
        trial_negative = true;
        if test_negative
            test_negative = false;
            trial_negative = false;
        end
    end
    
    # Determine the matrix corresponding to test and trial
    if typeof(test_ex) == SymEntity
        if integral in ["volume","surface","boundary","dirichlet","neumann"]
            if length(test_ex.derivs) == 2
                # fe.d2N(row, d1, d2)
                deriv_index1 = test_ex.derivs[1];
                deriv_index2 = test_ex.derivs[2];
                test_part = IR_operation_node(IRtypes.member_op, [:fe,
                    IR_operation_node(IRtypes.function_op, [:d2N, :row, deriv_index1-1, deriv_index2-1])
                ])
            elseif length(test_ex.derivs) == 1
                # fe.dN(row, d)
                deriv_index = test_ex.derivs[1];
                test_part = IR_operation_node(IRtypes.member_op, [:fe,
                    IR_operation_node(IRtypes.function_op, [:dN, :row, deriv_index-1])
                ])
            else
                # fe.N(row)
                test_part = IR_operation_node(IRtypes.member_op, [:fe,
                    IR_operation_node(IRtypes.function_op, [:N, :row])
                ])
            end
        else # other integral types?
            #
            println("unexpected integral type: "*integral);
        end
        
    else
        test_part = nothing;
    end
    
    if typeof(trial_ex) == SymEntity
        if integral in ["volume","surface","boundary","dirichlet","neumann"]
            if length(trial_ex.derivs) == 2
                # fe.d2N() TODO
            elseif length(trial_ex.derivs) == 1
                # fe.dN(col, d)
                deriv_index = trial_ex.derivs[1];
                trial_part = IR_operation_node(IRtypes.member_op, [:fe,
                    IR_operation_node(IRtypes.function_op, [:dN, :col, deriv_index-1])
                ])
            else
                # fe.N(col)
                trial_part = IR_operation_node(IRtypes.member_op, [:fe,
                    IR_operation_node(IRtypes.function_op, [:N, :col])
                ])
            end
        else # other integral types
            #
            println("unexpected integral type: "*integral);
        end
    else
        trial_part = nothing;
    end
    
    # Turn the coefficient part into IR
    wg_part = IR_data_node(IRtypes.float_data, :wdetj);
    if trial_negative || test_negative
        wg_part = IR_operation_node(IRtypes.math_op, [:-, wg_part]);
    end
    
    if !(coef_ex === nothing)
        coef_part = arithmetic_expr_to_IR(coef_ex);
        coef_part = IR_operation_node(IRtypes.math_op, [:*, wg_part, coef_part]);
    else
        coef_part = wg_part;
    end
    
    return (test_part, trial_part, coef_part, test_ind, trial_ind);
end
