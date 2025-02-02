#= 
# A set of tools for parsing Finch input expressions into symEngine expressions.
# The terms are assumed to be integrated over element volume unless wrapped by one of these:
# surface(...) : integral over all element surfaces
# boundary(...) : integral over all boundary surfaces
# dirichletBoundary(...) : integral over dirichlet boundary surfaces
# neumannBoundary(...) : integral over neumann boundary surfaces
=#
module SymbolicParser
export sp_parse, add_custom_op, add_custom_op_file, sym_var

# See finch_import_symbols.jl for a list of all imported symbols.
import ..Finch: @import_finch_symbols
@import_finch_symbols()
import ..Finch: build_symexpressions

using SymEngine, LinearAlgebra

struct CallbackPlaceholder
    name::String
    args::Array
end
Base.show(io::IO, x::CallbackPlaceholder) = print(io, to_string(x));
function to_string(x::CallbackPlaceholder)
    argstr = "";
    for i=1:length(x.args)
        if i>1
            argstr *= ", ";
        end
        if typeof(x.args[i]) <: Array
            if length(x.args[i]) == 1
                argstr *= string(x.args[i][1]);
            else
                argstr *= "[";
                for j=1:length(x.args[i])
                    if j>1
                        argstr *= ", ";
                    end
                    argstr *= string(x.args[i][j]);
                end
                argstr *= "]";
            end
        else
            argstr *= string(x.args[i]);
        end
    end
    return x.name*"("*argstr*")"
end

include("symbolic_stepper_reformat.jl");
include("symbolic_utils.jl");

# These are special function symbols that need to be defined.
# They can be used in operators.
@funs(conditional)
@funs(symbolmin)
@funs(symbolmax)
@funs(isgreaterthan)
@funs(islessthan)
@funs(indexing_operator)

import Base.*, Base./, Base.+, Base.-
# a special operator for dealing with scalars when the scalar is in an array
function *(a::Array{Basic,1}, b::Array{Basic,1})
    if size(a) == (1,)
        return b.*a[1];
    elseif size(b) == (1,)
        return a.*b[1];
    elseif size(a) == size(b)
        # This should be an error, but I will treat it as a dot product for lazy people
        return [transpose(a) * b];
    else
        return SymEngine.*(a,b);
    end
end
function /(a::Array{Basic,1}, b::Array{Basic,1})
    if size(a) == (1,)
        return a[1]./b;
    elseif size(b) == (1,)
        return a./b[1];
    else
        return SymEngine./(a,b);
    end
end
# operators for dealing with numbers and Basic arrays
function *(a::Number, b::Array{Basic,1}) return a.*b; end
function +(a::Number, b::Array{Basic,1}) return a.+b; end
function -(a::Number, b::Array{Basic,1}) return a.-b; end
function /(a::Number, b::Array{Basic,1}) return a./b; end
function *(a::Array{Basic,1}, b::Number) return a.*b; end
function +(a::Array{Basic,1}, b::Number) return a.+b; end
function -(a::Array{Basic,1}, b::Number) return a.-b; end
function /(a::Array{Basic,1}, b::Number) return a./b; end
function -(a::Array{Basic,1}) return .-a; end

# Adds a single custom operator
function add_custom_op(s::Symbol, handle::Function)
    ops = finch_state.ops;
    # check to see if op is already defined
    # replace if it is
    foundit = false;
    for i=1:length(ops)
        if ops[i].symbol === s
            ops[i] = SymOperator(s, handle);
            foundit = true;
            break;
        end
    end
    if !foundit
        push!(ops, SymOperator(s, handle));
        log_entry("Added custom operator: "*string(s), 2);
    else
        log_entry("Replaced existing operator: "*string(s), 2);
    end
end

# Includes a set of custom operators
# The file will include an array of symbols and an array of function handles
function add_custom_op_file(file::String)
    include(file);
    for i=1:length(_names)
        add_custom_op(_names[i], _handles[i]);
    end
end

# Builds an array of symbolic layer symbols
function sym_var(name::String, type::String, components::Int=1)
    if type == VAR_ARRAY
        # These must be indexed
        symvar = [symbols("_"*name*"_INDEXED")];
        
    else
        symvar = [symbols("_"*name*"_1")];
        for i=2:components
            push!(symvar, symbols("_"*name*"_"*string(i)));
        end
    end
    
    return symvar;
end

