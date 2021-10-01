//This file was generated by Finch.

/*
Configuration info
*/
m_uiMaxDepth = 6;           // mesh refinement depth
double wavelet_tol = 0.1;     // tolerance for approximating functions(f) determines mesh fineness
double partition_tol = 0.3; // load balancing parameter
double solve_tol = 1.0e-6;            // tol used by cgsolve for stopping iterations
unsigned int solve_max_iters = 100; // used by cgsolve
unsigned int eOrder  = 2;
int config_dimension = 3;
const char* config_solver = "CG";
const char* config_trial_function = "Legendre";
const char* config_test_function = "Legendre";
const char* config_elemental_nodes = "Lobatto";
const char* config_quadrature= "Gauss";
