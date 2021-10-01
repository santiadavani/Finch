%This file was generated by Finch.

%{
Linear term
%}

dof = size(grid_data.allnodes,2);
ne  = mesh_data.nel;
Np = refel.Np;
RHS = zeros(dof,1);

% loop over elements
for e=1:ne
    idx = grid_data.loc2glb(:,e)';
    pts = grid_data.allnodes(:,idx);
    [detJ, Jac]  = Utils.geometric_factors(refel, pts);
    
coef_0_1 = genfunction_1(idx);

elVec = refel.Q' * diag(refel.wg .* detJ) * (refel.Q * coef_0_1);


    RHS(idx) = elVec;
end


for i=1:length(grid_data.bdry)
    RHS(grid_data.bdry{i}) = prob.bc_func(grid_data.bdry{i});
end