# Parses a variational or integral form expression into a SymEngine Basic expression 
# Takes an Expr and variable symbols
# The symbols are only for determining lhs vs. rhs
# Returns an array of SymEngine expressions:
# [lhs, rhs, surflhs, surfrhs, bdrylhs, bdryrhs, dirichletlhs, dirichletrhs, neumannlhs, neumannrhs]
# If these pieces are not present, they are nothing
# lhs contains terms including the unknown variable
# rhs contains terms without it
function sp_parse(ex, var; is_FV::Bool=false, is_flux::Bool=false)
    resultExpressions = [];
    append!(resultExpressions, fill(nothing,10));
    # These will hold the relevant expressions if they are present
    lhs = nothing;
    rhs = nothing;
    surflhs = nothing;
    surfrhs = nothing;
    bdrylhs = nothing;
    bdryrhs = nothing;
    dbdrylhs = nothing;
    dbdryrhs = nothing;
    nbdrylhs = nothing;
    nbdryrhs = nothing;
    
    varcount = 1;
    timederiv = false;
    placeholders = [];
    
    log_entry("SP expr = "*string(ex), 3);
    
    # Check that there are as many vars as exs
    if typeof(var) <: Array
        if !(typeof(ex) <:Array && length(var) == length(ex))
            printerr("Error: Need same # of unknowns and equations");
            return (nothing,nothing);
        end
        varcount = length(var);
    end
    
    # Work with a copy of ex
    if typeof(ex) == Symbol
        symex = ex;
    else
        symex = copy(ex);
    end
    
    # Insert parameters
    symex = insert_parameters(symex);
    log_entry("SP insert parameters -> "*string(symex), 3);
    
    # Replace symbols for variables, coefficients, test functions, and special operators
    symex = replace_symbols(symex);
    log_entry("SP replace symbols -> "*string(symex), 3);
    
    # Look for indexes like [i] where i is an indexer
    if length(finch_state.indexers) > 0
        symex = handle_indexers(symex);
        log_entry("SP symbolic indicies -> "*string(symex), 3);
    end
    
    # Look for callbacks like CALLBACK_f(a,b,c), process their arguments, and replace them with placeholder vars
    symex = handle_callbacks(symex, placeholders);
    log_entry("SP handle callbacks -> "*string(symex), 3);
    for i=1:length(placeholders)
        log_entry("    PLACEHOLDER_"*string(i)*": "*to_string(placeholders[i]), 3);
    end
    
    # change some operators like ^ and / to broadcast versions .^ ./
    symex = broadcast_ops(symex);
    
    # Evaluate the expression to apply symbolic operators
    symex = apply_ops(symex);
    log_entry("SP apply ops -> "*string(symex), 3);
    
    # If the result of this is not in the proper array structure, fix it
    if typeof(var) <: Array
        if !(typeof(symex) <: Array)
            symex = [[symex]];
        else
            for i=1:length(symex)
                if !(typeof(symex[i]) <: Array)
                    symex[i] = [symex[i]];
                end
            end
        end
    else
        if !(typeof(symex) <: Array)
            symex = [symex];
        end
    end
    
    
    # Expand the expression and separate terms
    sterms = get_sym_terms(symex);
    log_entry("SP sterms = "*string(sterms), 3);
    
    # Check for time derivatives
    timederiv = check_for_symbol(sterms, "TIMEDERIV");
    
    # Check for surface integrals
    has_surface = check_for_symbol(sterms, "SURFACEINTEGRAL");
    has_bdry = check_for_symbol(sterms, "BOUNDARYINTEGRAL");
    has_Dbdry = check_for_symbol(sterms, "DIRICHLETINTEGRAL");
    has_Nbdry = check_for_symbol(sterms, "NEUMANNINTEGRAL");
    
    # Each element has an lhs and rhs
    # Also isolate terms that are nonlinear in the unknown
    lhs = copy(sterms); # set up the container right
    rhs = copy(sterms);
    nlt = copy(sterms);
    nlv = copy(sterms);
    has_nonlinear = false;
    if typeof(var) <: Array
        for i=1:length(symex)
            sz = size(symex[i]);
            (lhs[i],rhs[i],nlt[i],nlv[i]) = split_left_right_nonlinear(sterms[i],sz,var);
            if length(rhs[i]) == 0
                rhs[i] = [Basic(0)];
            end
            if length(nlt[i]) > 0 || has_nonlinear
                has_nonlinear = true;
            end
        end
    else
        sz = size(symex);
        (lhs,rhs,nlt,nlv) = split_left_right_nonlinear(sterms,sz,var);
        if length(rhs[1]) == 0
            rhs[1] = [Basic(0)];
        end
        if length(nlt) > 0
            has_nonlinear = true;
        end
    end
    
    # If there was a time derivative, separate those terms as well
    if timederiv
        dtlhs = copy(lhs);
        dtrhs = copy(rhs);
        if typeof(var) <: Array
            for i=1:length(symex)
                sz = size(symex[i]);
                (dtlhs[i],lhs[i]) = split_on_symbol("TIMEDERIV", lhs[i], sz);
                (dtrhs[i],rhs[i]) = split_on_symbol("TIMEDERIV", rhs[i], sz);
            end
        else
            sz = size(symex);
            (dtlhs,lhs) = split_on_symbol("TIMEDERIV", lhs,sz);
            (dtrhs,rhs) = split_on_symbol("TIMEDERIV", rhs,sz);
        end
    end
    
    # If there was a surface integral, separate those terms as well
    if has_surface
        surflhs = copy(lhs);
        surfrhs = copy(rhs);
        if typeof(var) <: Array
            for i=1:length(symex)
                sz = size(symex[i]);
                (surflhs[i],lhs[i]) = split_on_symbol("SURFACEINTEGRAL", lhs[i],sz);
                (surfrhs[i],rhs[i]) = split_on_symbol("SURFACEINTEGRAL", rhs[i],sz);
            end
        else
            sz = size(symex);
            (surflhs,lhs) = split_on_symbol("SURFACEINTEGRAL", lhs,sz);
            (surfrhs,rhs) = split_on_symbol("SURFACEINTEGRAL", rhs,sz);
        end
    end
    
    # If there was a boundary integral, separate those terms as well
    if has_bdry
        bdrylhs = copy(lhs);
        bdryrhs = copy(rhs);
        if typeof(var) <: Array
            for i=1:length(symex)
                sz = size(symex[i]);
                (bdrylhs[i],lhs[i]) = split_on_symbol("BOUNDARYINTEGRAL", lhs[i],sz);
                (bdryrhs[i],rhs[i]) = split_on_symbol("BOUNDARYINTEGRAL", rhs[i],sz);
            end
        else
            sz = size(symex);
            (bdrylhs,lhs) = split_on_symbol("BOUNDARYINTEGRAL", lhs,sz);
            (bdryrhs,rhs) = split_on_symbol("BOUNDARYINTEGRAL", rhs,sz);
        end
    end
    
    # If there was a dirichletBoundary integral, separate those terms as well
    if has_Dbdry
        dbdrylhs = copy(lhs);
        dbdryrhs = copy(rhs);
        if typeof(var) <: Array
            for i=1:length(symex)
                sz = size(symex[i]);
                (dbdrylhs[i],lhs[i]) = split_on_symbol("DIRICHLETINTEGRAL", lhs[i],sz);
                (dbdryrhs[i],rhs[i]) = split_on_symbol("DIRICHLETINTEGRAL", rhs[i],sz);
            end
        else
            sz = size(symex);
            (dbdrylhs,lhs) = split_on_symbol("DIRICHLETINTEGRAL", lhs,sz);
            (dbdryrhs,rhs) = split_on_symbol("DIRICHLETINTEGRAL", rhs,sz);
        end
    end
    
    # If there was a neumannBoundary integral, separate those terms as well
    if has_Nbdry
        nbdrylhs = copy(lhs);
        nbdryrhs = copy(rhs);
        if typeof(var) <: Array
            for i=1:length(symex)
                sz = size(symex[i]);
                (nbdrylhs[i],lhs[i]) = split_on_symbol("NEUMANNINTEGRAL", lhs[i],sz);
                (nbdryrhs[i],rhs[i]) = split_on_symbol("NEUMANNINTEGRAL", rhs[i],sz);
            end
        else
            sz = size(symex);
            (nbdrylhs,lhs) = split_on_symbol("NEUMANNINTEGRAL", lhs,sz);
            (nbdryrhs,rhs) = split_on_symbol("NEUMANNINTEGRAL", rhs,sz);
        end
    end
    
    log_entry("SP LHS = "*string(lhs), 3);
    log_entry("SP RHS = "*string(rhs), 3);
    if timederiv
        log_entry("SP dtLHS = "*string(dtlhs), 3);
        log_entry("SP dtRHS = "*string(dtrhs), 3);
    end
    if has_surface
        log_entry("SP surfLHS = "*string(surflhs), 3);
        log_entry("SP surfRHS = "*string(surfrhs), 3);
    end
    if has_bdry
        log_entry("SP bdryLHS = "*string(bdrylhs), 3);
        log_entry("SP bdryRHS = "*string(bdryrhs), 3);
    end
    if has_Dbdry
        log_entry("SP dirichletLHS = "*string(dbdrylhs), 3);
        log_entry("SP dirichletRHS = "*string(dbdryrhs), 3);
    end
    if has_Nbdry
        log_entry("SP neumannLHS = "*string(nbdrylhs), 3);
        log_entry("SP neumannRHS = "*string(nbdryrhs), 3);
    end
    
    # Linearize any nonlinear terms and generate derivative functions
    if has_nonlinear
        log_entry("SP NONLINEAR = "*string(nlt), 3);
        # If nlt[i] is a nonlinear Basic expression, replace the unknown symbol (u) with an old one (OLDu)
        # and put it in RHS. Note that OLDu has already been defined automatically.
        # Then generate a function for nlt[i], use AD to generate a derivative of it,
        # create a callback function for the derivative, insert that callback function in
        # the expression multiplied by var on lhs and oldvar on rhs.
        # the test function part must be kept separate for this process.
        if typeof(var) <: Array
            for vi=1:length(var)
                for i=1:length(nlt[vi][1])
                    # println("nlt: "*string(nlt[vi][1][i])*" nlv: "*string(nlv[vi][1][i]))
                    old_nlv = apply_old_to_symbol(nlv[vi][1][i]);
                    old_term = subs(nlt[vi][1][i], (nlv[vi][1][i], old_nlv));
                    deriv_term = create_deriv_func(old_term, old_nlv, finch_state.prob.derivative_type);
                    
                    expanded_deriv_terms = get_sym_terms(deriv_term);
                    
                    # println("old: "*string(old_term))
                    push!(rhs[vi][1], -old_term);
                    for ti=1:length(expanded_deriv_terms)
                        push!(rhs[vi][1], expanded_deriv_terms[ti] * old_nlv);
                        push!(lhs[vi][1], expanded_deriv_terms[ti] * nlv[vi][1][i]);
                    end
                    
                end
            end
        else
            for i=1:length(nlt)
                # println("nlt: "*string(nlt[1][i])*" nlv: "*string(nlv[1][i]))
                old_nlv = apply_old_to_symbol(nlv[1][i]);
                old_term = subs(nlt[1][i], (nlv[1][i], old_nlv));
                deriv_term = create_deriv_func(old_term, old_nlv, finch_state.prob.derivative_type);
                # println("old: "*string(old_term))
                push!(rhs[1], -old_term);
                push!(rhs[1], deriv_term * old_nlv);
                push!(lhs[1], deriv_term * nlv[1][i]);
            end
        end
        
        if has_surface
            log_entry("Linearized: "*string(lhs)*" + surface("*string(surflhs)*") = "*string(rhs)*" + surface("*string(surfrhs)*")");
        else
            log_entry("Linearized: "*string(lhs)*" = "*string(rhs));
        end
        
    end
    
    # If needed, reformat for time stepper
    if timederiv || is_FV
        stepper_type = finch_state.config.stepper;
        if is_FV
            if stepper_type == MIXED_STEPPER && typeof(finch_state.time_stepper) <: Array
                stepper_type = finch_state.time_stepper[2].type;
            end
            log_entry("flux, before modifying for time: "*string(surflhs)*" - "*string(surfrhs));
            (newsurflhs, newsurfrhs) = reformat_for_stepper_fv_flux(stepper_type, surflhs, surfrhs);
            log_entry("flux, modified for time stepping: "*string(newsurflhs)*" + "*string(newsurfrhs));
            log_entry("source, before modifying for time: "*string(lhs)*" - "*string(rhs));
            (newlhs, newrhs) = reformat_for_stepper_fv_source(stepper_type, lhs, rhs,);
            log_entry("source, modified for time stepping: "*string(newlhs)*" + "*string(newrhs));
            
        else # FE
            if stepper_type == MIXED_STEPPER && typeof(finch_state.time_stepper) <: Array
                stepper_type = finch_state.time_stepper[1].type;
            end
            before_modify_stringL = "Weak form, before modifying for time: Dt("*string(dtlhs)*") + "*string(lhs);
            before_modify_stringR = " = "*string(rhs);
            
            if has_surface
                before_modify_stringL *= " + surface("*string(surflhs)*")";
                before_modify_stringR *= " + surface("*string(surfrhs)*")";
                (newlhs, newrhs, newsurflhs, newsurfrhs, newnlt) = reformat_for_stepper(stepper_type, (dtlhs, lhs), rhs, surflhs, surfrhs, nlt);
                after_modify_stringL = "Weak form, modified for time stepping: "*string(newlhs)*" + surface("*string(newsurflhs)*")";
                after_modify_stringR = " = "*string(newrhs)*" + surface("*string(newsurfrhs)*")";
                
            else # no surface
                (newlhs, newrhs, newnlt) = reformat_for_stepper(stepper_type, (dtlhs, lhs), rhs, nothing, nothing, nlt);
                after_modify_stringL = "Weak form, modified for time stepping: "*string(newlhs);
                after_modify_stringR = " = "*string(newrhs);
            end
            
            # boundary integrals are not modified.
            if has_bdry
                before_modify_stringL *= " + boundary("*string(bdrylhs)*")";
                before_modify_stringR *= " + boundary("*string(bdryrhs)*")";
                after_modify_stringL *= " + boundary("*string(bdrylhs)*")";
                after_modify_stringR *= " + boundary("*string(bdryrhs)*")";
            end
            if has_Dbdry
                before_modify_stringL *= " + dirichletBoundary("*string(dbdrylhs)*")";
                before_modify_stringR *= " + dirichletBoundary("*string(dbdryrhs)*")";
                after_modify_stringL *= " + dirichletBoundary("*string(dbdrylhs)*")";
                after_modify_stringR *= " + dirichletBoundary("*string(dbdryrhs)*")";
            end
            if has_Nbdry
                before_modify_stringL *= " + neumannBoundary("*string(nbdrylhs)*")";
                before_modify_stringR *= " + neumannBoundary("*string(nbdryrhs)*")";
                after_modify_stringL *= " + neumannBoundary("*string(nbdrylhs)*")";
                after_modify_stringR *= " + neumannBoundary("*string(nbdryrhs)*")";
            end
            
            # this was all just to print to the log?
            log_entry(before_modify_stringL * before_modify_stringR);
            log_entry(after_modify_stringL * after_modify_stringR);
        end
        
    else # no time stepper
        newlhs = lhs;
        newrhs = rhs;
        newnlt = nlt;
        if has_surface
            newsurflhs = surflhs;
            newsurfrhs = surfrhs;
        end
    end
    
    lhs = newlhs;
    rhs = newrhs;
    if has_surface
        surflhs = newsurflhs;
        surfrhs = newsurfrhs;
    end
    
    # # Linearize any nonlinear terms and generate derivative functions
    # if has_nonlinear
    #     log_entry("SP NONLINEAR = "*string(newnlt), 3);
    #     # If nlt[i] is a nonlinear Basic expression, put it in RHS and change sign.
    #     # Note that u is no longer the unknown being solved for. DELTAu is unknown
    #     # Create a derivative of nlt[i] by:
    #     #  1) generate a function for nlt[i] and use AD to generate a derivative of it,
    #     #     create a callback function for the derivative. insert that callback function in
    #     #     the expression
    #     # OR
    #     #  2) Use SymEngine.diff to make a symbolic derivative
    #     # Then multiply the derivative term by DELTAu and place in LHS.
    #     #
    #     # For all linear LHS terms, make a copy, substitute u->DELTAu in the copy, 
    #     # u terms go to RHS and change sign, DELTAu stay on LHS
    #     # 
    #     # Linear RHS terms change sign
    #     #
    #     # the test function part must be kept separate for this process.
    #     if typeof(var) <: Array
    #         for vi=1:length(var)
    #             for ci=1:length(newlhs[vi])
    #                 # # change sign of all RHS parts
    #                 # for ti=1:length(newrhs[vi][ci])
    #                 #     newrhs[vi][ci][ti] = -newrhs[vi][ci][ti];
    #                 # end
                    
    #                 # copy all linear LHS terms and put in RHS and change sign
    #                 for ti=1:length(newlhs[vi][ci])
    #                     push!(newrhs[vi][ci], -copy(newlhs[vi][ci][ti]));
    #                 end
                    
    #                 # Do this for each NL term
    #                 for i=1:length(newnlt[vi][ci])
    #                     delta_nlv = apply_delta_to_symbol(nlv[vi][ci][i]);
    #                     new_nl_term = copy(newnlt[vi][ci][i]);
    #                     Jdu_term = create_deriv_func(new_nl_term, nlv[vi][ci][i], prob.derivative_type);
    #                     Jdu_term = Jdu_term * delta_nlv;
                        
    #                     expanded_deriv_terms = get_sym_terms(Jdu_term);
                        
    #                     # put nl term in RHS and change sign
    #                     push!(newrhs[vi][ci], -newnlt[vi][ci][i]);
                        
    #                     # for LHS terms, substitute u->DELTAu and leave in LHS
    #                     for ti=1:length(newlhs[vi][ci])
    #                         # newlhs[vi][ci][ti] = subs(newlhs[vi][ci][ti], (nlv[vi][ci][i], delta_nlv));
    #                         newlhs[vi][ci][ti] = apply_delta_to_symbols_in_expression(newlhs[vi][ci][ti], nlv[vi][ci][i]);
    #                     end
                        
    #                     # add the expanded deriv terms to LHS
    #                     append!(newlhs[vi][ci], expanded_deriv_terms);
    #                 end
    #             end
    #         end
    #     else
    #         for ci=1:length(newlhs[vi])
    #             # copy all linear LHS terms and put in RHS
    #             for ti=1:length(newlhs[ci])
    #                 push!(newrhs[ci], copy(newlhs[ci][ti]));
    #             end
                
    #             # Do this for each NL term
    #             for i=1:length(newnlt[ci])
    #                 delta_nlv = apply_delta_to_symbol(nlv[ci][i]);
    #                 new_nl_term = copy(newnlt[ci][i]);
    #                 Jdu_term = create_deriv_func(new_nl_term, nlv[ci][i], prob.derivative_type);
    #                 Jdu_term = Jdu_term * delta_nlv;
                    
    #                 expanded_deriv_terms = get_sym_terms(Jdu_term);
                    
    #                 # put nl term in RHS note that it changes sign twice, so no negative
    #                 push!(newrhs[ci], newnlt[ci][i]);
                    
    #                 # for LHS terms, substitute u->DELTAu and leave in LHS
    #                 # Note that this is not a simple substitution
    #                 # All symbols that contain _u_ need to change to _DELTAu_
    #                 for ti=1:length(newlhs[ci])
    #                     # newlhs[ci][ti] = subs(newlhs[ci][ti], (nlv[ci][i], delta_nlv));
    #                     newlhs[ci][ti] = apply_delta_to_symbols_in_expression(newlhs[ci][ti], nlv[ci][i]);
    #                 end
                    
    #                 # add the expanded deriv terms to LHS
    #                 append!(newlhs[ci], expanded_deriv_terms);
    #             end
    #         end
    #     end
        
    #     if has_surface
    #         log_entry("Linearized: "*string(newlhs)*" + surface("*string(newsurflhs)*") = "*string(newrhs)*" + surface("*string(newsurfrhs)*")");
    #     else
    #         log_entry("Linearized: "*string(newlhs)*" = "*string(newrhs));
    #     end
    # end
    
    # Parse Basic->Expr and insert placeholders
    lhs = basic_to_expr_and_place(lhs, placeholders)
    rhs = basic_to_expr_and_place(rhs, placeholders)
    surflhs = basic_to_expr_and_place(surflhs, placeholders)
    surfrhs = basic_to_expr_and_place(surfrhs, placeholders)
    bdrylhs = basic_to_expr_and_place(bdrylhs, placeholders)
    bdryrhs = basic_to_expr_and_place(bdryrhs, placeholders)
    dbdrylhs = basic_to_expr_and_place(dbdrylhs, placeholders)
    dbdryrhs = basic_to_expr_and_place(dbdryrhs, placeholders)
    nbdrylhs = basic_to_expr_and_place(nbdrylhs, placeholders)
    nbdryrhs = basic_to_expr_and_place(nbdryrhs, placeholders)
    
    resultExpressions = build_symexpressions(var, [lhs, rhs, surflhs, surfrhs, bdrylhs, bdryrhs, dbdrylhs, dbdryrhs, nbdrylhs, nbdryrhs], remove_zeros=true);
    
    return resultExpressions;
