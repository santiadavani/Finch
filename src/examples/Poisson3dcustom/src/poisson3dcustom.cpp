//This file was generated by Finch.

/*

*/
#include "TreeNode.h"
#include "mpi.h"
#include "genPts_par.h"
#include "sfcSort.h"
#include "mesh.h"
#include "dendro.h"
#include "dendroIO.h"
#include "octUtils.h"
#include "functional"
#include "fdCoefficient.h"
#include "stencil.h"
#include "rkTransport.h"
#include "refel.h"
#include "operators.h"
#include "cg.h"

#include "linear_skel.h"
#include "bilinear_skel.h"

int main (int argc, char** argv)
{

    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;

    int rank, npes;
    MPI_Comm_rank(comm, &rank);
    MPI_Comm_size(comm, &npes);
    
    m_uiMaxDepth = 4; // a default value, but should be set in config.cpp
    
    //////////////will be generated/////////////////////////////////////////////
    #include "Config.cpp"
    ////////////////////////////////////////////////////////////////////////////
    
    Point domain_min(0,0,0);
    Point domain_max(1,1,1);
    
    Point grid_min(0, 0, 0);
    Point grid_max((1u << m_uiMaxDepth), (1u << m_uiMaxDepth), (1u << m_uiMaxDepth));
    
    double Rg_x=(grid_max.x()-grid_min.x());
    double Rg_y=(grid_max.y()-grid_min.y());
    double Rg_z=(grid_max.z()-grid_min.z());

    double Rd_x=(domain_max.x()-domain_min.x());
    double Rd_y=(domain_max.y()-domain_min.y());
    double Rd_z=(domain_max.z()-domain_min.z());

    const Point d_min=domain_min;
    const Point d_max=domain_max;

    const Point g_min=grid_min;
    const Point g_max=grid_max;
    
    std::function<double(double)> gridX_to_X = [d_min,g_min,Rd_x,Rg_x](const double x){
        return d_min.x() + (x-g_min.x())*Rd_x/Rg_x;
    };
    
    std::function<double(double)> gridY_to_Y = [d_min,g_min,Rd_y,Rg_y](const double y){
        return d_min.y() + (y-g_min.y())*Rd_y/Rg_y;
    };
    
    std::function<double(double)> gridZ_to_Z = [d_min,g_min,Rd_z,Rg_z](const double z){
        return d_min.z() + (z-g_min.z())*Rd_z/Rg_z;
    };
    
    std::function<void(double,double,double,double*)> zero_init = [](const double x,const double y,const double z,double *var){
        var[0]=0;
    };
    
    //////////////will be generated/////////////////////////////////////////////
    #include "Genfunction.cpp"
    #include "Problem.cpp"
    /////////////////////////////////////////////////////////////////////////////
    
    // Uncomment to display various parameters
    if (!rank) {
    //     std::cout << YLW << "maxDepth: " << m_uiMaxDepth << NRM << std::endl;
    //     std::cout << YLW << "wavelet_tol: " << wavelet_tol << NRM << std::endl;
    //     std::cout << YLW << "partition_tol: " << partition_tol << NRM << std::endl;
    //     std::cout << YLW << "eleOrder: " << eOrder << NRM << std::endl;
    }

    _InitializeHcurve(m_uiDim);
    RefElement refEl(m_uiDim,eOrder);
    
    // This is the tricky part. Octree generation could be based on a function or other variable. This will need to be generated.
    // But for now just use this
    ot::DA* octDA=new ot::DA(genfunction_0,1,comm,eOrder,wavelet_tol,100,partition_tol,ot::FEM_CG);

// Variable info will also be generated, but for now assume a single scalar variable
std::vector<double> uSolVec;
octDA->createVector(uSolVec,false,false,DOF);
double *uSolVecPtr=&(*(uSolVec.begin()));

FinchDendroSkeleton::LHSMat lhsMat(octDA,1);
lhsMat.setProblemDimensions(domain_min,domain_max);
lhsMat.setGlobalDofVec(uSolVecPtr);

FinchDendroSkeleton::RHSVec rhsVec(octDA,1);
rhsVec.setProblemDimensions(domain_min,domain_max);
rhsVec.setGlobalDofVec(uSolVecPtr);

// This assumes some things
lhsMat.setBdryFunction({0});
rhsVec.setBdryFunction({0});

// Allocate dofs
double * _u_1=octDA->getVecPointerToDof(uSolVecPtr,VAR::M_UI_u_1, false,false);
double * _f_1=octDA->getVecPointerToDof(uSolVecPtr,VAR::M_UI_f_1, false,false);
double * rhs=octDA->getVecPointerToDof(uSolVecPtr,VAR::M_UI_RHS, false,false); // linear part

// Init dofs
octDA->setVectorByFunction(_u_1,zero_init,false,false,1);
octDA->setVectorByFunction(_f_1,genfunction_0,false,false,1);
octDA->setVectorByFunction(rhs,zero_init,false,false,1); // zeros

// Solve
// This uses the generated RHS code to compute the RHS vector.
        rhsVec.computeVec(_u_1,rhs,1.0);
        
        // Solve the linear system. 
        lhsMat.cgSolve(_u_1,rhs,solve_max_iters,solve_tol,0);    
    // Output
    //////////////will be generated/////////////////////////////////////////////
    #include "Output.cpp"
    ////////////////////////////////////////////////////////////////////////////
    
    octDA->destroyVector(uSolVec);

    if(!rank)
        std::cout<<" End of computation. "<<std::endl;

    delete octDA;

    MPI_Finalize();
    return 0;
}
