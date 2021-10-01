%This file was generated by Finch.

%{
Configuration info
%}
config.dimension = 2;
config.geometry = 'square';
config.mesh_type = 'unstructured';
config.solver_type = 'CG';
config.trial_function = 'Legendre';
config.test_function = 'Legendre';
config.elemental_nodes = 'Lobatto';
config.quadrature = 'Gauss';
config.p_adaptive = false;
config.basis_order_min = 2;
config.basis_order_max = 2;
config.linear = true;
config.t_adaptive = false;
config.stepper = 'Euler-implicit';
config.linalg_matrixfree = false;
config.linalg_matfree_max = 1;
config.linalg_matfree_tol = 1.0;
config.linalg_backend = 'Default solver';
config.output_format = 'vtk';
order = config.basis_order_min;