end

# Replaces parameter symbols with their values
function insert_parameters(ex)
    if typeof(ex) == Symbol
        # parameter?
        for p in finch_state.parameters
            if ex === p.symbol
                if p.type == SCALAR
                    return insert_parameters(p.value[1]);
                else
                    return insert_parameters(p.value);
                end
            end
        end
        # nope
        return ex;
        
    elseif typeof(ex) == Expr && length(ex.args) > 0
        for i=1:length(ex.args)
            ex.args[i] = insert_parameters(ex.args[i]); # recursively replace on args if ex
        end
        return ex;
    elseif typeof(ex) <:Array
        result = copy(ex);
        for i=1:length(ex)
            result[i] = insert_parameters(ex[i]);
        end
        return result;
    else
        return ex;
    end
end

# Replaces variable, coefficient and operator symbols in the expression
function replace_symbols(ex)
    if typeof(ex) <: Number
        return Basic(ex);
    elseif typeof(ex) == Symbol
        # variable?
        for v in finch_state.variables
            if ex === v.symbol
                return v.symvar;
            end
        end
        # coefficient?
        for c in finch_state.coefficients
            if ex === c.symbol
                # constant coefficients are entered as numbers
                if c.type == SCALAR && typeof(c.value[1]) <: Number
                    return [Basic(c.value[1])];
                end
                return c.symvar;
            end
        end
        # operator?
        for i=1:length(finch_state.ops)
            if ex === finch_state.ops[i].symbol
                #return Symbol(string(ops[i].op));
                return :(finch_state.ops[$i].op);
            end
        end
        # test function?
        for c in finch_state.test_functions
            if ex === c.symbol
                return c.symvar;
            end
        end
        # callback functions
        for c in finch_state.callback_functions
            if string(ex) == c.name
                # Make a special SymEngine function for this and process it later
                cname = Symbol("CALLBACK_" * c.name);
                cstr = string(cname);
                glop = Expr(:global, Expr(:(=), cname, Expr(:call, :(SymEngine.SymFunction), cstr)));
                eval(glop);
                return cname;
            end
        end
        # none of them? just return as is
        return ex;
    elseif typeof(ex) == Expr && length(ex.args) > 0
        for i=1:length(ex.args)
            ex.args[i] = replace_symbols(ex.args[i]); # recursively replace on args if ex
        end
        
        return ex;
    elseif typeof(ex) <:Array
        result = copy(ex);
        for i=1:length(ex)
            if typeof(ex[i]) == SymEngine.Basic
                result[i] = replace_symbols(ex[i])[1];
            else
                result[i] = replace_symbols(ex[i]);
            end
            
        end
        return result;
    else
        return ex;
    end
