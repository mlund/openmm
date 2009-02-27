/* -------------------------------------------------------------------------- *
 *                                   OpenMM                                   *
 * -------------------------------------------------------------------------- *
 * This is part of the OpenMM molecular simulation toolkit originating from   *
 * Simbios, the NIH National Center for Physics-Based Simulation of           *
 * Biological Structures at Stanford, funded under the NIH Roadmap for        *
 * Medical Research, grant U54 GM072970. See https://simtk.org.               *
 *                                                                            *
 * Portions copyright (c) 2009 Stanford University and the Authors.           *
 * Authors: Scott Le Grand, Peter Eastman                                     *
 * Contributors:                                                              *
 *                                                                            *
 * Permission is hereby granted, free of charge, to any person obtaining a    *
 * copy of this software and associated documentation files (the "Software"), *
 * to deal in the Software without restriction, including without limitation  *
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,   *
 * and/or sell copies of the Software, and to permit persons to whom the      *
 * Software is furnished to do so, subject to the following conditions:       *
 *                                                                            *
 * The above copyright notice and this permission notice shall be included in *
 * all copies or substantial portions of the Software.                        *
 *                                                                            *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR *
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,   *
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL    *
 * THE AUTHORS, CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,    *
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR      *
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE  *
 * USE OR OTHER DEALINGS IN THE SOFTWARE.                                     *
 * -------------------------------------------------------------------------- */

#include <stdio.h>
#include <cuda.h>
#include <vector_functions.h>
#include <cstdlib>
#include <string>
#include <iostream>
//#include <fstream>
using namespace std;

#define DeltaShake

#include "gputypes.h"


static __constant__ cudaGmxSimulation cSim;

void SetSettleSim(gpuContext gpu)
{
    cudaError_t status;
    status = cudaMemcpyToSymbol(cSim, &gpu->sim, sizeof(cudaGmxSimulation));
    RTERROR(status, "cudaMemcpyToSymbol: SetSim copy to cSim failed");
}

void GetSettleSim(gpuContext gpu)
{
    cudaError_t status;
    status = cudaMemcpyFromSymbol(&gpu->sim, cSim, sizeof(cudaGmxSimulation));
    RTERROR(status, "cudaMemcpyFromSymbol: SetSim copy from cSim failed");
}

/**
 * This is based on the setlep FORTRAN routine by Shuichi Miyamoto.  See
 * S. Miyamoto and P. Kollman, J. Comp. Chem., vol 13, no. 8, pp. 952-962 (1992).
 */