end

# Turns u[i] into u_INDEXEDBYi
function handle_indexers(ex)
    # Traverse the Expr looking for ref heads
    if typeof(ex) <:Array
        result = copy(ex);
        for i=1:length(ex)
            result[i] = handle_indexers(ex[i]);
        end
        return result;
        
    elseif typeof(ex) == Expr
        if ex.head === :ref
            needs_indexing = false;
            for i=2:length(ex.args)
                if !(typeof(ex.args[i]) <: Number)
                    needs_indexing = true;
                end
            end
            if needs_indexing
                
                var = ex.args[1];
                if typeof(var) <: Array && length(var) == 1 && occursin("INDEXED", string(var[1]))
                    newname = string(var[1]);
                    for i=2:length(ex.args)
                        newname *= "BY"*string(ex.args[i]);
                    end
                    return [symbols(newname)];
                else
                    printerr("Expected an array type variable when indexing: "*string(ex));
                end
                
                
                # newex = Expr(:call, :indexing_operator, ex.args[1]);
                # # the index symbols need to be turned into symengine things
                # for i=2:length(ex.args)
                #     if typeof(ex.args[i]) == Symbol
                #         ex.args[i] = symbols(string(ex.args[i]))
                #     end
                # end
                # append!(newex.args, ex.args[2:end]);
                # return newex;
            end
            
        else
            for i=1:length(ex.args)
                ex.args[i] = handle_indexers(ex.args[i]);
            end
        end
    end
    
    return ex;
end

# Turns callbackfun([a],[b],2) into PLACEHOLDER_i, processes the arguments ([a],[b],2), and stores in placeholders[i]
function handle_callbacks(ex, placeholders)
    # Traverse the Expr looking for :call with "CALLBACK_"
    if typeof(ex) <:Array
        result = copy(ex);
        for i=1:length(ex)
            result[i] = handle_callbacks(ex[i], placeholders);
        end
        return result;
        
    elseif typeof(ex) == Expr
        if ex.head === :call && occursin("CALLBACK_", string(ex.args[1]))
            
            # build a placeholder var
            pind = length(placeholders)+1;
            phvar = symbols("PLACEHOLDER_"*string(pind));
            # process the arguments
            for i=2:length(ex.args)
                ex.args[i] = apply_ops(ex.args[i]);
            end
            # build a callbackplaceholder struct
            push!(placeholders, CallbackPlaceholder(string(ex.args[1]), ex.args[2:end]))
            
            #swap in the phvar
            ex = phvar;
        else
            for i=1:length(ex.args)
                ex.args[i] = handle_callbacks(ex.args[i], placeholders);
            end
        end
    end
    
    return ex;
    
end

function broadcast_ops(ex)
    if typeof(ex) <:Array
        result = copy(ex);
        for i=1:length(ex)
            result[i] = broadcast_ops(ex[i]);
        end
        return result;
    elseif typeof(ex) == Expr
        for i=1:length(ex.args)
            ex.args[i] = broadcast_ops(ex.args[i]);
        end
        return ex;
    elseif typeof(ex) == Symbol
        # replace ^,/,+,- with .^,./,.+,.-
        if ex === :^ ex = :.^
        elseif ex === :/ ex = :./
        elseif ex === :* ex = :.*
        #elseif ex === :+ ex = :.+
        #elseif ex === :- ex = :.-
        end
    end
    return ex;