__global__ void kApplyFirstSettle_kernel()
{
    unsigned int pos = threadIdx.x + blockIdx.x * blockDim.x;
    while (pos < cSim.settleConstraints)
    {
        int4 atomID         = cSim.pSettleID[pos];
        float2 params       = cSim.pSettleParameter[pos];
        float4 apos0        = cSim.pOldPosq[atomID.x];
        float4 xp0          = cSim.pPosqP[atomID.x];
        float4 apos1        = cSim.pOldPosq[atomID.y];
        float4 xp1          = cSim.pPosqP[atomID.y];
        float4 apos2        = cSim.pOldPosq[atomID.z];
        float4 xp2          = cSim.pPosqP[atomID.z];
        float m0            = 1.0/cSim.pVelm4[atomID.x].w;
        float m1            = 1.0/cSim.pVelm4[atomID.y].w;
        float m2            = 1.0/cSim.pVelm4[atomID.z].w;


        float xb0 = apos1.x-apos0.x;
        float yb0 = apos1.y-apos0.y;
        float zb0 = apos1.z-apos0.z;
        float xc0 = apos2.x-apos0.x;
        float yc0 = apos2.y-apos0.y;
        float zc0 = apos2.z-apos0.z;
        float dist1 = sqrt(xb0*xb0 + yb0*yb0 + zb0*zb0);
        float dist2 = sqrt(xc0*xc0 + yc0*yc0 + zc0*zc0);

        float totalMass = m0+m1+m2;
        float xcom = ((apos0.x+xp0.x)*m0 + (apos1.x+xp1.x)*m1 + (apos2.x+xp2.x)*m2) / totalMass;
        float ycom = ((apos0.y+xp0.y)*m0 + (apos1.y+xp1.y)*m1 + (apos2.y+xp2.y)*m2) / totalMass;
        float zcom = ((apos0.z+xp0.z)*m0 + (apos1.z+xp1.z)*m1 + (apos2.z+xp2.z)*m2) / totalMass;

        float xa1 = apos0.x + xp0.x - xcom;
        float ya1 = apos0.y + xp0.y - ycom;
        float za1 = apos0.z + xp0.z - zcom;
        float xb1 = apos1.x + xp1.x - xcom;
        float yb1 = apos1.y + xp1.y - ycom;
        float zb1 = apos1.z + xp1.z - zcom;
        float xc1 = apos2.x + xp2.x - xcom;
        float yc1 = apos2.y + xp2.y - ycom;
        float zc1 = apos2.z + xp2.z - zcom;

        float xaksZd = yb0*zc0 - zb0*yc0;
        float yaksZd = zb0*xc0 - xb0*zc0;
        float zaksZd = xb0*yc0 - yb0*xc0;
        float xaksXd = ya1*zaksZd - za1*yaksZd;
        float yaksXd = za1*xaksZd - xa1*zaksZd;
        float zaksXd = xa1*yaksZd - ya1*xaksZd;
        float xaksYd = yaksZd*zaksXd - zaksZd*yaksXd;
        float yaksYd = zaksZd*xaksXd - xaksZd*zaksXd;
        float zaksYd = xaksZd*yaksXd - yaksZd*xaksXd;

        float axlng = sqrt(xaksXd * xaksXd + yaksXd * yaksXd + zaksXd * zaksXd);
        float aylng = sqrt(xaksYd * xaksYd + yaksYd * yaksYd + zaksYd * zaksYd);
        float azlng = sqrt(xaksZd * xaksZd + yaksZd * yaksZd + zaksZd * zaksZd);
        float trns11 = xaksXd / axlng;
        float trns21 = yaksXd / axlng;
        float trns31 = zaksXd / axlng;
        float trns12 = xaksYd / aylng;
        float trns22 = yaksYd / aylng;
        float trns32 = zaksYd / aylng;
        float trns13 = xaksZd / azlng;
        float trns23 = yaksZd / azlng;
        float trns33 = zaksZd / azlng;

        float xb0d = trns11*xb0 + trns21*yb0 + trns31*zb0;
        float yb0d = trns12*xb0 + trns22*yb0 + trns32*zb0;
        float xc0d = trns11*xc0 + trns21*yc0 + trns31*zc0;
        float yc0d = trns12*xc0 + trns22*yc0 + trns32*zc0;
//        float xa1d = trns11*xa1 + trns21*ya1 + trns31*za1;
//        float ya1d = trns12*xa1 + trns22*ya1 + trns32*za1;
        float za1d = trns13*xa1 + trns23*ya1 + trns33*za1;
        float  xb1d = trns11*xb1 + trns21*yb1 + trns31*zb1;
        float  yb1d = trns12*xb1 + trns22*yb1 + trns32*zb1;
        float  zb1d = trns13*xb1 + trns23*yb1 + trns33*zb1;
        float  xc1d = trns11*xc1 + trns21*yc1 + trns31*zc1;
        float  yc1d = trns12*xc1 + trns22*yc1 + trns32*zc1;
        float  zc1d = trns13*xc1 + trns23*yc1 + trns33*zc1;

        //                                        --- Step2  A2' ---

        float rc = 0.5*params.y;
        float rb = sqrt(params.x*params.x-rc*rc);
        float ra = rb*(m1+m2)/totalMass;
        rb -= ra;
        float sinphi = za1d / ra;
        float cosphi = sqrt(1.0 - sinphi*sinphi);
        float sinpsi = ( zb1d - zc1d ) / (2*rc*cosphi);
        float cospsi = sqrt(1.0 - sinpsi*sinpsi);

        float ya2d =   ra * cosphi;
        float xb2d = - rc * cospsi;
        float yb2d = - rb * cosphi - rc *sinpsi * sinphi;
        float yc2d = - rb * cosphi + rc *sinpsi * sinphi;
        float xb2d2 = xb2d * xb2d;
        float hh2 = 4.0 * xb2d2 + (yb2d-yc2d) * (yb2d-yc2d) + (zb1d-zc1d) * (zb1d-zc1d);
        float deltx = 2.0 * xb2d + sqrt ( 4.0 * xb2d2 - hh2 + params.y*params.y );
        xb2d -= deltx * 0.5;

        //                                        --- Step3  al,be,ga ---

        float alpa = ( xb2d * (xb0d-xc0d) + yb0d * yb2d + yc0d * yc2d );
        float beta = ( xb2d * (yc0d-yb0d) + xb0d * yb2d + xc0d * yc2d );
        float gama = xb0d * yb1d - xb1d * yb0d + xc0d * yc1d - xc1d * yc0d;

        float al2be2 = alpa * alpa + beta * beta;
        float sinthe = ( alpa*gama - beta * sqrt ( al2be2 - gama * gama ) ) / al2be2;

        //                                        --- Step4  A3' ---

        float costhe = sqrt (1.0 - sinthe * sinthe );
        float xa3d = - ya2d * sinthe;
        float ya3d =   ya2d * costhe;
        float za3d = za1d;
        float xb3d =   xb2d * costhe - yb2d * sinthe;
        float yb3d =   xb2d * sinthe + yb2d * costhe;
        float zb3d = zb1d;
        float xc3d = - xb2d * costhe - yc2d * sinthe;
        float yc3d = - xb2d * sinthe + yc2d * costhe;
        float zc3d = zc1d;

        //                                        --- Step5  A3 ---

        float xa3 = trns11*xa3d + trns12*ya3d + trns13*za3d;
        float ya3 = trns21*xa3d + trns22*ya3d + trns23*za3d;
        float za3 = trns31*xa3d + trns32*ya3d + trns33*za3d;
        float xb3 = trns11*xb3d + trns12*yb3d + trns13*zb3d;
        float yb3 = trns21*xb3d + trns22*yb3d + trns23*zb3d;
        float zb3 = trns31*xb3d + trns32*yb3d + trns33*zb3d;
        float xc3 = trns11*xc3d + trns12*yc3d + trns13*zc3d;
        float yc3 = trns21*xc3d + trns22*yc3d + trns23*zc3d;
        float zc3 = trns31*xc3d + trns32*yc3d + trns33*zc3d;

        xp0.x = xcom + xa3 - apos0.x;
        xp0.y = ycom + ya3 - apos0.y;
        xp0.z = zcom + za3 - apos0.z;
        xp1.x = xcom + xb3 - apos1.x;
        xp1.y = ycom + yb3 - apos1.y;
        xp1.z = zcom + zb3 - apos1.z;
        xp2.x = xcom + xc3 - apos2.x;
        xp2.y = ycom + yc3 - apos2.y;
        xp2.z = zcom + zc3 - apos2.z;


        cSim.pPosqP[atomID.x] = xp0;
        cSim.pPosqP[atomID.y] = xp1;
        cSim.pPosqP[atomID.z] = xp2;

        pos += blockDim.x * gridDim.x;
    }
}