end

# Eval to apply the sym_*_op ops to create a SymEngine expression
function apply_ops(ex)
    if typeof(ex) <:Array
        result = [];
        for i=1:length(ex)
            push!(result, eval(ex[i]));
        end
        return result;
    else
        return eval(ex);
    end
end

# Determine if this expression has an unknown variable symbol
function has_unknown(ex, var)
    str = string(ex);
    result = false;
    if typeof(var) <: Array
        for i=1:length(var)
            varsymbol = "_"*string(var[i])*"_";
            if occursin(varsymbol, str)
                result = true;
            end
        end
    else
        varsymbol = "_"*string(var)*"_";
        result = occursin(varsymbol, str);
    end
    
    return result;
end

# Determine if a Basic is nonlinear in an unknown
# For now assume single unknowns
# return nothing if no nonlinearity detected
# otherwise return the symbol containing the nonlinear variable
# Note: conditionals will look nonlinear, so check both branches separately.
function check_for_nonlinear(ex, var)
    result = nothing;
    if typeof(ex) == Basic
        # Extract a list of all symbols from ex
        allsymbols = SymEngine.free_symbols(ex);
        divided_ex = copy(ex);
        
        # for now, assume only one unknown variable is present
        # Figure out which one
        if typeof(var) <: Array
            present_var = var[1];
            for i=1:length(var)
                if has_unknown(ex, var[i]) # this one is present
                    tmp = present_var; # just to bring in scope
                    present_var = var[i];
                end
            end
        else
            present_var = var;
        end
        
        # Look for certain functions like conditional()
        allfuns = SymEngine.function_symbols(ex);
        # println(" allfuns: " * string(allfuns))
        for f in allfuns
            f_name = SymEngine.get_name(f);
            # println("  name: "*string(f_name))
            if f_name == "conditional"
                # check each of the args for nonlinearity
                f_args = SymEngine.get_args(f);
                # println("  args: "*string(f_args))
                for fa in f_args
                    nl = check_for_nonlinear(fa, var);
                    if !(nl===nothing)
                        return nl;
                    end
                end
                # At this point the args were not nonlinear
                # divide out the function to prevent problems
                divided_ex = divided_ex / f;
            end
        end
        # update allsymbols with removed conditionals
        allsymbols = SymEngine.free_symbols(divided_ex);
        
        # Find the corresponding symbol in the list
        for s in allsymbols
            if has_unknown(s, present_var)
                # Try dividing ex by the symbol and see if it still remains
                divided_ex = divided_ex / s;
                if has_unknown(divided_ex, present_var)
                    result = s;
                    # println(" NL: "*string(divided_ex))
                end
                break;
            end
        end
        
        
    end
    
    return result;
end

# Separate terms for each variable ex.
function get_sym_terms(ex)
    # Recursively work on each term of the array
    if typeof(ex) <: Array
        result = [get_sym_terms(ex[1])];
        for i=2:length(ex)
            push!(result,  get_sym_terms(ex[i]));
        end
        
        return result;
    end
    
    # ex is a symbolic expression(not array of them)
    # if ex is just a number, turn it into a Basic for expand
    if typeof(ex) <: Number
       ex = Basic(ex); 
    end
    # First expand it
    newex = expand(ex);
    log_entry("expanded: "*string(newex), 3);
    
    # Then separate the terms into an array
    return get_all_terms(newex);
end

function get_all_terms(ex)
    if typeof(ex) == Basic
        # convert to Expr, separate, convert to Basic
        expr = Meta.parse(string(ex));
        log_entry("Basic->Expr: "*string(expr), 3);
        
        terms = get_all_terms(expr);
        #println("Exprterms = "*string(terms));
        bterms = Array{Basic,1}(undef,0);
        for i=1:length(terms)
            if !(terms[i] == 0)
                push!(bterms, Basic(terms[i]));
            end
        end
        return bterms;
    end
    
    # At this point ex must be an Expr or symbol or number
    terms = [];
    if !(typeof(ex) == Expr)
        push!(terms, ex);
        return terms;
    end
    if ex.head === :call
        if ex.args[1] === :+ || ex.args[1] === :.+
            for i=2:length(ex.args)
                terms = append!(terms, get_all_terms(ex.args[i]));
            end
        elseif ex.args[1] === :-
            # apply -() to minused terms
            # Remember that the result of this will only be added terms, no minuses
            terms = get_all_terms(ex.args[2]);
            if length(ex.args) < 3
                for j=1:length(terms)
                    terms[j] = apply_negative(terms[j]);
                end
            else
                for i=3:length(ex.args)
                    tmp = get_all_terms(ex.args[i]);
                    for j=1:length(tmp)
                        tmp[j] = apply_negative(tmp[j]);
                    end
                    append!(terms, tmp);
                end
            end
        else
            push!(terms, ex);
        end
    else
        push!(terms, ex);
    end
    return terms;
end

function check_for_symbol(terms, symb)
    result = false;
    if typeof(terms) <: Array
        for i=1:length(terms)
            result = result || check_for_symbol(terms[i], symb);
        end
    else
        result = occursin(string(symb), string(terms));
    end
    return result;
end

# function split_left_right(sterms,sz,var)
#     lhs = copy(sterms); # set up the container right
#     rhs = copy(sterms);
#     if length(sz) == 0 # probably just a number
#         rhs = sterms;
#         lhs = [];
#     elseif length(sz) == 1 # vector or scalar
#         for i=1:sz[1]
#             lhs[i] = Array{Basic,1}(undef,0);
#             rhs[i] = Array{Basic,1}(undef,0);
#             for ti=1:length(sterms[i])
#                 if has_unknown(sterms[i][ti], var)
#                     #println("lhs: "*string(sterms[i][ti]));
#                     push!(lhs[i], sterms[i][ti]);
#                 else
#                     #println("rhs: "*string(sterms[i][ti]));
#                     # switch sign to put on RHS
#                     push!(rhs[i], -sterms[i][ti]);
#                 end
#             end
#         end
#     elseif length(sz) == 2 # matrix
#         for j=1:sz[2]
#             for i=1:sz[1]
#                 lhs[i,j] = Basic(0);
#                 rhs[i,j] = Basic(0);
#                 for ti=1:length(sterms[i,j])
#                     if has_unknown(sterms[i,j][ti], var)
#                         #println("lhs: "*string(sterms[i,j][ti]));
#                         push!(lhs[i,j], sterms[i,j][ti]);
#                     else
#                         #println("rhs: "*string(sterms[i,j][ti]));
#                         push!(rhs[i,j], -sterms[i,j][ti]);
#                     end
#                 end
#             end
#         end
#     elseif length(sz) == 3 # rank 3
#         for k=1:sz[3]
#             for j=1:sz[2]
#                 for i=1:sz[1]
#                     lhs[i,j,k] = Basic(0);
#                     rhs[i,j,k] = Basic(0);
#                     for ti=1:length(sterms[i,j,k])
#                         if has_unknown(sterms[i,j,k][ti], var)
#                             #println("lhs: "*string(sterms[i,j,k][ti]));
#                             push!(lhs[i,j,k], sterms[i,j,k][ti]);
#                         else
#                             #println("rhs: "*string(sterms[i,j,k][ti]));
#                             push!(rhs[i,j,k], -sterms[i,j,k][ti]);
#                         end
#                     end
#                 end
#             end
#         end
#     end
#     return (lhs,rhs);
# end