void kApplyFirstSettle(gpuContext gpu)
{
//    printf("kApplyFirstSettle\n");
    if (gpu->sim.settleConstraints > 0)
    {
        kApplyFirstSettle_kernel<<<gpu->sim.blocks, gpu->sim.settle_threads_per_block>>>();
        LAUNCHERROR("kApplyFirstSettle");
    }
}

__global__ void kApplySecondSettle_kernel()
{
    unsigned int pos = threadIdx.x + blockIdx.x * blockDim.x;
    while (pos < cSim.settleConstraints)
    {
        int4 atomID         = cSim.pSettleID[pos];
        float2 params       = cSim.pSettleParameter[pos];
        float4 apos0        = cSim.pOldPosq[atomID.x];
        float4 xp0          = cSim.pPosq[atomID.x];
        float4 apos1        = cSim.pOldPosq[atomID.y];
        float4 xp1          = cSim.pPosq[atomID.y];
        float4 apos2        = cSim.pOldPosq[atomID.z];
        float4 xp2          = cSim.pPosq[atomID.z];
        float m0            = 1.0/cSim.pVelm4[atomID.x].w;
        float m1            = 1.0/cSim.pVelm4[atomID.y].w;
        float m2            = 1.0/cSim.pVelm4[atomID.z].w;


        float xb0 = apos1.x-apos0.x;
        float yb0 = apos1.y-apos0.y;
        float zb0 = apos1.z-apos0.z;
        float xc0 = apos2.x-apos0.x;
        float yc0 = apos2.y-apos0.y;
        float zc0 = apos2.z-apos0.z;
        float dist1 = sqrt(xb0*xb0 + yb0*yb0 + zb0*zb0);
        float dist2 = sqrt(xc0*xc0 + yc0*yc0 + zc0*zc0);

        float totalMass = m0+m1+m2;
        float xcom = ((apos0.x+xp0.x)*m0 + (apos1.x+xp1.x)*m1 + (apos2.x+xp2.x)*m2) / totalMass;
        float ycom = ((apos0.y+xp0.y)*m0 + (apos1.y+xp1.y)*m1 + (apos2.y+xp2.y)*m2) / totalMass;
        float zcom = ((apos0.z+xp0.z)*m0 + (apos1.z+xp1.z)*m1 + (apos2.z+xp2.z)*m2) / totalMass;

        float xa1 = apos0.x + xp0.x - xcom;
        float ya1 = apos0.y + xp0.y - ycom;
        float za1 = apos0.z + xp0.z - zcom;
        float xb1 = apos1.x + xp1.x - xcom;
        float yb1 = apos1.y + xp1.y - ycom;
        float zb1 = apos1.z + xp1.z - zcom;
        float xc1 = apos2.x + xp2.x - xcom;
        float yc1 = apos2.y + xp2.y - ycom;
        float zc1 = apos2.z + xp2.z - zcom;

        float xaksZd = yb0*zc0 - zb0*yc0;
        float yaksZd = zb0*xc0 - xb0*zc0;
        float zaksZd = xb0*yc0 - yb0*xc0;
        float xaksXd = ya1*zaksZd - za1*yaksZd;
        float yaksXd = za1*xaksZd - xa1*zaksZd;
        float zaksXd = xa1*yaksZd - ya1*xaksZd;
        float xaksYd = yaksZd*zaksXd - zaksZd*yaksXd;
        float yaksYd = zaksZd*xaksXd - xaksZd*zaksXd;
        float zaksYd = xaksZd*yaksXd - yaksZd*xaksXd;

        float axlng = sqrt(xaksXd * xaksXd + yaksXd * yaksXd + zaksXd * zaksXd);
        float aylng = sqrt(xaksYd * xaksYd + yaksYd * yaksYd + zaksYd * zaksYd);
        float azlng = sqrt(xaksZd * xaksZd + yaksZd * yaksZd + zaksZd * zaksZd);
        float trns11 = xaksXd / axlng;
        float trns21 = yaksXd / axlng;
        float trns31 = zaksXd / axlng;
        float trns12 = xaksYd / aylng;
        float trns22 = yaksYd / aylng;
        float trns32 = zaksYd / aylng;
        float trns13 = xaksZd / azlng;
        float trns23 = yaksZd / azlng;
        float trns33 = zaksZd / azlng;

        float xb0d = trns11*xb0 + trns21*yb0 + trns31*zb0;
        float yb0d = trns12*xb0 + trns22*yb0 + trns32*zb0;
        float xc0d = trns11*xc0 + trns21*yc0 + trns31*zc0;
        float yc0d = trns12*xc0 + trns22*yc0 + trns32*zc0;
//        float xa1d = trns11*xa1 + trns21*ya1 + trns31*za1;
//        float ya1d = trns12*xa1 + trns22*ya1 + trns32*za1;
        float za1d = trns13*xa1 + trns23*ya1 + trns33*za1;
        float  xb1d = trns11*xb1 + trns21*yb1 + trns31*zb1;
        float  yb1d = trns12*xb1 + trns22*yb1 + trns32*zb1;
        float  zb1d = trns13*xb1 + trns23*yb1 + trns33*zb1;
        float  xc1d = trns11*xc1 + trns21*yc1 + trns31*zc1;
        float  yc1d = trns12*xc1 + trns22*yc1 + trns32*zc1;
        float  zc1d = trns13*xc1 + trns23*yc1 + trns33*zc1;

        //                                        --- Step2  A2' ---

        float rc = 0.5*params.y;
        float rb = sqrt(params.x*params.x-rc*rc);
        float ra = rb*(m1+m2)/totalMass;
        rb -= ra;
        float sinphi = za1d / ra;
        float cosphi = sqrt(1.0 - sinphi*sinphi);
        float sinpsi = ( zb1d - zc1d ) / (2*rc*cosphi);
        float cospsi = sqrt(1.0 - sinpsi*sinpsi);

        float ya2d =   ra * cosphi;
        float xb2d = - rc * cospsi;
        float yb2d = - rb * cosphi - rc *sinpsi * sinphi;
        float yc2d = - rb * cosphi + rc *sinpsi * sinphi;
        float xb2d2 = xb2d * xb2d;
        float hh2 = 4.0 * xb2d2 + (yb2d-yc2d) * (yb2d-yc2d) + (zb1d-zc1d) * (zb1d-zc1d);
        float deltx = 2.0 * xb2d + sqrt ( 4.0 * xb2d2 - hh2 + params.y*params.y );
        xb2d -= deltx * 0.5;

        //                                        --- Step3  al,be,ga ---

        float alpa = ( xb2d * (xb0d-xc0d) + yb0d * yb2d + yc0d * yc2d );
        float beta = ( xb2d * (yc0d-yb0d) + xb0d * yb2d + xc0d * yc2d );
        float gama = xb0d * yb1d - xb1d * yb0d + xc0d * yc1d - xc1d * yc0d;

        float al2be2 = alpa * alpa + beta * beta;
        float sinthe = ( alpa*gama - beta * sqrt ( al2be2 - gama * gama ) ) / al2be2;

        //                                        --- Step4  A3' ---

        float costhe = sqrt (1.0 - sinthe * sinthe );
        float xa3d = - ya2d * sinthe;
        float ya3d =   ya2d * costhe;
        float za3d = za1d;
        float xb3d =   xb2d * costhe - yb2d * sinthe;
        float yb3d =   xb2d * sinthe + yb2d * costhe;
        float zb3d = zb1d;
        float xc3d = - xb2d * costhe - yc2d * sinthe;
        float yc3d = - xb2d * sinthe + yc2d * costhe;
        float zc3d = zc1d;

        //                                        --- Step5  A3 ---

        float xa3 = trns11*xa3d + trns12*ya3d + trns13*za3d;
        float ya3 = trns21*xa3d + trns22*ya3d + trns23*za3d;
        float za3 = trns31*xa3d + trns32*ya3d + trns33*za3d;
        float xb3 = trns11*xb3d + trns12*yb3d + trns13*zb3d;
        float yb3 = trns21*xb3d + trns22*yb3d + trns23*zb3d;
        float zb3 = trns31*xb3d + trns32*yb3d + trns33*zb3d;
        float xc3 = trns11*xc3d + trns12*yc3d + trns13*zc3d;
        float yc3 = trns21*xc3d + trns22*yc3d + trns23*zc3d;
        float zc3 = trns31*xc3d + trns32*yc3d + trns33*zc3d;

        xp0.x = xcom + xa3;
        xp0.y = ycom + ya3;
        xp0.z = zcom + za3;
        xp1.x = xcom + xb3;
        xp1.y = ycom + yb3;
        xp1.z = zcom + zb3;
        xp2.x = xcom + xc3;
        xp2.y = ycom + yc3;
        xp2.z = zcom + zc3;


        cSim.pPosq[atomID.x] = xp0;
        cSim.pPosq[atomID.y] = xp1;
        cSim.pPosq[atomID.z] = xp2;

        pos += blockDim.x * gridDim.x;
    }
}

void kApplySecondSettle(gpuContext gpu)
{
//    printf("kApplySecondSettle\n");
    if (gpu->sim.settleConstraints > 0)
    {
        kApplySecondSettle_kernel<<<gpu->sim.blocks, gpu->sim.settle_threads_per_block>>>();
        LAUNCHERROR("kApplySecondSettle");
    }
}