function split_left_right_nonlinear(sterms,sz,var)
    lhs = copy(sterms); # set up the container right
    rhs = copy(sterms);
    nl = copy(sterms);
    nlv = copy(sterms);
    if length(sz) == 0 # probably just a number
        rhs = sterms;
        lhs = [];
        nl = [];
        nlv = [];
    elseif length(sz) == 1 # vector or scalar
        for i=1:sz[1]
            lhs[i] = Array{Basic,1}(undef,0);
            rhs[i] = Array{Basic,1}(undef,0);
            nl[i] = Array{Basic,1}(undef,0);
            nlv[i] = Array{Basic,1}(undef,0);
            for ti=1:length(sterms[i])
                if has_unknown(sterms[i][ti], var)
                    nl_var = check_for_nonlinear(sterms[i][ti], var);
                    if !(nl_var === nothing)
                        push!(nl[i], sterms[i][ti]);
                        push!(nlv[i], nl_var);
                    else
                        push!(lhs[i], sterms[i][ti]);
                    end
                else
                    # switch sign to put on RHS
                    push!(rhs[i], -sterms[i][ti]);
                end
            end
        end
    elseif length(sz) == 2 # matrix
        for j=1:sz[2]
            for i=1:sz[1]
                lhs[i,j] = Array{Basic,1}(undef,0);
                rhs[i,j] = Array{Basic,1}(undef,0);
                nl[i,j] = Array{Basic,1}(undef,0);
                nlv[i,j] = Array{Basic,1}(undef,0);
                for ti=1:length(sterms[i,j])
                    if has_unknown(sterms[i,j][ti], var)
                        nl_var = check_for_nonlinear(sterms[i,j][ti], var);
                        if !(nl_var === nothing)
                            push!(nl[i,j], sterms[i,j][ti]);
                            push!(nli[i,j], nl_var);
                        else
                            push!(lhs[i,j], sterms[i,j][ti]);
                        end
                    else
                        #println("rhs: "*string(sterms[i,j][ti]));
                        push!(rhs[i,j], -sterms[i,j][ti]);
                    end
                end
            end
        end
    elseif length(sz) == 3 # rank 3
        for k=1:sz[3]
            for j=1:sz[2]
                for i=1:sz[1]
                    lhs[i,j,k] = Array{Basic,1}(undef,0);
                    rhs[i,j,k] = Array{Basic,1}(undef,0);
                    nl[i,j,k] = Array{Basic,1}(undef,0);
                    nli[i,j,k] = Array{Basic,1}(undef,0);
                    for ti=1:length(sterms[i,j,k])
                        if has_unknown(sterms[i,j,k][ti], var)
                            nl_var = check_for_nonlinear(sterms[i,j,k][ti], var);
                            if !(nl_var === nothing)
                                push!(nl[i,j,k], sterms[i,j,k][ti]);
                                push!(nli[i,j,k], nl_var);
                            else
                                push!(lhs[i,j,k], sterms[i,j,k][ti]);
                            end
                        else
                            #println("rhs: "*string(sterms[i,j,k][ti]));
                            push!(rhs[i,j,k], -sterms[i,j,k][ti]);
                        end
                    end
                end
            end
        end
    end
    return (lhs, rhs, nl, nlv);
end

function split_on_symbol(sym, terms, sz)
    hassymbol = copy(terms); # set up the container right
    nosymbol = copy(terms);
    specialSymbol = symbols(sym); # will be removed from terms
    if length(sz) == 1 # vector or scalar
        for i=1:sz[1]
            hassymbol[i] = Array{Basic,1}(undef,0);
            nosymbol[i] = Array{Basic,1}(undef,0);
            for ti=1:length(terms[i])
                if check_for_symbol(terms[i][ti], sym)
                    terms[i][ti] = subs(terms[i][ti], specialSymbol=>1);
                    push!(hassymbol[i], terms[i][ti]);
                else
                    push!(nosymbol[i], terms[i][ti]);
                end
            end
        end
    elseif length(sz) == 2 # matrix
        for j=1:sz[2]
            for i=1:sz[1]
                hassymbol[i,j] = Array{Basic,1}(undef,0);
                nosymbol[i,j] = Array{Basic,1}(undef,0);
                for ti=1:length(terms[i,j])
                    if check_for_symbol(terms[i,j][ti], sym)
                        terms[i,j][ti] = subs(terms[i,j][ti], specialSymbol=>1);
                        push!(hassymbol[i,j], terms[i,j][ti]);
                    else
                        push!(nosymbol[i,j], terms[i,j][ti]);
                    end
                end
            end
        end
    elseif length(sz) == 3 # rank 3
        for k=1:sz[3]
            for j=1:sz[2]
                for i=1:sz[1]
                    hassymbol[i,j,k] = Array{Basic,1}(undef,0);
                    nosymbol[i,j,k] = Array{Basic,1}(undef,0);
                    for ti=1:length(terms[i,j,k])
                        if check_for_symbol(terms[i,j,k][ti], sym)
                            terms[i,j,k][ti] = subs(terms[i,j,k][ti], specialSymbol=>1);
                            push!(hassymbol[i,j,k], terms[i,j,k][ti]);
                        else
                            push!(nosymbol[i,j,k], terms[i,j,k][ti]);
                        end
                    end
                end
            end
        end
    end
    
    return (hassymbol, nosymbol);
end

# Parse Basic into Expr and insert placeholders
# This works recursively so each piece in the array is parsed, then the Expr is traversed to swap placeholders.
function basic_to_expr_and_place(ex, placeholders)
    if typeof(ex) <: Array
        exarray = [];
        for i=1:length(ex)
            push!(exarray, basic_to_expr_and_place(ex[i], placeholders));
        end
        return exarray;
        
    elseif typeof(ex) <: SymEngine.Basic
        # ex is a SymEngine.Basic object
        # First parse it into an Expr
        jex = Meta.parse(string(ex));
        # Then process it
        newex = basic_to_expr_and_place(jex, placeholders);
        
        return newex;
        
    elseif typeof(ex) == Expr
        # There are certain functions that need to apply flags to variables
        # such as twoPrevious(_u_1...) -> PREV2__u_1...
        if ex.head === :call && ex.args[1] === :twoPrevious
            ex = apply_flag_to_variables("PREV2_", ex.args[2]);
        end
        
        for i=1:length(ex.args)
            ex.args[i] = basic_to_expr_and_place(ex.args[i], placeholders)
        end
        return ex;
        
    elseif typeof(ex) == Symbol
        # Here's where the replacement happens
        str = string(ex);
        if occursin("PLACEHOLDER_", str)
            phind = parse(Int, str[13:end]);
            ex = Meta.parse(to_string(placeholders[phind]));
            
            if typeof(ex) == Expr
                for i=1:length(ex.args)
                    ex.args[i] = basic_to_expr_and_place(ex.args[i], placeholders)
                end
            end
        end
        
        return ex;
        
    else # could be a number or string or something or nothing
        return ex;
    end
end

end # module