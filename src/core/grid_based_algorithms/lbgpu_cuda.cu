/*
 * Copyright (C) 2010-2022 The ESPResSo project
 *
 * This file is part of ESPResSo.
 *
 * ESPResSo is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * ESPResSo is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
/** \file
 *  %Lattice Boltzmann on GPUs.
 *
 *  The corresponding header file is lbgpu.cuh.
 */

#include "config/config.hpp"

#ifdef CUDA

#include "grid_based_algorithms/OptionalCounter.hpp"
#include "grid_based_algorithms/lb-d3q19.hpp"
#include "grid_based_algorithms/lb_boundaries.hpp"
#include "grid_based_algorithms/lbgpu.cuh"
#include "grid_based_algorithms/lbgpu.hpp"

#include "cuda_interface.hpp"
#include "cuda_utils.cuh"
#include "errorhandling.hpp"
#include "lbgpu.hpp"

#include <utils/Array.hpp>
#include <utils/Counter.hpp>

#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <thrust/functional.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/transform_reduce.h>
#include <thrust/tuple.h>

#include <cuda.h>
#include <curand_kernel.h>

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

/** struct for hydrodynamic fields: this is for internal use
 *  (i.e. stores values in LB units) and should not be used for
 *  printing values
 */
static LB_rho_v_gpu *device_rho_v = nullptr;

/** struct for hydrodynamic fields: this is the interface
 *  and stores values in MD units. It should not be used
 *  as an input for any LB calculations. TODO: in the future,
 *  one might want to have several structures for printing
 *  separately rho, v, pi without having to compute/store
 *  the complete set.
 */
static LB_rho_v_pi_gpu *print_rho_v_pi = nullptr;

/** @name structs for velocity densities */
/**@{*/
static LB_nodes_gpu nodes_a;
static LB_nodes_gpu nodes_b;
/**@}*/

/** boundary information */
static LB_boundaries_gpu boundaries;

/** struct for node force density */
LB_node_force_density_gpu node_f = {
    // force_density
    nullptr,
#if defined(VIRTUAL_SITES_INERTIALESS_TRACERS) || defined(EK_DEBUG)
    // force_density_buf
    nullptr
#endif
};

#ifdef LB_BOUNDARIES_GPU
/** @brief Force on the boundary nodes */
static float *lb_boundary_force = nullptr;
#endif

/** @brief Whether LB GPU was initialized */
static bool *device_gpu_lb_initialized = nullptr;

/** @brief Direction of data transfer between @ref nodes_a and @ref nodes_b
 *  during integration in @ref lb_integrate_GPU
 */
static bool intflag = true;
LB_nodes_gpu *current_nodes = nullptr;

/** Parameters residing in constant memory */
__device__ __constant__ LB_parameters_gpu para[1];

static constexpr float sqrt12 = 3.4641016151377544f;
static constexpr unsigned int threads_per_block = 64;
OptionalCounter rng_counter_coupling_gpu;
OptionalCounter rng_counter_fluid_gpu;

/** Transformation from 1d array-index to xyz
 *  @param[in]  index   Node index / thread index
 */
template <typename T> __device__ uint3 index_to_xyz(T index) {
  auto const x = index % para->dim[0];
  index /= para->dim[0];
  auto const y = index % para->dim[1];
  index /= para->dim[1];
  auto const z = index;
  return {x, y, z};
}

/** Transformation from xyz to 1d array-index
 *  @param[in] x,y,z     The xyz array
 */
template <typename T> __device__ T xyz_to_index(T x, T y, T z) {
  return x +
         static_cast<T>(para->dim[0]) * (y + static_cast<T>(para->dim[1]) * z);
}

/** Calculate modes from the populations (space-transform).
 *  @param[in]  populations    Populations of one node.
 *  @param[out] mode    Modes corresponding to given @p populations.
 */
__device__ void calc_m_from_n(Utils::Array<float, 19> const &populations,
                              Utils::Array<float, 19> &mode) {
  /**
   * The following convention and equations from @cite dunweg09a are used:
   * The \f$\hat{c}_i\f$ are given by:
   *
   * \f{align*}{
   *   c_{ 0} &= ( 0, 0, 0) \\
   *   c_{ 1} &= ( 1, 0, 0) \\
   *   c_{ 2} &= (-1, 0, 0) \\
   *   c_{ 3} &= ( 0, 1, 0) \\
   *   c_{ 4} &= ( 0,-1, 0) \\
   *   c_{ 5} &= ( 0, 0, 1) \\
   *   c_{ 6} &= ( 0, 0,-1) \\
   *   c_{ 7} &= ( 1, 1, 0) \\
   *   c_{ 8} &= (-1,-1, 0) \\
   *   c_{ 9} &= ( 1,-1, 0) \\
   *   c_{10} &= (-1, 1, 0) \\
   *   c_{11} &= ( 1, 0, 1) \\
   *   c_{12} &= (-1, 0,-1) \\
   *   c_{13} &= ( 1, 0,-1) \\
   *   c_{14} &= (-1, 0, 1) \\
   *   c_{15} &= ( 0, 1, 1) \\
   *   c_{16} &= ( 0,-1,-1) \\
   *   c_{17} &= ( 0, 1,-1) \\
   *   c_{18} &= ( 0,-1, 1)
   *  \f}
   *
   *  The basis vectors (modes) are constructed as follows (eq. (111)):
   *  \f[m_k = \sum_{i} e_{ki} n_{i}\f] where the \f$e_{ki}\f$ form a
   *  linear transformation (matrix) that is given by (modified from table 1):
   *
   *  \f{align*}{
   *    e_{ 0,i} &= 1 \\
   *    e_{ 1,i} &= \hat{c}_{i,x} \\
   *    e_{ 2,i} &= \hat{c}_{i,y} \\
   *    e_{ 3,i} &= \hat{c}_{i,z} \\
   *    e_{ 4,i} &= \hat{c}_{i}^2 - 1 \\
   *    e_{ 5,i} &= \hat{c}_{i,x}^2 - \hat{c}_{i,y}^2 \\
   *    e_{ 6,i} &= \hat{c}_{i}^2 - 3 \hat{c}_{i,z}^2 \\
   *    e_{ 7,i} &= \hat{c}_{i,x} \hat{c}_{i,y} \\
   *    e_{ 8,i} &= \hat{c}_{i,x} \hat{c}_{i,z} \\
   *    e_{ 9,i} &= \hat{c}_{i,y} \hat{c}_{i,z} \\
   *    e_{10,i} &= (3 \hat{c}_{i}^2 - 5) \hat{c}_{i,x} \\
   *    e_{11,i} &= (3 \hat{c}_{i}^2 - 5) \hat{c}_{i,y} \\
   *    e_{12,i} &= (3 \hat{c}_{i}^2 - 5) \hat{c}_{i,z} \\
   *    e_{13,i} &= (\hat{c}_{i,y}^2 - \hat{c}_{i,z}^2) \hat{c}_{i,x} \\
   *    e_{14,i} &= (\hat{c}_{i,x}^2 - \hat{c}_{i,z}^2) \hat{c}_{i,y} \\
   *    e_{15,i} &= (\hat{c}_{i,x}^2 - \hat{c}_{i,y}^2) \hat{c}_{i,z} \\
   *    e_{16,i} &= 3 \hat{c}_{i}^4 - 6 \hat{c}_{i}^2 + 1 \\
   *    e_{17,i} &= (2 \hat{c}_{i}^2 - 3) (\hat{c}_{i,x}^2 - \hat{c}_{i,y}^2) \\
   *    e_{18,i} &= (2 \hat{c}_{i}^2 - 3) (\hat{c}_{i}^2 - 3 \hat{c}_{i,z}^2)
   *  \f}
   *
   *  Such that the transformation matrix is given by:
   *
   *  \code{.cpp}
   *   {{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
   *    { 0, 1,-1, 0, 0, 0, 0, 1,-1, 1,-1, 1,-1, 1,-1, 0, 0, 0, 0},
   *    { 0, 0, 0, 1,-1, 0, 0, 1,-1,-1, 1, 0, 0, 0, 0, 1,-1, 1,-1},
   *    { 0, 0, 0, 0, 0, 1,-1, 0, 0, 0, 0, 1,-1,-1, 1, 1,-1,-1, 1},
   *    {-1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
   *    { 0, 1, 1,-1,-1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,-1,-1,-1,-1},
   *    { 0, 1, 1, 1, 1,-2,-2, 2, 2, 2, 2,-1,-1,-1,-1,-1,-1,-1,-1},
   *    { 0, 0, 0, 0, 0, 0, 0, 1, 1,-1,-1, 0, 0, 0, 0, 0, 0, 0, 0},
   *    { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1,-1,-1, 0, 0, 0, 0},
   *    { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1,-1,-1},
   *    { 0,-2, 2, 0, 0, 0, 0, 1,-1, 1,-1, 1,-1, 1,-1, 0, 0, 0, 0},
   *    { 0, 0, 0,-2, 2, 0, 0, 1,-1,-1, 1, 0, 0, 0, 0, 1,-1, 1,-1},
   *    { 0, 0, 0, 0, 0,-2, 2, 0, 0, 0, 0, 1,-1,-1, 1, 1,-1,-1, 1},
   *    { 0, 0, 0, 0, 0, 0, 0, 1,-1, 1,-1,-1, 1,-1, 1, 0, 0, 0, 0},
   *    { 0, 0, 0, 0, 0, 0, 0, 1,-1,-1, 1, 0, 0, 0, 0,-1, 1,-1, 1},
   *    { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,-1,-1, 1,-1, 1, 1,-1},
   *    { 1,-2,-2,-2,-2,-2,-2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
   *    { 0,-1,-1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,-1,-1,-1,-1},
   *    { 0,-1,-1,-1,-1, 2, 2, 2, 2, 2, 2,-1,-1,-1,-1,-1,-1,-1,-1}}
   *  \endcode
   *
   *  with weights
   *
   *  \f[q^{c_{i}} = ( 1/3, 1/18, 1/18, 1/18,
   *                  1/18, 1/18, 1/18, 1/36,
   *                  1/36, 1/36, 1/36, 1/36,
   *                  1/36, 1/36, 1/36, 1/36,
   *                  1/36, 1/36, 1/36 )\f]
   *
   *  which makes the transformation satisfy the following
   *  orthogonality condition (eq. (109)):
   *  \f[\sum_{i} q^{c_{i}} e_{ki} e_{li} = w_{k} \delta_{kl}\f]
   *  where the weights are:
   *
   *  \f[w_{i} = (  1, 1/3, 1/3, 1/3,
   *              2/3, 4/9, 4/3, 1/9,
   *              1/9, 1/9, 2/3, 2/3,
   *              2/3, 2/9, 2/9, 2/9,
   *                2, 4/9, 4/3 )\f]
   */
  for (int i = 0; i < 19; ++i) {
    mode[i] = calc_mode_x_from_n(populations, i);
  }
}

__device__ void reset_LB_force_densities(unsigned int index,
                                         LB_node_force_density_gpu node_f,
                                         bool buffer = true) {
#if defined(VIRTUAL_SITES_INERTIALESS_TRACERS) || defined(EK_DEBUG)
  // Store backup of the node forces
  if (buffer) {
    node_f.force_density_buf[index] = node_f.force_density[index];
  }
#endif

  if (para->external_force_density) {
    node_f.force_density[index] = para->ext_force_density;
  } else {
    node_f.force_density[index] = {};
  }
}

__global__ void
reset_LB_force_densities_kernel(LB_node_force_density_gpu node_f,
                                bool buffer = true) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes)
    reset_LB_force_densities(index, node_f, buffer);
}

void reset_LB_force_densities_GPU(bool buffer) {
  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(reset_LB_force_densities_kernel, dim_grid, threads_per_block,
             node_f, buffer);
}

/**
 *  @param[in]  modes    Local register values modes
 *  @param[in]  index   Node index / thread index
 *  @param[in]  node_f  Local node force
 *  @param[out] d_v     Local device values
 */
__device__ void update_rho_v(Utils::Array<float, 19> const &modes,
                             unsigned int index,
                             LB_node_force_density_gpu const &node_f,
                             LB_rho_v_gpu *d_v) {
  float Rho_tot = 0.0f;
  Utils::Array<float, 3> u_tot = {};

  /* re-construct the real density
   * remember that the populations are stored as differences to their
   * equilibrium value */

  d_v[index].rho = modes[0] + para->rho;
  Rho_tot += modes[0] + para->rho;
  u_tot[0] += modes[1];
  u_tot[1] += modes[2];
  u_tot[2] += modes[3];

  /** If forces are present, the momentum density is redefined to
   *  include one half-step of the force action. See the
   *  Chapman-Enskog expansion in @cite ladd01a.
   */

  u_tot[0] += 0.5f * node_f.force_density[index][0];
  u_tot[1] += 0.5f * node_f.force_density[index][1];
  u_tot[2] += 0.5f * node_f.force_density[index][2];

  u_tot[0] /= Rho_tot;
  u_tot[1] /= Rho_tot;
  u_tot[2] /= Rho_tot;

  d_v[index].v[0] = u_tot[0];
  d_v[index].v[1] = u_tot[1];
  d_v[index].v[2] = u_tot[2];
}

/** lb_relax_modes, means collision update of the modes
 *  @param[in] index     Node index / thread index
 *  @param[in,out] mode  Local register values mode
 *  @param[in] node_f    Local node force
 *  @param[in,out] d_v   Local device values
 */
__device__ void relax_modes(Utils::Array<float, 19> &mode, unsigned int index,
                            LB_node_force_density_gpu node_f,
                            LB_rho_v_gpu *d_v) {
  float u_tot[3] = {0.0f, 0.0f, 0.0f};

  update_rho_v(mode, index, node_f, d_v);

  u_tot[0] = d_v[index].v[0];
  u_tot[1] = d_v[index].v[1];
  u_tot[2] = d_v[index].v[2];

  float Rho;
  float j[3];
  Utils::Array<float, 6> modes_from_pi_eq;

  Rho = mode[0] + para->rho;
  j[0] = Rho * u_tot[0];
  j[1] = Rho * u_tot[1];
  j[2] = Rho * u_tot[2];

  /* equilibrium part of the stress modes (eq13 schiller) */

  modes_from_pi_eq[0] = ((j[0] * j[0]) + (j[1] * j[1]) + (j[2] * j[2])) / Rho;
  modes_from_pi_eq[1] = ((j[0] * j[0]) - (j[1] * j[1])) / Rho;
  modes_from_pi_eq[2] =
      (((j[0] * j[0]) + (j[1] * j[1]) + (j[2] * j[2])) - 3.0f * (j[2] * j[2])) /
      Rho;
  modes_from_pi_eq[3] = j[0] * j[1] / Rho;
  modes_from_pi_eq[4] = j[0] * j[2] / Rho;
  modes_from_pi_eq[5] = j[1] * j[2] / Rho;

  /* relax the stress modes (eq14 schiller) */

  mode[4] =
      modes_from_pi_eq[0] + para->gamma_bulk * (mode[4] - modes_from_pi_eq[0]);
  mode[5] =
      modes_from_pi_eq[1] + para->gamma_shear * (mode[5] - modes_from_pi_eq[1]);
  mode[6] =
      modes_from_pi_eq[2] + para->gamma_shear * (mode[6] - modes_from_pi_eq[2]);
  mode[7] =
      modes_from_pi_eq[3] + para->gamma_shear * (mode[7] - modes_from_pi_eq[3]);
  mode[8] =
      modes_from_pi_eq[4] + para->gamma_shear * (mode[8] - modes_from_pi_eq[4]);
  mode[9] =
      modes_from_pi_eq[5] + para->gamma_shear * (mode[9] - modes_from_pi_eq[5]);

  /* relax the ghost modes (project them out) */
  /* ghost modes have no equilibrium part due to orthogonality */

  mode[10] = para->gamma_odd * mode[10];
  mode[11] = para->gamma_odd * mode[11];
  mode[12] = para->gamma_odd * mode[12];
  mode[13] = para->gamma_odd * mode[13];
  mode[14] = para->gamma_odd * mode[14];
  mode[15] = para->gamma_odd * mode[15];
  mode[16] = para->gamma_even * mode[16];
  mode[17] = para->gamma_even * mode[17];
  mode[18] = para->gamma_even * mode[18];
}

/** Thermalization of the modes with Gaussian random numbers
 *  @param[in] index     Node index / thread index
 *  @param[in,out] mode  Local register values mode
 *  @param[in]  philox_counter   Philox counter
 */
__device__ void thermalize_modes(Utils::Array<float, 19> &mode,
                                 unsigned int index, uint64_t philox_counter) {
  float Rho;
  float4 random_floats;
  /* mass mode */
  Rho = mode[0] + para->rho;

  /* stress modes */
  random_floats = random_wrapper_philox(index, 4, philox_counter);
  mode[4] += sqrtf(Rho * (para->mu * (2.0f / 3.0f) *
                          (1.0f - (para->gamma_bulk * para->gamma_bulk)))) *
             (random_floats.w - 0.5f) * sqrt12;
  mode[5] += sqrtf(Rho * (para->mu * (4.0f / 9.0f) *
                          (1.0f - (para->gamma_shear * para->gamma_shear)))) *
             (random_floats.x - 0.5f) * sqrt12;

  mode[6] += sqrtf(Rho * (para->mu * (4.0f / 3.0f) *
                          (1.0f - (para->gamma_shear * para->gamma_shear)))) *
             (random_floats.y - 0.5f) * sqrt12;
  mode[7] += sqrtf(Rho * (para->mu * (1.0f / 9.0f) *
                          (1.0f - (para->gamma_shear * para->gamma_shear)))) *
             (random_floats.z - 0.5f) * sqrt12;

  random_floats = random_wrapper_philox(index, 8, philox_counter);
  mode[8] += sqrtf(Rho * (para->mu * (1.0f / 9.0f) *
                          (1.0f - (para->gamma_shear * para->gamma_shear)))) *
             (random_floats.w - 0.5f) * sqrt12;
  mode[9] += sqrtf(Rho * (para->mu * (1.0f / 9.0f) *
                          (1.0f - (para->gamma_shear * para->gamma_shear)))) *
             (random_floats.x - 0.5f) * sqrt12;

  /* ghost modes */
  mode[10] += sqrtf(Rho * (para->mu * (2.0f / 3.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.y - 0.5f) * sqrt12;
  mode[11] += sqrtf(Rho * (para->mu * (2.0f / 3.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.z - 0.5f) * sqrt12;

  random_floats = random_wrapper_philox(index, 12, philox_counter);
  mode[12] += sqrtf(Rho * (para->mu * (2.0f / 3.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.w - 0.5f) * sqrt12;
  mode[13] += sqrtf(Rho * (para->mu * (2.0f / 9.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.x - 0.5f) * sqrt12;

  mode[14] += sqrtf(Rho * (para->mu * (2.0f / 9.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.y - 0.5f) * sqrt12;
  mode[15] += sqrtf(Rho * (para->mu * (2.0f / 9.0f) *
                           (1.0f - (para->gamma_odd * para->gamma_odd)))) *
              (random_floats.z - 0.5f) * sqrt12;

  random_floats = random_wrapper_philox(index, 16, philox_counter);
  mode[16] += sqrtf(Rho * (para->mu * (2.0f) *
                           (1.0f - (para->gamma_even * para->gamma_even)))) *
              (random_floats.w - 0.5f) * sqrt12;
  mode[17] += sqrtf(Rho * (para->mu * (4.0f / 9.0f) *
                           (1.0f - (para->gamma_even * para->gamma_even)))) *
              (random_floats.x - 0.5f) * sqrt12;

  mode[18] += sqrtf(Rho * (para->mu * (4.0f / 3.0f) *
                           (1.0f - (para->gamma_even * para->gamma_even)))) *
              (random_floats.y - 0.5f) * sqrt12;
}

/** Normalization of the modes need before back-transformation into velocity
 *  space
 *  @param[in,out] mode  Local register values mode
 */
__device__ void normalize_modes(Utils::Array<float, 19> &mode) {
  /* normalization factors enter in the back transformation */
  mode[0] *= 1.0f;
  mode[1] *= 3.0f;
  mode[2] *= 3.0f;
  mode[3] *= 3.0f;
  mode[4] *= 3.0f / 2.0f;
  mode[5] *= 9.0f / 4.0f;
  mode[6] *= 3.0f / 4.0f;
  mode[7] *= 9.0f;
  mode[8] *= 9.0f;
  mode[9] *= 9.0f;
  mode[10] *= 3.0f / 2.0f;
  mode[11] *= 3.0f / 2.0f;
  mode[12] *= 3.0f / 2.0f;
  mode[13] *= 9.0f / 2.0f;
  mode[14] *= 9.0f / 2.0f;
  mode[15] *= 9.0f / 2.0f;
  mode[16] *= 1.0f / 2.0f;
  mode[17] *= 9.0f / 4.0f;
  mode[18] *= 3.0f / 4.0f;
}

/** Back-transformation from modespace to densityspace and streaming with
 *  the push method using pbc
 *  @param[in]  index  Node index / thread index
 *  @param[in]  mode   Local register values mode
 *  @param[out] n_b    Local node residing in array b
 */
__device__ void calc_n_from_modes_push(LB_nodes_gpu n_b,
                                       Utils::Array<float, 19> const &mode,
                                       unsigned int index) {
  auto const xyz = index_to_xyz(index);
  unsigned int x = xyz.x;
  unsigned int y = xyz.y;
  unsigned int z = xyz.z;

  n_b.populations[x + para->dim[0] * y + para->dim[0] * para->dim[1] * z][0] =
      1.0f / 3.0f * (mode[0] - mode[4] + mode[16]);

  n_b.populations[(x + 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] * z][1] =
      1.0f / 18.0f *
      (mode[0] + mode[1] + mode[5] + mode[6] - mode[17] - mode[18] -
       2.0f * (mode[10] + mode[16]));

  n_b.populations[(para->dim[0] + x - 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] * z][2] =
      1.0f / 18.0f *
      (mode[0] - mode[1] + mode[5] + mode[6] - mode[17] - mode[18] +
       2.0f * (mode[10] - mode[16]));

  n_b.populations[x + para->dim[0] * ((y + 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][3] =
      1.0f / 18.0f *
      (mode[0] + mode[2] - mode[5] + mode[6] + mode[17] - mode[18] -
       2.0f * (mode[11] + mode[16]));

  n_b.populations[x + para->dim[0] * ((para->dim[1] + y - 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][4] =
      1.0f / 18.0f *
      (mode[0] - mode[2] - mode[5] + mode[6] + mode[17] - mode[18] +
       2.0f * (mode[11] - mode[16]));

  n_b.populations[x + para->dim[0] * y +
                  para->dim[0] * para->dim[1] * ((z + 1) % para->dim[2])][5] =
      1.0f / 18.0f *
      (mode[0] + mode[3] - 2.0f * (mode[6] + mode[12] + mode[16] - mode[18]));

  n_b.populations[x + para->dim[0] * y +
                  para->dim[0] * para->dim[1] *
                      ((para->dim[2] + z - 1) % para->dim[2])][6] =
      1.0f / 18.0f *
      (mode[0] - mode[3] - 2.0f * (mode[6] - mode[12] + mode[16] - mode[18]));

  n_b.populations[(x + 1) % para->dim[0] +
                  para->dim[0] * ((y + 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][7] =
      1.0f / 36.0f *
      (mode[0] + mode[1] + mode[2] + mode[4] + 2.0f * mode[6] + mode[7] +
       mode[10] + mode[11] + mode[13] + mode[14] + mode[16] + 2.0f * mode[18]);

  n_b.populations[(para->dim[0] + x - 1) % para->dim[0] +
                  para->dim[0] * ((para->dim[1] + y - 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][8] =
      1.0f / 36.0f *
      (mode[0] - mode[1] - mode[2] + mode[4] + 2.0f * mode[6] + mode[7] -
       mode[10] - mode[11] - mode[13] - mode[14] + mode[16] + 2.0f * mode[18]);

  n_b.populations[(x + 1) % para->dim[0] +
                  para->dim[0] * ((para->dim[1] + y - 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][9] =
      1.0f / 36.0f *
      (mode[0] + mode[1] - mode[2] + mode[4] + 2.0f * mode[6] - mode[7] +
       mode[10] - mode[11] + mode[13] - mode[14] + mode[16] + 2.0f * mode[18]);

  n_b.populations[(para->dim[0] + x - 1) % para->dim[0] +
                  para->dim[0] * ((y + 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * z][10] =
      1.0f / 36.0f *
      (mode[0] - mode[1] + mode[2] + mode[4] + 2.0f * mode[6] - mode[7] -
       mode[10] + mode[11] - mode[13] + mode[14] + mode[16] + 2.0f * mode[18]);

  n_b.populations[(x + 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] * ((z + 1) % para->dim[2])][11] =
      1.0f / 36.0f *
      (mode[0] + mode[1] + mode[3] + mode[4] + mode[5] - mode[6] + mode[8] +
       mode[10] + mode[12] - mode[13] + mode[15] + mode[16] + mode[17] -
       mode[18]);

  n_b.populations[(para->dim[0] + x - 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] *
                      ((para->dim[2] + z - 1) % para->dim[2])][12] =
      1.0f / 36.0f *
      (mode[0] - mode[1] - mode[3] + mode[4] + mode[5] - mode[6] + mode[8] -
       mode[10] - mode[12] + mode[13] - mode[15] + mode[16] + mode[17] -
       mode[18]);

  n_b.populations[(x + 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] *
                      ((para->dim[2] + z - 1) % para->dim[2])][13] =
      1.0f / 36.0f *
      (mode[0] + mode[1] - mode[3] + mode[4] + mode[5] - mode[6] - mode[8] +
       mode[10] - mode[12] - mode[13] - mode[15] + mode[16] + mode[17] -
       mode[18]);

  n_b.populations[(para->dim[0] + x - 1) % para->dim[0] + para->dim[0] * y +
                  para->dim[0] * para->dim[1] * ((z + 1) % para->dim[2])][14] =
      1.0f / 36.0f *
      (mode[0] - mode[1] + mode[3] + mode[4] + mode[5] - mode[6] - mode[8] -
       mode[10] + mode[12] + mode[13] + mode[15] + mode[16] + mode[17] -
       mode[18]);

  n_b.populations[x + para->dim[0] * ((y + 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * ((z + 1) % para->dim[2])][15] =
      1.0f / 36.0f *
      (mode[0] + mode[2] + mode[3] + mode[4] - mode[5] - mode[6] + mode[9] +
       mode[11] + mode[12] - mode[14] - mode[15] + mode[16] - mode[17] -
       mode[18]);

  n_b.populations[x + para->dim[0] * ((para->dim[1] + y - 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] *
                      ((para->dim[2] + z - 1) % para->dim[2])][16] =
      1.0f / 36.0f *
      (mode[0] - mode[2] - mode[3] + mode[4] - mode[5] - mode[6] + mode[9] -
       mode[11] - mode[12] + mode[14] + mode[15] + mode[16] - mode[17] -
       mode[18]);

  n_b.populations[x + para->dim[0] * ((y + 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] *
                      ((para->dim[2] + z - 1) % para->dim[2])][17] =
      1.0f / 36.0f *
      (mode[0] + mode[2] - mode[3] + mode[4] - mode[5] - mode[6] - mode[9] +
       mode[11] - mode[12] - mode[14] + mode[15] + mode[16] - mode[17] -
       mode[18]);

  n_b.populations[x + para->dim[0] * ((para->dim[1] + y - 1) % para->dim[1]) +
                  para->dim[0] * para->dim[1] * ((z + 1) % para->dim[2])][18] =
      1.0f / 36.0f *
      (mode[0] - mode[2] + mode[3] + mode[4] - mode[5] - mode[6] - mode[9] -
       mode[11] + mode[12] + mode[14] - mode[15] + mode[16] - mode[17] -
       mode[18]);
}

/** Bounce back boundary conditions.
 *
 *  The populations that have propagated into a boundary node
 *  are bounced back to the node they came from. This results
 *  in no slip boundary conditions, cf. @cite ladd01a.
 *
 *  @param[in]  index   Node index / thread index
 *  @param[in]  n_curr  Local node receiving the current node field
 *  @param[in]  boundaries  Constant velocity at the boundary, set by the user
 *  @param[out] lb_boundary_force     Force on the boundary nodes
 */
__device__ void bounce_back_boundaries(LB_nodes_gpu n_curr,
                                       LB_boundaries_gpu boundaries,
                                       unsigned int index,
                                       float *lb_boundary_force) {
  int c[3];
  float shift, weight, pop_to_bounce_back;
  float boundary_force[3] = {0.0f, 0.0f, 0.0f};
  std::size_t to_index, to_index_x, to_index_y, to_index_z;
  unsigned population, inverse;

  if (boundaries.index[index] != 0) {
    auto const v = boundaries.velocity[index];

    auto const xyz = index_to_xyz(index);

    unsigned int x = xyz.x;
    unsigned int y = xyz.y;
    unsigned int z = xyz.z;

    /* store populations temporary in second lattice to avoid race conditions */

    // TODO : PUT IN EQUILIBRIUM CONTRIBUTION TO THE BOUNCE-BACK DENSITY FOR THE
    // BOUNDARY FORCE
    // TODO : INITIALIZE BOUNDARY FORCE PROPERLY, HAS NONZERO ELEMENTS IN FIRST
    // STEP
    // TODO : SET INTERNAL BOUNDARY NODE VALUES TO ZERO

#define BOUNCEBACK()                                                           \
  shift = 2.0f / para->agrid * para->rho * 3.0f * weight * para->tau *         \
          (v[0] * static_cast<float>(c[0]) + v[1] * static_cast<float>(c[1]) + \
           v[2] * static_cast<float>(c[2]));                                   \
  pop_to_bounce_back = n_curr.populations[index][population];                  \
  to_index_x =                                                                 \
      (x + static_cast<unsigned>(c[0]) + para->dim[0]) % para->dim[0];         \
  to_index_y =                                                                 \
      (y + static_cast<unsigned>(c[1]) + para->dim[1]) % para->dim[1];         \
  to_index_z =                                                                 \
      (z + static_cast<unsigned>(c[2]) + para->dim[2]) % para->dim[2];         \
  to_index = to_index_x + para->dim[0] * to_index_y +                          \
             para->dim[0] * para->dim[1] * to_index_z;                         \
  if (n_curr.boundary[to_index] == 0) {                                        \
    boundary_force[0] +=                                                       \
        (2.0f * pop_to_bounce_back + shift) * static_cast<float>(c[0]);        \
    boundary_force[1] +=                                                       \
        (2.0f * pop_to_bounce_back + shift) * static_cast<float>(c[1]);        \
    boundary_force[2] +=                                                       \
        (2.0f * pop_to_bounce_back + shift) * static_cast<float>(c[2]);        \
    n_curr.populations[to_index][inverse] = pop_to_bounce_back + shift;        \
  }

    // the resting population does nothing, i.e., population 0.
    c[0] = 1;
    c[1] = 0;
    c[2] = 0;
    weight = 1.f / 18.f;
    population = 2;
    inverse = 1;
    BOUNCEBACK();

    c[0] = -1;
    c[1] = 0;
    c[2] = 0;
    weight = 1.f / 18.f;
    population = 1;
    inverse = 2;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = 1;
    c[2] = 0;
    weight = 1.f / 18.f;
    population = 4;
    inverse = 3;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = -1;
    c[2] = 0;
    weight = 1.f / 18.f;
    population = 3;
    inverse = 4;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = 0;
    c[2] = 1;
    weight = 1.f / 18.f;
    population = 6;
    inverse = 5;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = 0;
    c[2] = -1;
    weight = 1.f / 18.f;
    population = 5;
    inverse = 6;
    BOUNCEBACK();

    c[0] = 1;
    c[1] = 1;
    c[2] = 0;
    weight = 1.f / 36.f;
    population = 8;
    inverse = 7;
    BOUNCEBACK();

    c[0] = -1;
    c[1] = -1;
    c[2] = 0;
    weight = 1.f / 36.f;
    population = 7;
    inverse = 8;
    BOUNCEBACK();

    c[0] = 1;
    c[1] = -1;
    c[2] = 0;
    weight = 1.f / 36.f;
    population = 10;
    inverse = 9;
    BOUNCEBACK();

    c[0] = -1;
    c[1] = 1;
    c[2] = 0;
    weight = 1.f / 36.f;
    population = 9;
    inverse = 10;
    BOUNCEBACK();

    c[0] = 1;
    c[1] = 0;
    c[2] = 1;
    weight = 1.f / 36.f;
    population = 12;
    inverse = 11;
    BOUNCEBACK();

    c[0] = -1;
    c[1] = 0;
    c[2] = -1;
    weight = 1.f / 36.f;
    population = 11;
    inverse = 12;
    BOUNCEBACK();

    c[0] = 1;
    c[1] = 0;
    c[2] = -1;
    weight = 1.f / 36.f;
    population = 14;
    inverse = 13;
    BOUNCEBACK();

    c[0] = -1;
    c[1] = 0;
    c[2] = 1;
    weight = 1.f / 36.f;
    population = 13;
    inverse = 14;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = 1;
    c[2] = 1;
    weight = 1.f / 36.f;
    population = 16;
    inverse = 15;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = -1;
    c[2] = -1;
    weight = 1.f / 36.f;
    population = 15;
    inverse = 16;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = 1;
    c[2] = -1;
    weight = 1.f / 36.f;
    population = 18;
    inverse = 17;
    BOUNCEBACK();

    c[0] = 0;
    c[1] = -1;
    c[2] = 1;
    weight = 1.f / 36.f;
    population = 17;
    inverse = 18;
    BOUNCEBACK();

    atomicAdd(&lb_boundary_force[3 * (n_curr.boundary[index] - 1) + 0],
              boundary_force[0]);
    atomicAdd(&lb_boundary_force[3 * (n_curr.boundary[index] - 1) + 1],
              boundary_force[1]);
    atomicAdd(&lb_boundary_force[3 * (n_curr.boundary[index] - 1) + 2],
              boundary_force[2]);
  }
}

/** Add external forces within the modespace, needed for particle-interaction
 *  @param[in]     index   Node index / thread index
 *  @param[in,out] mode    Local register values mode
 *  @param[in,out] node_f  Local node force
 *  @param[in]     d_v     Local device values
 */
__device__ void apply_forces(unsigned int index, Utils::Array<float, 19> &mode,
                             LB_node_force_density_gpu node_f,
                             LB_rho_v_gpu *d_v) {
  float u[3] = {0.0f, 0.0f, 0.0f}, C[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
  /* Note: the values d_v were calculated in relax_modes() */

  u[0] = d_v[index].v[0];
  u[1] = d_v[index].v[1];
  u[2] = d_v[index].v[2];

  C[0] += (1.0f + para->gamma_shear) * u[0] * node_f.force_density[index][0] +
          1.0f / 3.0f * (para->gamma_bulk - para->gamma_shear) *
              (u[0] * node_f.force_density[index][0] +
               u[1] * node_f.force_density[index][1] +
               u[2] * node_f.force_density[index][2]);

  C[2] += (1.0f + para->gamma_shear) * u[1] * node_f.force_density[index][1] +
          1.0f / 3.0f * (para->gamma_bulk - para->gamma_shear) *
              (u[0] * node_f.force_density[index][0] +
               u[1] * node_f.force_density[index][1] +
               u[2] * node_f.force_density[index][2]);

  C[5] += (1.0f + para->gamma_shear) * u[2] * node_f.force_density[index][2] +
          1.0f / 3.0f * (para->gamma_bulk - para->gamma_shear) *
              (u[0] * node_f.force_density[index][0] +
               u[1] * node_f.force_density[index][1] +
               u[2] * node_f.force_density[index][2]);

  C[1] += 1.0f / 2.0f * (1.0f + para->gamma_shear) *
          (u[0] * node_f.force_density[index][1] +
           u[1] * node_f.force_density[index][0]);

  C[3] += 1.0f / 2.0f * (1.0f + para->gamma_shear) *
          (u[0] * node_f.force_density[index][2] +
           u[2] * node_f.force_density[index][0]);

  C[4] += 1.0f / 2.0f * (1.0f + para->gamma_shear) *
          (u[1] * node_f.force_density[index][2] +
           u[2] * node_f.force_density[index][1]);

  /* update momentum modes */
  mode[1] += node_f.force_density[index][0];
  mode[2] += node_f.force_density[index][1];
  mode[3] += node_f.force_density[index][2];

  /* update stress modes */
  mode[4] += C[0] + C[2] + C[5];
  mode[5] += C[0] - C[2];
  mode[6] += C[0] + C[2] - 2.0f * C[5];
  mode[7] += C[1];
  mode[8] += C[3];
  mode[9] += C[4];

  reset_LB_force_densities(index, node_f);
}

__device__ Utils::Array<float, 19>
stress_modes(LB_rho_v_gpu const &rho_v, const Utils::Array<float, 19> &modes) {
  /* note that d_v[index].v[] already includes the 1/2 f term, accounting
   * for the pre- and post-collisional average
   */
  auto const density = rho_v.rho;
  Utils::Array<float, 3> j{density * rho_v.v[0], density * rho_v.v[1],
                           density * rho_v.v[2]};
  // equilibrium part of the stress modes, which comes from
  // the equality between modes and stress tensor components

  /* m4 = trace(pi) - rho
     m5 = pi_xx - pi_yy
     m6 = trace(pi) - 3 pi_zz
     m7 = pi_xy
     m8 = pi_xz
     m9 = pi_yz */

  // and plugging in the Euler stress for the equilibrium:
  // pi_eq = rho_0*c_s^2*I3 + (j \otimes j)/rho
  // with I3 the 3D identity matrix and
  // rho = \trace(rho_0*c_s^2*I3), which yields

  /* m4_from_pi_eq = j.j
     m5_from_pi_eq = j_x*j_x - j_y*j_y
     m6_from_pi_eq = j.j - 3*j_z*j_z
     m7_from_pi_eq = j_x*j_y
     m8_from_pi_eq = j_x*j_z
     m9_from_pi_eq = j_y*j_z */

  // where the / density term has been dropped. We thus obtain:
  /* Now we must predict the outcome of the next collision */
  /* We immediately average pre- and post-collision. */
  /* TODO: need a reference for this. */
  Utils::Array<float, 6> modes_from_pi_eq{
      (j[0] * j[0] + j[1] * j[1] + j[2] * j[2]) / density,
      (j[0] * j[0] - j[1] * j[1]) / density,
      (j[0] * j[0] + j[1] * j[1] + j[2] * j[2] - 3.0f * j[2] * j[2]) / density,
      j[0] * j[1] / density,
      j[0] * j[2] / density,
      j[1] * j[2] / density};
  auto res = modes;
  res[4] = modes_from_pi_eq[0] +
           (0.5f + 0.5f * para->gamma_bulk) * (modes[4] - modes_from_pi_eq[0]);
  res[5] = modes_from_pi_eq[1] +
           (0.5f + 0.5f * para->gamma_shear) * (modes[5] - modes_from_pi_eq[1]);
  res[6] = modes_from_pi_eq[2] +
           (0.5f + 0.5f * para->gamma_shear) * (modes[6] - modes_from_pi_eq[2]);
  res[7] = modes_from_pi_eq[3] +
           (0.5f + 0.5f * para->gamma_shear) * (modes[7] - modes_from_pi_eq[3]);
  res[8] = modes_from_pi_eq[4] +
           (0.5f + 0.5f * para->gamma_shear) * (modes[8] - modes_from_pi_eq[4]);
  res[9] = modes_from_pi_eq[5] +
           (0.5f + 0.5f * para->gamma_shear) * (modes[9] - modes_from_pi_eq[5]);
  return res;
}

/** Calculate the stress tensor.
 *  Transform the stress tensor components according to the modes that
 *  correspond to those used by U. Schiller. In terms of populations this
 *  expression then corresponds exactly to those in eq. (116)-(121) in
 *  @cite dunweg07a, when these are written out in populations.
 *  But to ensure this, the expression in Schiller's modes has to be
 *  different!
 *  @param[in]  modes   Local register values modes
 */
__device__ Utils::Array<float, 6>
stress_from_stress_modes(Utils::Array<float, 19> const &modes) {
  return {(2.0f * (modes[0] + modes[4]) + modes[6] + 3.0f * modes[5]) / 6.0f,
          modes[7],
          (2.0f * (modes[0] + modes[4]) + modes[6] - 3.0f * modes[5]) / 6.0f,
          modes[8],
          modes[9],
          (modes[0] + modes[4] - modes[6]) / 3.0f};
}

/** Calculate hydrodynamic fields in LB units
 *  @param[in]  n_a     Local node residing in array a for boundary flag
 *  @param[in]  modes   Local register values modes
 *  @param[out] d_p_v   Local print values
 *  @param[out] d_v     Local device values
 *  @param[in]  node_f  Local node force
 *  @param[in]  index   Node index / thread index
 *  @param[in]  print_index  Node index / thread index
 *  TODO: code duplication with \ref calc_values_from_m
 */
__device__ void
calc_values_in_LB_units(LB_nodes_gpu n_a, Utils::Array<float, 19> const &modes,
                        LB_rho_v_pi_gpu *d_p_v, LB_rho_v_gpu *d_v,
                        LB_node_force_density_gpu node_f, unsigned int index,
                        unsigned int print_index) {

  if (n_a.boundary[index] == 0) {
    /* Ensure we are working with the current values of d_v */
    update_rho_v(modes, index, node_f, d_v);

    d_p_v[print_index].rho = d_v[index].rho;

    d_p_v[print_index].v = d_v[index].v;
    auto const modes_tmp = stress_modes(d_v[index], modes);

    d_p_v[print_index].pi = stress_from_stress_modes(modes_tmp);

  } else {
    d_p_v[print_index].rho = 0.0f;
    d_p_v[print_index].v = {};
    d_p_v[print_index].pi = {};
  }
}

/** Calculate hydrodynamic fields in MD units
 *  @param[out] mode_single   Local register values mode
 *  @param[in]  d_v_single    Local device values
 *  @param[out] rho_out       Density
 *  @param[out] j_out         Momentum
 *  @param[out] pi_out        Pressure tensor
 */
__device__ void calc_values_from_m(Utils::Array<float, 19> const &mode_single,
                                   LB_rho_v_gpu const &d_v_single,
                                   float *rho_out, float *j_out,
                                   Utils::Array<float, 6> &pi_out) {
  *rho_out = d_v_single.rho;
  float Rho = d_v_single.rho;
  j_out[0] = Rho * d_v_single.v[0];
  j_out[1] = Rho * d_v_single.v[1];
  j_out[2] = Rho * d_v_single.v[2];

  // Now we must predict the outcome of the next collision
  // We immediately average pre- and post-collision.
  // Transform the stress tensor components according to the mode_singles.
  pi_out = stress_from_stress_modes(stress_modes(d_v_single, mode_single));
}

/** Interpolation kernel.
 *  See @cite dunweg09a
 *  @param u Distance to grid point in units of agrid
 *  @retval Value for the interpolation function.
 */
__device__ __inline__ float
three_point_polynomial_smallerequal_than_half(float u) {
  return 1.f / 3.f * (1.f + sqrtf(1.f - 3.f * u * u));
}

/** Interpolation kernel.
 *  See @cite dunweg09a
 *  @param u Distance to grid point in units of agrid
 *  @retval Value for the interpolation function.
 */
__device__ __inline__ float three_point_polynomial_larger_than_half(float u) {
  return 1.f / 6.f *
         (5.f + -3 * fabsf(u) - sqrtf(-2.f + 6.f * fabsf(u) - 3.f * u * u));
}

/**
 * @brief Get velocity of at index.
 */
__device__ __inline__ float3 node_velocity(float rho_eq, LB_nodes_gpu n_a,
                                           unsigned index) {
  auto const boundary_index = n_a.boundary[index];

  if (boundary_index) {
    auto const inv_lattice_speed = para->tau / para->agrid;
    auto const &u = n_a.boundary_velocity[index];
    return make_float3(inv_lattice_speed * u[0], inv_lattice_speed * u[1],
                       inv_lattice_speed * u[2]);
  }

  auto const rho = rho_eq + calc_mode_x_from_n(n_a.populations[index], 0);
  return make_float3(calc_mode_x_from_n(n_a.populations[index], 1) / rho,
                     calc_mode_x_from_n(n_a.populations[index], 2) / rho,
                     calc_mode_x_from_n(n_a.populations[index], 3) / rho);
}

__device__ __inline__ float3
velocity_interpolation(LB_nodes_gpu n_a, float const *particle_position,
                       Utils::Array<unsigned int, 27> &node_indices,
                       Utils::Array<float, 27> &delta) {
  Utils::Array<int, 3> center_node_index{};
  Utils::Array<float3, 3> temp_delta{};

  for (unsigned i = 0; i < 3; ++i) {
    // position of particle in units of agrid.
    auto const scaled_pos = particle_position[i] / para->agrid - 0.5f;
    center_node_index[i] = static_cast<int>(rint(scaled_pos));
    // distance to center node in agrid
    auto const dist = scaled_pos - static_cast<float>(center_node_index[i]);
    // distance to left node in agrid
    auto const dist_m1 =
        scaled_pos - static_cast<float>(center_node_index[i] - 1);
    // distance to right node in agrid
    auto const dist_p1 =
        scaled_pos - static_cast<float>(center_node_index[i] + 1);
    if (i == 0) {
      temp_delta[0].x = three_point_polynomial_larger_than_half(dist_m1);
      temp_delta[1].x = three_point_polynomial_smallerequal_than_half(dist);
      temp_delta[2].x = three_point_polynomial_larger_than_half(dist_p1);
    } else if (i == 1) {
      temp_delta[0].y = three_point_polynomial_larger_than_half(dist_m1);
      temp_delta[1].y = three_point_polynomial_smallerequal_than_half(dist);
      temp_delta[2].y = three_point_polynomial_larger_than_half(dist_p1);
    } else if (i == 2) {
      temp_delta[0].z = three_point_polynomial_larger_than_half(dist_m1);
      temp_delta[1].z = three_point_polynomial_smallerequal_than_half(dist);
      temp_delta[2].z = three_point_polynomial_larger_than_half(dist_p1);
    }
  }

  auto fold_if_necessary = [](int ind, int dim) {
    if (ind >= dim) {
      return ind - dim;
    }
    if (ind < 0) {
      return ind + dim;
    }
    return ind;
  };

  unsigned cnt = 0;
  float3 interpolated_u{0.0f, 0.0f, 0.0f};
#pragma unroll 1
  for (int i = 0; i < 3; ++i) {
#pragma unroll 1
    for (int j = 0; j < 3; ++j) {
#pragma unroll 1
      for (int k = 0; k < 3; ++k) {
        auto const x = fold_if_necessary(center_node_index[0] - 1 + i,
                                         static_cast<int>(para->dim[0]));
        auto const y = fold_if_necessary(center_node_index[1] - 1 + j,
                                         static_cast<int>(para->dim[1]));
        auto const z = fold_if_necessary(center_node_index[2] - 1 + k,
                                         static_cast<int>(para->dim[2]));
        delta[cnt] = temp_delta[i].x * temp_delta[j].y * temp_delta[k].z;
        auto const index = static_cast<unsigned>(xyz_to_index(x, y, z));
        node_indices[cnt] = index;

        auto const node_u = node_velocity(para->rho, n_a, index);
        interpolated_u.x += delta[cnt] * node_u.x;
        interpolated_u.y += delta[cnt] * node_u.y;
        interpolated_u.z += delta[cnt] * node_u.z;

        ++cnt;
      }
    }
  }
  return interpolated_u;
}

/** Velocity interpolation.
 *  Eq. (12) @cite ahlrichs99a.
 *  @param[in]  n_a                Local node residing in array a
 *  @param[in]  particle_position  Particle position
 *  @param[out] node_index         Node index around (8) particle
 *  @param[out] delta              Weighting of particle position
 *  @retval Interpolated velocity
 */
__device__ __inline__ float3
velocity_interpolation(LB_nodes_gpu n_a, float const *particle_position,
                       Utils::Array<unsigned int, 8> &node_index,
                       Utils::Array<float, 8> &delta) {
  Utils::Array<int, 3> left_node_index;
  Utils::Array<float, 6> temp_delta;
  // Eq. (10) and (11) in @cite ahlrichs99a page 8227
#pragma unroll
  for (unsigned i = 0; i < 3; ++i) {
    auto const scaledpos = particle_position[i] / para->agrid - 0.5f;
    left_node_index[i] = static_cast<int>(floorf(scaledpos));
    temp_delta[3 + i] = scaledpos - static_cast<float>(left_node_index[i]);
    temp_delta[i] = 1.0f - temp_delta[3 + i];
  }

  delta[0] = temp_delta[0] * temp_delta[1] * temp_delta[2];
  delta[1] = temp_delta[3] * temp_delta[1] * temp_delta[2];
  delta[2] = temp_delta[0] * temp_delta[4] * temp_delta[2];
  delta[3] = temp_delta[3] * temp_delta[4] * temp_delta[2];
  delta[4] = temp_delta[0] * temp_delta[1] * temp_delta[5];
  delta[5] = temp_delta[3] * temp_delta[1] * temp_delta[5];
  delta[6] = temp_delta[0] * temp_delta[4] * temp_delta[5];
  delta[7] = temp_delta[3] * temp_delta[4] * temp_delta[5];

  // modulo for negative numbers is strange at best, shift to make sure we are
  // positive
  int const x = (left_node_index[0] + static_cast<int>(para->dim[0])) %
                static_cast<int>(para->dim[0]);
  int const y = (left_node_index[1] + static_cast<int>(para->dim[1])) %
                static_cast<int>(para->dim[1]);
  int const z = (left_node_index[2] + static_cast<int>(para->dim[2])) %
                static_cast<int>(para->dim[2]);
  auto fold_if_necessary = [](int ind, int dim) {
    return ind >= dim ? ind % dim : ind;
  };
  auto const xp1 = fold_if_necessary(x + 1, static_cast<int>(para->dim[0]));
  auto const yp1 = fold_if_necessary(y + 1, static_cast<int>(para->dim[1]));
  auto const zp1 = fold_if_necessary(z + 1, static_cast<int>(para->dim[2]));
  node_index[0] = static_cast<unsigned>(xyz_to_index(x, y, z));
  node_index[1] = static_cast<unsigned>(xyz_to_index(xp1, y, z));
  node_index[2] = static_cast<unsigned>(xyz_to_index(x, yp1, z));
  node_index[3] = static_cast<unsigned>(xyz_to_index(xp1, yp1, z));
  node_index[4] = static_cast<unsigned>(xyz_to_index(x, y, zp1));
  node_index[5] = static_cast<unsigned>(xyz_to_index(xp1, y, zp1));
  node_index[6] = static_cast<unsigned>(xyz_to_index(x, yp1, zp1));
  node_index[7] = static_cast<unsigned>(xyz_to_index(xp1, yp1, zp1));

  float3 interpolated_u{0.0f, 0.0f, 0.0f};
  for (unsigned i = 0; i < 8; ++i) {
    auto const node_u = node_velocity(para->rho, n_a, node_index[i]);
    interpolated_u.x += delta[i] * node_u.x;
    interpolated_u.y += delta[i] * node_u.y;
    interpolated_u.z += delta[i] * node_u.z;
  }
  return interpolated_u;
}

/** Calculate viscous force.
 *  Eq. (12) @cite ahlrichs99a.
 *  @param[in]  n_a                Local node residing in array a
 *  @param[out] delta              Weighting of particle position
 *  @param[out] delta_j            Weighting of particle momentum
 *  @param[in,out] particle_data   Particle position and velocity
 *  @param[in,out] particle_force  Particle force
 *  @param[in]  part_index         Particle id / thread id
 *  @param[out] node_index         Node index around (8) particle
 *  @param[in]  flag_cs            Determine if we are at the centre (0,
 *                                 typical) or at the source (1, swimmer only)
 *  @param[in]  philox_counter     Philox counter
 *  @param[in]  friction           Friction constant for the particle coupling
 *  @param[in]  time_step          MD time step
 *  @tparam no_of_neighbours       The number of neighbours to consider for
 *                                 interpolation
 */
template <std::size_t no_of_neighbours>
__device__ void calc_viscous_force(
    LB_nodes_gpu n_a, Utils::Array<float, no_of_neighbours> &delta,
    CUDA_particle_data *particle_data, float *particle_force,
    unsigned int part_index, float *delta_j,
    Utils::Array<unsigned int, no_of_neighbours> &node_index, bool flag_cs,
    uint64_t philox_counter, float friction, float time_step) {
  auto const flag_cs_float = static_cast<float>(flag_cs);
  // Zero out workspace
#pragma unroll
  for (int jj = 0; jj < 3; ++jj) {
    delta_j[jj] = 0.0f;
  }

  // Zero out only if we are at the centre of the particle <=> flag_cs = 0
  particle_force[3 * part_index + 0] =
      flag_cs_float * particle_force[3 * part_index + 0];
  particle_force[3 * part_index + 1] =
      flag_cs_float * particle_force[3 * part_index + 1];
  particle_force[3 * part_index + 2] =
      flag_cs_float * particle_force[3 * part_index + 2];

  float position[3];
  position[0] = particle_data[part_index].p[0];
  position[1] = particle_data[part_index].p[1];
  position[2] = particle_data[part_index].p[2];

  float velocity[3];
  velocity[0] = particle_data[part_index].v[0];
  velocity[1] = particle_data[part_index].v[1];
  velocity[2] = particle_data[part_index].v[2];

#ifdef ENGINE
  // First calculate interpolated velocity for dipole source,
  // such that we don't overwrite mode, etc. for the rest of the function
  float direction = float(particle_data[part_index].swim.push_pull) *
                    particle_data[part_index].swim.dipole_length;
  // Extrapolate position by dipole length if we are at the centre of the
  // particle
  position[0] +=
      flag_cs_float * direction * particle_data[part_index].swim.director[0];
  position[1] +=
      flag_cs_float * direction * particle_data[part_index].swim.director[1];
  position[2] +=
      flag_cs_float * direction * particle_data[part_index].swim.director[2];
#endif

  float3 const interpolated_u =
      velocity_interpolation(n_a, position, node_index, delta);

#ifdef ENGINE
  velocity[0] -= particle_data[part_index].swim.v_swim *
                 particle_data[part_index].swim.director[0];
  velocity[1] -= particle_data[part_index].swim.v_swim *
                 particle_data[part_index].swim.director[1];
  velocity[2] -= particle_data[part_index].swim.v_swim *
                 particle_data[part_index].swim.director[2];

  // The first three components are v_center, the last three v_source
  // Do not use within LB, because these have already been converted back to MD
  // units
  particle_data[part_index].swim.v_cs[0 + 3 * flag_cs] =
      interpolated_u.x * para->agrid / para->tau;
  particle_data[part_index].swim.v_cs[1 + 3 * flag_cs] =
      interpolated_u.y * para->agrid / para->tau;
  particle_data[part_index].swim.v_cs[2 + 3 * flag_cs] =
      interpolated_u.z * para->agrid / para->tau;
#endif

  /* take care to rescale velocities with time_step and transform to MD units
   * (eq. (9) @cite ahlrichs99a) */

  /* Viscous force */
  float3 viscforce_density{0.0f, 0.0f, 0.0f};
  viscforce_density.x -=
      friction * (velocity[0] - interpolated_u.x * para->agrid / para->tau);
  viscforce_density.y -=
      friction * (velocity[1] - interpolated_u.y * para->agrid / para->tau);
  viscforce_density.z -=
      friction * (velocity[2] - interpolated_u.z * para->agrid / para->tau);

#ifdef LB_ELECTROHYDRODYNAMICS
  viscforce_density.x += friction * particle_data[part_index].mu_E[0];
  viscforce_density.y += friction * particle_data[part_index].mu_E[1];
  viscforce_density.z += friction * particle_data[part_index].mu_E[2];
#endif

  if (para->kT > 0.0) {
    /* add stochastic force of zero mean (eq. (15) @cite ahlrichs99a) */
    float4 random_floats = random_wrapper_philox(
        static_cast<unsigned>(particle_data[part_index].identity), LBQ * 32,
        philox_counter);
    /* lb_coupl_pref is stored in MD units (force).
     * Eq. (16) @cite ahlrichs99a.
     * The factor 12 comes from the fact that we use random numbers
     * from -0.5 to 0.5 (equally distributed) which have variance 1/12.
     * time_step comes from the discretization.
     */
    float lb_coupl_pref = sqrtf(12.f * 2.f * friction * para->kT / time_step);
    viscforce_density.x += lb_coupl_pref * (random_floats.w - 0.5f);
    viscforce_density.y += lb_coupl_pref * (random_floats.x - 0.5f);
    viscforce_density.z += lb_coupl_pref * (random_floats.y - 0.5f);
  }
  /* delta_j for transform momentum transfer to lattice units which is done
     in calc_node_force (eq. (12) @cite ahlrichs99a) */

  // only add to particle_force for particle centre <=> (1-flag_cs) = 1
  particle_force[3 * part_index + 0] +=
      (1 - flag_cs_float) * viscforce_density.x;
  particle_force[3 * part_index + 1] +=
      (1 - flag_cs_float) * viscforce_density.y;
  particle_force[3 * part_index + 2] +=
      (1 - flag_cs_float) * viscforce_density.z;

  // only add to particle_force for particle centre <=> (1-flag_cs) = 1
  delta_j[0] -= ((1 - flag_cs_float) * viscforce_density.x) * time_step *
                para->tau / para->agrid;
  delta_j[1] -= ((1 - flag_cs_float) * viscforce_density.y) * time_step *
                para->tau / para->agrid;
  delta_j[2] -= ((1 - flag_cs_float) * viscforce_density.z) * time_step *
                para->tau / para->agrid;

#ifdef ENGINE
  // add swimming force to source position
  delta_j[0] -= flag_cs_float * particle_data[part_index].swim.f_swim *
                particle_data[part_index].swim.director[0] * time_step *
                para->tau / para->agrid;
  delta_j[1] -= flag_cs_float * particle_data[part_index].swim.f_swim *
                particle_data[part_index].swim.director[1] * time_step *
                para->tau / para->agrid;
  delta_j[2] -= flag_cs_float * particle_data[part_index].swim.f_swim *
                particle_data[part_index].swim.director[2] * time_step *
                para->tau / para->agrid;
#endif
}

/** Calculate the node force caused by the particles, with atomicAdd due to
 *  avoiding race conditions.
 *  Eq. (14) @cite ahlrichs99a.
 *  @param[in]  delta              Weighting of particle position
 *  @param[in]  delta_j            Weighting of particle momentum
 *  @param[in]  node_index         Node index around (8) particle
 *  @param[out] node_f             Node force
 *  @tparam no_of_neighbours       The number of neighbours to consider for
 *                                 interpolation
 */
template <std::size_t no_of_neighbours>
__device__ void
calc_node_force(Utils::Array<float, no_of_neighbours> const &delta,
                float const *delta_j,
                Utils::Array<unsigned int, no_of_neighbours> const &node_index,
                LB_node_force_density_gpu node_f) {
  for (std::size_t node = 0; node < no_of_neighbours; ++node) {
    for (unsigned i = 0; i < 3; ++i) {
      atomicAdd(&(node_f.force_density[node_index[node]][i]),
                delta[node] * delta_j[i]);
    }
  }
}

/*********************************************************/
/** \name System setup and Kernel functions */
/*********************************************************/

/** Kernel to calculate local populations from hydrodynamic fields.
 *  The mapping is given in terms of the equilibrium distribution.
 *
 *  Eq. (2.15) @cite ladd94a.
 *  Eq. (4) in @cite usta05a.
 *
 *  @param[out] n_a        %Lattice site
 *  @param[out] gpu_check  Additional check if GPU kernel are executed
 *  @param[out] d_v        Local device values
 *  @param[in]  node_f     Node forces
 */
__global__ void calc_n_from_rho_j_pi(LB_nodes_gpu n_a, LB_rho_v_gpu *d_v,
                                     LB_node_force_density_gpu node_f,
                                     bool *gpu_check) {
  /* TODO: this can handle only a uniform density, something similar, but local,
           has to be called every time the fields are set by the user ! */
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;
  if (index < para->number_of_nodes) {
    Utils::Array<float, 19> mode;

    gpu_check[0] = true;

    /* default values for fields in lattice units */
    float Rho = para->rho;
    Utils::Array<float, 3> v{};
    Utils::Array<float, 6> pi = {{Rho * D3Q19::c_sound_sq<float>, 0.0f,
                                  Rho * D3Q19::c_sound_sq<float>, 0.0f, 0.0f,
                                  Rho * D3Q19::c_sound_sq<float>}};
    Utils::Array<float, 6> local_pi{};
    float rhoc_sq = Rho * D3Q19::c_sound_sq<float>;
    float avg_rho = para->rho;
    float local_rho, trace;
    Utils::Array<float, 3> local_j{};

    local_rho = Rho;

    local_j[0] = Rho * v[0];
    local_j[1] = Rho * v[1];
    local_j[2] = Rho * v[2];

    local_pi = pi;

    // reduce the pressure tensor to the part needed here.

    local_pi[0] -= rhoc_sq;
    local_pi[2] -= rhoc_sq;
    local_pi[5] -= rhoc_sq;

    trace = local_pi[0] + local_pi[2] + local_pi[5];

    float rho_times_coeff;
    float tmp1, tmp2;

    /* update the q=0 sublattice */
    n_a.populations[index][0] =
        1.0f / 3.0f * (local_rho - avg_rho) - 1.0f / 2.0f * trace;

    /* update the q=1 sublattice */
    rho_times_coeff = 1.0f / 18.0f * (local_rho - avg_rho);

    n_a.populations[index][1] = rho_times_coeff + 1.0f / 6.0f * local_j[0] +
                                1.0f / 4.0f * local_pi[0] -
                                1.0f / 12.0f * trace;
    n_a.populations[index][2] = rho_times_coeff - 1.0f / 6.0f * local_j[0] +
                                1.0f / 4.0f * local_pi[0] -
                                1.0f / 12.0f * trace;
    n_a.populations[index][3] = rho_times_coeff + 1.0f / 6.0f * local_j[1] +
                                1.0f / 4.0f * local_pi[2] -
                                1.0f / 12.0f * trace;
    n_a.populations[index][4] = rho_times_coeff - 1.0f / 6.0f * local_j[1] +
                                1.0f / 4.0f * local_pi[2] -
                                1.0f / 12.0f * trace;
    n_a.populations[index][5] = rho_times_coeff + 1.0f / 6.0f * local_j[2] +
                                1.0f / 4.0f * local_pi[5] -
                                1.0f / 12.0f * trace;
    n_a.populations[index][6] = rho_times_coeff - 1.0f / 6.0f * local_j[2] +
                                1.0f / 4.0f * local_pi[5] -
                                1.0f / 12.0f * trace;

    /* update the q=2 sublattice */
    rho_times_coeff = 1.0f / 36.0f * (local_rho - avg_rho);

    tmp1 = local_pi[0] + local_pi[2];
    tmp2 = 2.0f * local_pi[1];
    n_a.populations[index][7] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] + local_j[1]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][8] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] + local_j[1]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][9] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] - local_j[1]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][10] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] - local_j[1]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    tmp1 = local_pi[0] + local_pi[5];
    tmp2 = 2.0f * local_pi[3];

    n_a.populations[index][11] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][12] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][13] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][14] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    tmp1 = local_pi[2] + local_pi[5];
    tmp2 = 2.0f * local_pi[4];

    n_a.populations[index][15] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[1] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][16] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[1] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][17] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[1] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[index][18] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[1] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    calc_m_from_n(n_a.populations[index], mode);
    update_rho_v(mode, index, node_f, d_v);
  }
}

__global__ void set_force_density(unsigned single_nodeindex,
                                  float const *force_density,
                                  LB_node_force_density_gpu node_f) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index == 0) {
    node_f.force_density[single_nodeindex][0] = force_density[0];
    node_f.force_density[single_nodeindex][1] = force_density[1];
    node_f.force_density[single_nodeindex][2] = force_density[2];
  }
}

/** Kernel to calculate local populations from hydrodynamic fields
 *  from given flow field velocities. The mapping is given in terms of
 *  the equilibrium distribution.
 *
 *  Eq. (2.15) @cite ladd94a.
 *  Eq. (4) in @cite usta05a.
 *
 *  @param[out] n_a               Current nodes array (double buffering!)
 *  @param[in]  single_nodeindex  Single node index
 *  @param[in]  velocity          Velocity
 *  @param[out] d_v               Local device values
 *  @param[in]  node_f            Node forces
 */
__global__ void set_u_from_rho_v_pi(LB_nodes_gpu n_a, unsigned single_nodeindex,
                                    float const *velocity, LB_rho_v_gpu *d_v,
                                    LB_node_force_density_gpu node_f) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index == 0) {
    float local_rho;
    float local_j[3];
    float local_pi[6];
    float trace, avg_rho;
    float rho_times_coeff;
    float tmp1, tmp2;

    Utils::Array<float, 19> mode_for_pi;
    float rho_from_m;
    float j_from_m[3];
    Utils::Array<float, 6> pi_from_m;

    // Calculate the modes for this node

    calc_m_from_n(n_a.populations[single_nodeindex], mode_for_pi);

    // Reset the d_v

    update_rho_v(mode_for_pi, single_nodeindex, node_f, d_v);

    // Calculate the density, velocity, and pressure tensor
    // in LB unit for this node

    calc_values_from_m(mode_for_pi, d_v[single_nodeindex], &rho_from_m,
                       j_from_m, pi_from_m);

    // Take LB component density and calculate the equilibrium part
    local_rho = rho_from_m;
    avg_rho = para->rho;

    // Take LB component velocity and make it a momentum

    local_j[0] = local_rho * velocity[0];
    local_j[1] = local_rho * velocity[1];
    local_j[2] = local_rho * velocity[2];
    // Take LB component pressure tensor and put in equilibrium

    local_pi[0] = pi_from_m[0];
    local_pi[1] = pi_from_m[1];
    local_pi[2] = pi_from_m[2];
    local_pi[3] = pi_from_m[3];
    local_pi[4] = pi_from_m[4];
    local_pi[5] = pi_from_m[5];

    trace = local_pi[0] + local_pi[2] + local_pi[5];

    // update the q=0 sublattice

    n_a.populations[single_nodeindex][0] =
        1.0f / 3.0f * (local_rho - avg_rho) - 1.0f / 2.0f * trace;

    // update the q=1 sublattice

    rho_times_coeff = 1.0f / 18.0f * (local_rho - avg_rho);

    n_a.populations[single_nodeindex][1] =
        rho_times_coeff + 1.0f / 6.0f * local_j[0] + 1.0f / 4.0f * local_pi[0] -
        1.0f / 12.0f * trace;
    n_a.populations[single_nodeindex][2] =
        rho_times_coeff - 1.0f / 6.0f * local_j[0] + 1.0f / 4.0f * local_pi[0] -
        1.0f / 12.0f * trace;
    n_a.populations[single_nodeindex][3] =
        rho_times_coeff + 1.0f / 6.0f * local_j[1] + 1.0f / 4.0f * local_pi[2] -
        1.0f / 12.0f * trace;
    n_a.populations[single_nodeindex][4] =
        rho_times_coeff - 1.0f / 6.0f * local_j[1] + 1.0f / 4.0f * local_pi[2] -
        1.0f / 12.0f * trace;
    n_a.populations[single_nodeindex][5] =
        rho_times_coeff + 1.0f / 6.0f * local_j[2] + 1.0f / 4.0f * local_pi[5] -
        1.0f / 12.0f * trace;
    n_a.populations[single_nodeindex][6] =
        rho_times_coeff - 1.0f / 6.0f * local_j[2] + 1.0f / 4.0f * local_pi[5] -
        1.0f / 12.0f * trace;

    // update the q=2 sublattice

    rho_times_coeff = 1.0f / 36.0f * (local_rho - avg_rho);

    tmp1 = local_pi[0] + local_pi[2];
    tmp2 = 2.0f * local_pi[1];

    n_a.populations[single_nodeindex][7] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] + local_j[1]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][8] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] + local_j[1]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][9] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] - local_j[1]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][10] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] - local_j[1]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    tmp1 = local_pi[0] + local_pi[5];
    tmp2 = 2.0f * local_pi[3];

    n_a.populations[single_nodeindex][11] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][12] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][13] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[0] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][14] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[0] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    tmp1 = local_pi[2] + local_pi[5];
    tmp2 = 2.0f * local_pi[4];

    n_a.populations[single_nodeindex][15] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[1] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][16] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[1] + local_j[2]) +
        1.0f / 8.0f * (tmp1 + tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][17] =
        rho_times_coeff + 1.0f / 12.0f * (local_j[1] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;
    n_a.populations[single_nodeindex][18] =
        rho_times_coeff - 1.0f / 12.0f * (local_j[1] - local_j[2]) +
        1.0f / 8.0f * (tmp1 - tmp2) - 1.0f / 24.0f * trace;

    // Calculate the modes for this node

    calc_m_from_n(n_a.populations[single_nodeindex], mode_for_pi);

    // Update the density and velocity field for this mode

    update_rho_v(mode_for_pi, single_nodeindex, node_f, d_v);
  }
}

/** Calculate the mass of the whole fluid kernel
 *  @param[out] sum  Resulting mass
 *  @param[in]  n_a  Local node residing in array a
 */
__global__ void calc_mass(LB_nodes_gpu n_a, float *sum) {

  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes) {
    Utils::Array<float, 4> mode;
    calc_mass_and_momentum_mode(mode, n_a, index);
    float Rho = mode[0] + para->rho;
    atomicAdd(&(sum[0]), Rho);
  }
}

/** (Re-)initialize the node force density / set the external force
 *  density in lb units
 *  @param[out] node_f  Local node force density
 */
__global__ void reinit_node_force(LB_node_force_density_gpu node_f) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes) {
    node_f.force_density[index][0] = para->ext_force_density[0];
    node_f.force_density[index][1] = para->ext_force_density[1];
    node_f.force_density[index][2] = para->ext_force_density[2];
  }
}

/** Kernel to set the local density
 *
 *  @param[out] n_a              Current nodes array (double buffering!)
 *  @param[in] single_nodeindex  Node to set the velocity for
 *  @param[in] rho               Density to set
 *  @param[in] d_v               Local modes
 */
__global__ void set_rho(LB_nodes_gpu n_a, LB_rho_v_gpu *d_v,
                        unsigned single_nodeindex, float rho) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;
  /* Note: this sets the velocities to zero */
  if (index == 0) {
    float local_rho;

    /* default values for fields in lattice units */
    local_rho = (rho - para->rho);
    d_v[single_nodeindex].rho = rho;

    n_a.populations[single_nodeindex][0] = 1.0f / 3.0f * local_rho;
    n_a.populations[single_nodeindex][1] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][2] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][3] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][4] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][5] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][6] = 1.0f / 18.0f * local_rho;
    n_a.populations[single_nodeindex][7] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][8] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][9] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][10] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][11] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][12] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][13] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][14] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][15] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][16] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][17] = 1.0f / 36.0f * local_rho;
    n_a.populations[single_nodeindex][18] = 1.0f / 36.0f * local_rho;
  }
}

/** Set the boundary flag for all boundary nodes
 *  @param[in]  boundary_node_list    Indices of the boundary nodes
 *  @param[in]  boundary_index_list   Flag for the corresponding boundary
 *  @param[in]  boundary_velocities   Boundary velocities
 *  @param[in]  number_of_boundnodes  Number of boundary nodes
 *  @param[in]  boundaries            Boundary information
 */
__global__ void init_boundaries(int const *boundary_node_list,
                                int const *boundary_index_list,
                                float const *boundary_velocities,
                                unsigned number_of_boundnodes,
                                LB_boundaries_gpu boundaries) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < number_of_boundnodes) {
    auto const node_index = boundary_node_list[index];
    auto const boundary_index = boundary_index_list[index];

    Utils::Array<float, 3> v = {
        boundary_velocities[3 * (boundary_index - 1) + 0],
        boundary_velocities[3 * (boundary_index - 1) + 1],
        boundary_velocities[3 * (boundary_index - 1) + 2]};

    boundaries.index[node_index] = static_cast<unsigned>(boundary_index);
    boundaries.velocity[node_index] = v;
  }
}

/** Reset the boundary flag of every node */
__global__ void reset_boundaries(LB_boundaries_gpu boundaries) {
  std::size_t index = blockIdx.y * gridDim.x * blockDim.x +
                      blockDim.x * blockIdx.x + threadIdx.x;
  if (index < para->number_of_nodes) {
    boundaries.index[index] = 0;
  }
}

/** Integration step of the LB-fluid-solver
 *  @param[in]     n_a     Local node residing in array a
 *  @param[out]    n_b     Local node residing in array b
 *  @param[in,out] d_v     Local device values
 *  @param[in,out] node_f  Local node force density
 *  @param[in]     philox_counter  Philox counter
 */
__global__ void integrate(LB_nodes_gpu n_a, LB_nodes_gpu n_b, LB_rho_v_gpu *d_v,
                          LB_node_force_density_gpu node_f,
                          uint64_t philox_counter) {
  /* every node is connected to a thread via the index */
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;
  /* the 19 moments (modes) are only temporary register values */
  Utils::Array<float, 19> mode;

  if (index < para->number_of_nodes) {
    calc_m_from_n(n_a.populations[index], mode);
    relax_modes(mode, index, node_f, d_v);
    thermalize_modes(mode, index, philox_counter);
    apply_forces(index, mode, node_f, d_v);
    normalize_modes(mode);
    calc_n_from_modes_push(n_b, mode, index);
  }
}

/** Integration step of the LB-fluid-solver
 *  @param[in]     n_a     Local node residing in array a
 *  @param[out]    n_b     Local node residing in array b
 *  @param[in,out] d_v     Local device values
 *  @param[in,out] node_f  Local node force density
 */
__global__ void integrate(LB_nodes_gpu n_a, LB_nodes_gpu n_b, LB_rho_v_gpu *d_v,
                          LB_node_force_density_gpu node_f) {
  /* every node is connected to a thread via the index */
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;
  /* the 19 moments (modes) are only temporary register values */
  Utils::Array<float, 19> mode;

  if (index < para->number_of_nodes) {
    calc_m_from_n(n_a.populations[index], mode);
    relax_modes(mode, index, node_f, d_v);
    apply_forces(index, mode, node_f, d_v);
    normalize_modes(mode);
    calc_n_from_modes_push(n_b, mode, index);
  }
}

/** Particle interaction kernel
 *  @param[in]  n_a                 Local node residing in array a
 *  @param[in,out]  particle_data   Particle position and velocity
 *  @param[in,out]  particle_force  Particle force
 *  @param[out] node_f              Local node force
 *  @param[in]  couple_virtual      If true, virtual particles are also coupled
 *  @param[in]  philox_counter      Philox counter
 *  @param[in]  friction            Friction constant for the particle coupling
 *  @param[in]  time_step           MD time step
 *  @tparam     no_of_neighbours    The number of neighbours to consider for
 *                                  interpolation
 */
template <std::size_t no_of_neighbours>
__global__ void
calc_fluid_particle_ia(LB_nodes_gpu n_a,
                       Utils::Span<CUDA_particle_data> particle_data,
                       float *particle_force, LB_node_force_density_gpu node_f,
                       bool couple_virtual, uint64_t philox_counter,
                       float friction, float time_step) {

  unsigned int part_index = blockIdx.y * gridDim.x * blockDim.x +
                            blockDim.x * blockIdx.x + threadIdx.x;
  Utils::Array<unsigned int, no_of_neighbours> node_index;
  Utils::Array<float, no_of_neighbours> delta;
  float delta_j[3];
  if (part_index < particle_data.size()) {
#if defined(VIRTUAL_SITES)
    if (!particle_data[part_index].is_virtual || couple_virtual)
#endif
    {
      /* force acting on the particle. delta_j will be used later to compute the
       * force that acts back onto the fluid. */
      calc_viscous_force<no_of_neighbours>(
          n_a, delta, particle_data.data(), particle_force, part_index, delta_j,
          node_index, false, philox_counter, friction, time_step);
      calc_node_force<no_of_neighbours>(delta, delta_j, node_index, node_f);

#ifdef ENGINE
      if (particle_data[part_index].swim.swimming) {
        calc_viscous_force<no_of_neighbours>(
            n_a, delta, particle_data.data(), particle_force, part_index,
            delta_j, node_index, true, philox_counter, friction, time_step);
        calc_node_force<no_of_neighbours>(delta, delta_j, node_index, node_f);
      }
#endif
    }
  }
}

#ifdef LB_BOUNDARIES_GPU
/** Bounce back boundary kernel
 *  @param[in]  n_curr  Pointer to local node receiving the current node field
 *  @param[in]  boundaries  Constant velocity at the boundary, set by the user
 *  @param[out] lb_boundary_force     Force on the boundary nodes
 */
__global__ void apply_boundaries(LB_nodes_gpu n_curr,
                                 LB_boundaries_gpu boundaries,
                                 float *lb_boundary_force) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes)
    bounce_back_boundaries(n_curr, boundaries, index, lb_boundary_force);
}

#endif

/** Get physical values of the nodes (density, velocity, ...)
 *  @param[in]  n_a     Local node residing in array a
 *  @param[out] p_v     Local print values
 *  @param[out] d_v     Local device values
 *  @param[in]  node_f  Local node force
 */
__global__ void
get_mesoscopic_values_in_LB_units(LB_nodes_gpu n_a, LB_rho_v_pi_gpu *p_v,
                                  LB_rho_v_gpu *d_v,
                                  LB_node_force_density_gpu node_f) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes) {
    Utils::Array<float, 19> mode;
    calc_m_from_n(n_a.populations[index], mode);
    calc_values_in_LB_units(n_a, mode, p_v, d_v, node_f, index, index);
  }
}

/** Get boundary flags
 *  @param[in]  n_a                 Local node residing in array a
 *  @param[out] device_bound_array  Local device values
 */
__global__ void lb_get_boundaries(LB_nodes_gpu n_a,
                                  unsigned int *device_bound_array) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes)
    device_bound_array[index] = n_a.boundary[index];
}

/** Print single node values kernel
 *  @param[in]  single_nodeindex  Node index
 *  @param[out] d_p_v   Result
 *  @param[in]  n_a     Local node residing in array a
 *  @param[out] d_v     Local device values
 *  @param[in]  node_f  Local node force
 */
__global__ void lb_print_node(unsigned int single_nodeindex,
                              LB_rho_v_pi_gpu *d_p_v, LB_nodes_gpu n_a,
                              LB_rho_v_gpu *d_v,
                              LB_node_force_density_gpu node_f) {
  Utils::Array<float, 19> mode;
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index == 0) {
    calc_m_from_n(n_a.populations[single_nodeindex], mode);

    /* the following actually copies rho and v from d_v, and calculates pi */
    calc_values_in_LB_units(n_a, mode, d_p_v, d_v, node_f, single_nodeindex, 0);
  }
}

__global__ void momentum(LB_nodes_gpu n_a, LB_node_force_density_gpu node_f,
                         float *sum) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index < para->number_of_nodes) {
    float j[3] = {0.0f, 0.0f, 0.0f};
    Utils::Array<float, 4> mode{};

    calc_mass_and_momentum_mode(mode, n_a, index);

    j[0] += mode[1] + 0.5f * node_f.force_density[index][0];
    j[1] += mode[2] + 0.5f * node_f.force_density[index][1];
    j[2] += mode[3] + 0.5f * node_f.force_density[index][2];

#ifdef LB_BOUNDARIES_GPU
    if (n_a.boundary[index])
      j[0] = j[1] = j[2] = 0.0f;
#endif

    atomicAdd(&(sum[0]), j[0]);
    atomicAdd(&(sum[1]), j[1]);
    atomicAdd(&(sum[2]), j[2]);
  }
}

/** Print single node boundary flag
 *  @param[in]  single_nodeindex  Node index
 *  @param[out] device_flag       Result
 *  @param[in]  n_a               Local node residing in array a
 */
__global__ void lb_get_boundary_flag(unsigned int single_nodeindex,
                                     unsigned int *device_flag,
                                     LB_nodes_gpu n_a) {
  unsigned int index = blockIdx.y * gridDim.x * blockDim.x +
                       blockDim.x * blockIdx.x + threadIdx.x;

  if (index == 0)
    device_flag[0] = n_a.boundary[single_nodeindex];
}

/**********************************************************************/
/* Host functions to setup and call kernels*/
/**********************************************************************/

void lb_get_para_pointer(LB_parameters_gpu **pointer_address) {
  auto const error = cudaGetSymbolAddress((void **)pointer_address, para);
  if (error != cudaSuccess) {
    fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(error));
    errexit();
  }
}

void lb_get_boundary_force_pointer(float **pointer_address) {
#ifdef LB_BOUNDARIES_GPU
  *pointer_address = lb_boundary_force;
#endif
}

/** Initialization for the lb gpu fluid called from host
 *  @param lbpar_gpu   Pointer to parameters to setup the lb field
 */
void lb_init_GPU(const LB_parameters_gpu &lbpar_gpu) {
#define free_realloc_and_clear(var, size)                                      \
  {                                                                            \
    if ((var) != nullptr)                                                      \
      cuda_safe_mem(cudaFree((var)));                                          \
    cuda_safe_mem(cudaMalloc((void **)&(var), size));                          \
    cudaMemset(var, 0, size);                                                  \
  }

  /* Allocate structs in device memory*/
  free_realloc_and_clear(device_rho_v,
                         lbpar_gpu.number_of_nodes * sizeof(LB_rho_v_gpu));

  /* TODO: this is almost a copy of device_rho_v; think about eliminating
   * it, and maybe pi can be added to device_rho_v in this case */
  free_realloc_and_clear(print_rho_v_pi,
                         lbpar_gpu.number_of_nodes * sizeof(LB_rho_v_pi_gpu));
  free_realloc_and_clear(nodes_a.populations,
                         lbpar_gpu.number_of_nodes *
                             sizeof(Utils::Array<float, 19>));
  free_realloc_and_clear(nodes_b.populations,
                         lbpar_gpu.number_of_nodes *
                             sizeof(Utils::Array<float, 19>));
  free_realloc_and_clear(node_f.force_density,
                         lbpar_gpu.number_of_nodes *
                             sizeof(Utils::Array<float, 3>));
#if defined(VIRTUAL_SITES_INERTIALESS_TRACERS) || defined(EK_DEBUG)
  free_realloc_and_clear(node_f.force_density_buf,
                         lbpar_gpu.number_of_nodes *
                             sizeof(Utils::Array<float, 3>));
#endif
  free_realloc_and_clear(boundaries.index,
                         lbpar_gpu.number_of_nodes * sizeof(unsigned int));
  free_realloc_and_clear(boundaries.velocity,
                         lbpar_gpu.number_of_nodes *
                             sizeof(Utils::Array<float, 3>));

  nodes_a.boundary = nodes_b.boundary = boundaries.index;
  nodes_a.boundary_velocity = nodes_b.boundary_velocity = boundaries.velocity;

  /* write parameters in const memory */
  cuda_safe_mem(
      cudaMemcpyToSymbol(para, &lbpar_gpu, sizeof(LB_parameters_gpu)));

  free_realloc_and_clear(device_gpu_lb_initialized, sizeof(bool));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(reset_boundaries, dim_grid, threads_per_block, boundaries);

  /* calc of velocity densities from given parameters and initialize the
   * Node_Force array with zero */
  KERNELCALL(reinit_node_force, dim_grid, threads_per_block, (node_f));
  KERNELCALL(calc_n_from_rho_j_pi, dim_grid, threads_per_block, nodes_a,
             device_rho_v, node_f, device_gpu_lb_initialized);

  intflag = true;
  current_nodes = &nodes_a;
  bool host_gpu_lb_initialized = false;
  cuda_safe_mem(cudaMemcpy(&host_gpu_lb_initialized, device_gpu_lb_initialized,
                           sizeof(bool), cudaMemcpyDeviceToHost));
  cudaDeviceSynchronize();

  if (!host_gpu_lb_initialized) {
    fprintf(stderr, "initialization of LB GPU code failed!\n");
    errexit();
  }
}

/** Reinitialization for the lb gpu fluid called from host
 *  @param lbpar_gpu   Pointer to parameters to setup the lb field
 */
void lb_reinit_GPU(LB_parameters_gpu *lbpar_gpu) {
  /* write parameters in const memory */
  cuda_safe_mem(cudaMemcpyToSymbol(para, lbpar_gpu, sizeof(LB_parameters_gpu)));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu->number_of_nodes, 4, threads_per_block);

  /* calc of velocity densities from given parameters and initialize the
   * Node_Force array with zero */
  KERNELCALL(calc_n_from_rho_j_pi, dim_grid, threads_per_block, nodes_a,
             device_rho_v, node_f, device_gpu_lb_initialized);
}

#ifdef LB_BOUNDARIES_GPU
/** Setup and call boundaries from the host
 *  @param host_n_lb_boundaries        Number of LB boundaries
 *  @param number_of_boundnodes        Number of boundnodes
 *  @param host_boundary_node_list     The indices of the boundary nodes
 *  @param host_boundary_index_list    The flag representing the corresponding
 *                                     boundary
 *  @param host_lb_boundary_velocity   The constant velocity at the boundary,
 *                                     set by the user
 */
void lb_init_boundaries_GPU(std::size_t host_n_lb_boundaries,
                            unsigned number_of_boundnodes,
                            int *host_boundary_node_list,
                            int *host_boundary_index_list,
                            float *host_lb_boundary_velocity) {

  float *boundary_velocity = nullptr;
  int *boundary_node_list = nullptr;
  int *boundary_index_list = nullptr;

  auto const size_of_boundindex = number_of_boundnodes * sizeof(int);
  cuda_safe_mem(cudaMalloc((void **)&boundary_node_list, size_of_boundindex));
  cuda_safe_mem(cudaMalloc((void **)&boundary_index_list, size_of_boundindex));
  cuda_safe_mem(cudaMemcpy(boundary_index_list, host_boundary_index_list,
                           size_of_boundindex, cudaMemcpyHostToDevice));
  cuda_safe_mem(cudaMemcpy(boundary_node_list, host_boundary_node_list,
                           size_of_boundindex, cudaMemcpyHostToDevice));
  cuda_safe_mem(cudaMalloc((void **)&lb_boundary_force,
                           3 * host_n_lb_boundaries * sizeof(float)));
  cuda_safe_mem(cudaMalloc((void **)&boundary_velocity,
                           3 * host_n_lb_boundaries * sizeof(float)));
  cuda_safe_mem(
      cudaMemcpy(boundary_velocity, host_lb_boundary_velocity,
                 3 * LBBoundaries::lbboundaries.size() * sizeof(float),
                 cudaMemcpyHostToDevice));

  /* values for the kernel call */
  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(reset_boundaries, dim_grid, threads_per_block, boundaries);

  if (LBBoundaries::lbboundaries.empty()) {
    cudaDeviceSynchronize();
    return;
  }

  if (number_of_boundnodes == 0) {
    fprintf(stderr,
            "WARNING: boundary cmd executed but no boundary node found!\n");
  } else {
    dim3 dim_grid_bound =
        calculate_dim_grid(number_of_boundnodes, 4, threads_per_block);

    KERNELCALL(init_boundaries, dim_grid_bound, threads_per_block,
               boundary_node_list, boundary_index_list, boundary_velocity,
               number_of_boundnodes, boundaries);
  }

  cudaFree(boundary_velocity);
  cudaFree(boundary_node_list);
  cudaFree(boundary_index_list);

  cudaDeviceSynchronize();
}
#endif
/** Setup and call extern single node force initialization from the host
 *  @param lbpar_gpu    Host parameter struct
 */
void lb_reinit_extern_nodeforce_GPU(LB_parameters_gpu *lbpar_gpu) {
  cuda_safe_mem(cudaMemcpyToSymbol(para, lbpar_gpu, sizeof(LB_parameters_gpu)));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu->number_of_nodes, 4, threads_per_block);

  KERNELCALL(reinit_node_force, dim_grid, threads_per_block, node_f);
}

/** Setup and call particle kernel from the host
 *  @tparam no_of_neighbours       The number of neighbours to consider for
 *                                 interpolation
 */
template <std::size_t no_of_neighbours>
void lb_calc_particle_lattice_ia_gpu(bool couple_virtual, double friction,
                                     double time_step) {
  auto device_particles = gpu_get_particle_pointer();

  if (device_particles.empty()) {
    return;
  }

  dim3 dim_grid = calculate_dim_grid(
      static_cast<unsigned>(device_particles.size()), 4, threads_per_block);
  if (lbpar_gpu.kT > 0.f) {
    assert(rng_counter_coupling_gpu);
    KERNELCALL(calc_fluid_particle_ia<no_of_neighbours>, dim_grid,
               threads_per_block, *current_nodes, device_particles,
               gpu_get_particle_force_pointer(), node_f, couple_virtual,
               rng_counter_coupling_gpu->value(), static_cast<float>(friction),
               static_cast<float>(time_step));
  } else {
    // We use a dummy value for the RNG counter if no temperature is set.
    KERNELCALL(calc_fluid_particle_ia<no_of_neighbours>, dim_grid,
               threads_per_block, *current_nodes, device_particles,
               gpu_get_particle_force_pointer(), node_f, couple_virtual, 0,
               static_cast<float>(friction), static_cast<float>(time_step));
  }
}
template void lb_calc_particle_lattice_ia_gpu<8>(bool couple_virtual,
                                                 double friction,
                                                 double time_step);
template void lb_calc_particle_lattice_ia_gpu<27>(bool couple_virtual,
                                                  double friction,
                                                  double time_step);

/** Setup and call kernel for getting macroscopic fluid values of all nodes
 *  @param host_values   struct to save the gpu values
 */
void lb_get_values_GPU(LB_rho_v_pi_gpu *host_values) {
  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(get_mesoscopic_values_in_LB_units, dim_grid, threads_per_block,
             *current_nodes, print_rho_v_pi, device_rho_v, node_f);
  cuda_safe_mem(cudaMemcpy(host_values, print_rho_v_pi,
                           lbpar_gpu.number_of_nodes * sizeof(LB_rho_v_pi_gpu),
                           cudaMemcpyDeviceToHost));
}

/** Get all the boundary flags for all nodes
 *  @param host_bound_array   here go the values of the boundary flag
 */
void lb_get_boundary_flags_GPU(unsigned int *host_bound_array) {
  unsigned int *device_bound_array;
  cuda_safe_mem(cudaMalloc((void **)&device_bound_array,
                           lbpar_gpu.number_of_nodes * sizeof(unsigned int)));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(lb_get_boundaries, dim_grid, threads_per_block, *current_nodes,
             device_bound_array);

  cuda_safe_mem(cudaMemcpy(host_bound_array, device_bound_array,
                           lbpar_gpu.number_of_nodes * sizeof(unsigned int),
                           cudaMemcpyDeviceToHost));

  cudaFree(device_bound_array);
}

/** Setup and call kernel for getting macroscopic fluid values of a single
 *  node
 */
void lb_print_node_GPU(unsigned single_nodeindex,
                       LB_rho_v_pi_gpu *host_print_values) {
  LB_rho_v_pi_gpu *device_print_values;
  cuda_safe_mem(
      cudaMalloc((void **)&device_print_values, sizeof(LB_rho_v_pi_gpu)));
  unsigned threads_per_block_print = 1;
  unsigned blocks_per_grid_print_y = 1;
  unsigned blocks_per_grid_print_x = 1;
  dim3 dim_grid_print =
      make_uint3(blocks_per_grid_print_x, blocks_per_grid_print_y, 1);

  KERNELCALL(lb_print_node, dim_grid_print, threads_per_block_print,
             single_nodeindex, device_print_values, *current_nodes,
             device_rho_v, node_f);

  cuda_safe_mem(cudaMemcpy(host_print_values, device_print_values,
                           sizeof(LB_rho_v_pi_gpu), cudaMemcpyDeviceToHost));
  cudaFree(device_print_values);
}

/** Setup and call kernel to calculate the total momentum of the hole fluid
 *  @param mass   value of the mass calculated on the GPU
 */
void lb_calc_fluid_mass_GPU(double *mass) {
  float *tot_mass;
  float cpu_mass = 0.0f;
  cuda_safe_mem(cudaMalloc((void **)&tot_mass, sizeof(float)));
  cuda_safe_mem(
      cudaMemcpy(tot_mass, &cpu_mass, sizeof(float), cudaMemcpyHostToDevice));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(calc_mass, dim_grid, threads_per_block, *current_nodes, tot_mass);

  cuda_safe_mem(
      cudaMemcpy(&cpu_mass, tot_mass, sizeof(float), cudaMemcpyDeviceToHost));

  cudaFree(tot_mass);
  mass[0] = (double)(cpu_mass);
}

/** Setup and call kernel to calculate the total momentum of the whole fluid
 *  @param host_mom   value of the momentum calculated on the GPU
 */
void lb_calc_fluid_momentum_GPU(double *host_mom) {
  float *tot_momentum;
  float host_momentum[3] = {0.0f, 0.0f, 0.0f};
  cuda_safe_mem(cudaMalloc((void **)&tot_momentum, 3 * sizeof(float)));
  cuda_safe_mem(cudaMemcpy(tot_momentum, host_momentum, 3 * sizeof(float),
                           cudaMemcpyHostToDevice));

  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);

  KERNELCALL(momentum, dim_grid, threads_per_block, *current_nodes, node_f,
             tot_momentum);

  cuda_safe_mem(cudaMemcpy(host_momentum, tot_momentum, 3 * sizeof(float),
                           cudaMemcpyDeviceToHost));

  cudaFree(tot_momentum);
  auto const lattice_speed = lbpar_gpu.agrid / lbpar_gpu.tau;
  host_mom[0] = static_cast<double>(host_momentum[0] * lattice_speed);
  host_mom[1] = static_cast<double>(host_momentum[1] * lattice_speed);
  host_mom[2] = static_cast<double>(host_momentum[2] * lattice_speed);
}

/** Setup and call kernel for getting macroscopic fluid values of all nodes
 *  @param[out] host_checkpoint_vd   LB populations
 */
void lb_save_checkpoint_GPU(float *const host_checkpoint_vd) {
  cuda_safe_mem(cudaMemcpy(host_checkpoint_vd, current_nodes->populations,
                           lbpar_gpu.number_of_nodes * 19 * sizeof(float),
                           cudaMemcpyDeviceToHost));
}

/** Setup and call kernel for getting macroscopic fluid values of all nodes
 *  @param[in] host_checkpoint_vd    LB populations
 */
void lb_load_checkpoint_GPU(float const *const host_checkpoint_vd) {
  current_nodes = &nodes_a;
  intflag = true;

  cuda_safe_mem(
      cudaMemcpy(current_nodes->populations, host_checkpoint_vd,
                 lbpar_gpu.number_of_nodes * sizeof(Utils::Array<float, 19>),
                 cudaMemcpyHostToDevice));
}

/** Setup and call kernel to get the boundary flag of a single node
 *  @param single_nodeindex   number of the node to get the flag for
 *  @param host_flag          here goes the value of the boundary flag
 */
void lb_get_boundary_flag_GPU(unsigned int single_nodeindex,
                              unsigned int *host_flag) {
  unsigned int *device_flag;
  cuda_safe_mem(cudaMalloc((void **)&device_flag, sizeof(unsigned int)));
  unsigned threads_per_block_flag = 1;
  unsigned blocks_per_grid_flag_y = 1;
  unsigned blocks_per_grid_flag_x = 1;
  dim3 dim_grid_flag =
      make_uint3(blocks_per_grid_flag_x, blocks_per_grid_flag_y, 1);

  KERNELCALL(lb_get_boundary_flag, dim_grid_flag, threads_per_block_flag,
             single_nodeindex, device_flag, *current_nodes);

  cuda_safe_mem(cudaMemcpy(host_flag, device_flag, sizeof(unsigned int),
                           cudaMemcpyDeviceToHost));

  cudaFree(device_flag);
}

/** Set the density at a single node
 *  @param single_nodeindex   the node to set the velocity for
 *  @param host_rho           the density to set
 */
void lb_set_node_rho_GPU(unsigned single_nodeindex, float host_rho) {
  unsigned threads_per_block_flag = 1;
  unsigned blocks_per_grid_flag_y = 1;
  unsigned blocks_per_grid_flag_x = 1;
  dim3 dim_grid_flag =
      make_uint3(blocks_per_grid_flag_x, blocks_per_grid_flag_y, 1);
  KERNELCALL(set_rho, dim_grid_flag, threads_per_block_flag, *current_nodes,
             device_rho_v, single_nodeindex, host_rho);
}

/** Set the net velocity at a single node
 *  @param single_nodeindex   the node to set the velocity for
 *  @param host_velocity      the velocity to set
 */
void lb_set_node_velocity_GPU(unsigned single_nodeindex, float *host_velocity) {
  float *device_velocity;
  cuda_safe_mem(cudaMalloc((void **)&device_velocity, 3 * sizeof(float)));
  cuda_safe_mem(cudaMemcpy(device_velocity, host_velocity, 3 * sizeof(float),
                           cudaMemcpyHostToDevice));
  unsigned threads_per_block_flag = 1;
  unsigned blocks_per_grid_flag_y = 1;
  unsigned blocks_per_grid_flag_x = 1;
  dim3 dim_grid_flag =
      make_uint3(blocks_per_grid_flag_x, blocks_per_grid_flag_y, 1);

  KERNELCALL(set_u_from_rho_v_pi, dim_grid_flag, threads_per_block_flag,
             *current_nodes, single_nodeindex, device_velocity, device_rho_v,
             node_f);
  float force_density[3] = {0.0f, 0.0f, 0.0f};
  float *device_force_density;
  cuda_safe_mem(cudaMalloc((void **)&device_force_density, 3 * sizeof(float)));
  cuda_safe_mem(cudaMemcpy(device_force_density, force_density,
                           3 * sizeof(float), cudaMemcpyHostToDevice));
  KERNELCALL(set_force_density, dim_grid_flag, threads_per_block_flag,
             single_nodeindex, device_force_density, node_f);
  cudaFree(device_velocity);
  cudaFree(device_force_density);
}

/** Reinitialize parameters
 *  @param lbpar_gpu   struct containing the parameters of the fluid
 */
void reinit_parameters_GPU(LB_parameters_gpu *lbpar_gpu) {
  /* write parameters in const memory */
  cuda_safe_mem(cudaMemcpyToSymbol(para, lbpar_gpu, sizeof(LB_parameters_gpu)));
}

/** Integration kernel for the lb gpu fluid update called from host */
void lb_integrate_GPU() {
  dim3 dim_grid =
      calculate_dim_grid(lbpar_gpu.number_of_nodes, 4, threads_per_block);
#ifdef LB_BOUNDARIES_GPU
  if (!LBBoundaries::lbboundaries.empty()) {
    cuda_safe_mem(
        cudaMemset(lb_boundary_force, 0,
                   3 * LBBoundaries::lbboundaries.size() * sizeof(float)));
  }
#endif

  /* call of fluid step */
  if (intflag) {
    if (lbpar_gpu.kT > 0.0) {
      assert(rng_counter_fluid_gpu);
      KERNELCALL(integrate, dim_grid, threads_per_block, nodes_a, nodes_b,
                 device_rho_v, node_f, rng_counter_fluid_gpu->value());
    } else {
      KERNELCALL(integrate, dim_grid, threads_per_block, nodes_a, nodes_b,
                 device_rho_v, node_f);
    }
    current_nodes = &nodes_b;
    intflag = false;
  } else {
    if (lbpar_gpu.kT > 0.0) {
      assert(rng_counter_fluid_gpu);
      KERNELCALL(integrate, dim_grid, threads_per_block, nodes_b, nodes_a,
                 device_rho_v, node_f, rng_counter_fluid_gpu->value());
    } else {
      KERNELCALL(integrate, dim_grid, threads_per_block, nodes_b, nodes_a,
                 device_rho_v, node_f);
    }
    current_nodes = &nodes_a;
    intflag = true;
  }

#ifdef LB_BOUNDARIES_GPU
  if (!LBBoundaries::lbboundaries.empty()) {
    KERNELCALL(apply_boundaries, dim_grid, threads_per_block, *current_nodes,
               boundaries, lb_boundary_force);
  }
#endif
}

void lb_gpu_get_boundary_forces(std::vector<double> &forces) {
#ifdef LB_BOUNDARIES_GPU
  std::vector<float> temp(3 * LBBoundaries::lbboundaries.size());
  cuda_safe_mem(cudaMemcpy(temp.data(), lb_boundary_force,
                           temp.size() * sizeof(float),
                           cudaMemcpyDeviceToHost));
  std::transform(temp.begin(), temp.end(), forces.begin(),
                 [](float val) { return -static_cast<double>(val); });
#endif
}

struct lb_lbfluid_mass_of_particle {
  __host__ __device__ float operator()(CUDA_particle_data particle) const {
#ifdef MASS
    return particle.mass;
#else
    return 1.f;
#endif
  }
};

/** Set the populations of a specific node on the GPU
 *  @param[out] n_a         Local node residing in array a
 *  @param[in]  population  New population
 *  @param[in]  x           x-coordinate of node
 *  @param[in]  y           y-coordinate of node
 *  @param[in]  z           z-coordinate of node
 */
__global__ void lb_lbfluid_set_population_kernel(LB_nodes_gpu n_a,
                                                 float const population[LBQ],
                                                 int x, int y, int z) {
  auto const index = static_cast<unsigned>(xyz_to_index(x, y, z));

  for (unsigned i = 0; i < LBQ; ++i) {
    n_a.populations[index][i] = population[i];
  }
}

/** Interface to set the populations of a specific node for the GPU
 *  @param[in] xyz              Node coordinates
 *  @param[in] population_host  Population
 */
void lb_lbfluid_set_population(const Utils::Vector3i &xyz,
                               float population_host[LBQ]) {
  float *population_device;
  cuda_safe_mem(cudaMalloc((void **)&population_device, LBQ * sizeof(float)));
  cuda_safe_mem(cudaMemcpy(population_device, population_host,
                           LBQ * sizeof(float), cudaMemcpyHostToDevice));

  dim3 dim_grid = make_uint3(1, 1, 1);
  KERNELCALL(lb_lbfluid_set_population_kernel, dim_grid, 1, *current_nodes,
             population_device, xyz[0], xyz[1], xyz[2]);

  cuda_safe_mem(cudaFree(population_device));
}

/** Get the populations of a specific node on the GPU
 *  @param[in]  n_a         Local node residing in array a
 *  @param[out] population  Population
 *  @param[in]  x           x-coordinate of node
 *  @param[in]  y           y-coordinate of node
 *  @param[in]  z           z-coordinate of node
 */
__global__ void lb_lbfluid_get_population_kernel(LB_nodes_gpu n_a,
                                                 float population[LBQ], int x,
                                                 int y, int z) {
  auto const index = static_cast<unsigned>(xyz_to_index(x, y, z));

  for (unsigned i = 0; i < LBQ; ++i) {
    population[i] = n_a.populations[index][i];
  }
}

/** Interface to get the populations of a specific node for the GPU
 *  @param[in]  xyz              Node coordinates
 *  @param[out] population_host  Population
 */
void lb_lbfluid_get_population(const Utils::Vector3i &xyz,
                               float population_host[LBQ]) {
  float *population_device;
  cuda_safe_mem(cudaMalloc((void **)&population_device, LBQ * sizeof(float)));

  dim3 dim_grid = make_uint3(1, 1, 1);
  KERNELCALL(lb_lbfluid_get_population_kernel, dim_grid, 1, *current_nodes,
             population_device, xyz[0], xyz[1], xyz[2]);

  cuda_safe_mem(cudaMemcpy(population_host, population_device,
                           LBQ * sizeof(float), cudaMemcpyDeviceToHost));

  cuda_safe_mem(cudaFree(population_device));
}

/**
 * @brief Velocity interpolation functor
 * @tparam no_of_neighbours     The number of neighbours to consider for
 *                              interpolation
 */
template <std::size_t no_of_neighbours> struct interpolation {
  LB_nodes_gpu current_nodes_gpu;
  LB_rho_v_gpu *d_v_gpu;
  interpolation(LB_nodes_gpu _current_nodes_gpu, LB_rho_v_gpu *_d_v_gpu)
      : current_nodes_gpu(_current_nodes_gpu), d_v_gpu(_d_v_gpu) {}
  __device__ float3 operator()(const float3 &position) const {
    float _position[3] = {position.x, position.y, position.z};
    Utils::Array<unsigned int, no_of_neighbours> node_indices;
    Utils::Array<float, no_of_neighbours> delta;
    return velocity_interpolation(current_nodes_gpu, _position, node_indices,
                                  delta);
  }
};

struct Plus : public thrust::binary_function<Utils::Array<float, 6>,
                                             Utils::Array<float, 6>,
                                             Utils::Array<float, 6>> {

  __device__ Utils::Array<float, 6>
  operator()(Utils::Array<float, 6> const &a, Utils::Array<float, 6> const &b) {
    return {a[0] + b[0], a[1] + b[1], a[2] + b[2],
            a[3] + b[3], a[4] + b[4], a[5] + b[5]};
  }
};

struct Stress {
  template <typename T>
  __device__ Utils::Array<float, 6> operator()(T const &t) const {
    Utils::Array<float, 19> modes;
    calc_m_from_n(thrust::get<0>(t), modes); // NOLINT
    return stress_from_stress_modes(stress_modes(thrust::get<1>(t), modes));
  }
};

Utils::Array<float, 6> stress_tensor_GPU() {
  if (not current_nodes->populations or not device_rho_v)
    throw std::runtime_error("LB not initialized");

  auto pop_begin = thrust::device_pointer_cast(current_nodes->populations);
  auto rho_v_begin = thrust::device_pointer_cast(device_rho_v);
  auto begin =
      thrust::make_zip_iterator(thrust::make_tuple(pop_begin, rho_v_begin));

  auto pop_end =
      thrust::device_pointer_cast(pop_begin + lbpar_gpu.number_of_nodes);
  auto rho_v_end =
      thrust::device_pointer_cast(rho_v_begin + lbpar_gpu.number_of_nodes);
  auto end = thrust::make_zip_iterator(thrust::make_tuple(pop_end, rho_v_end));

  return thrust::transform_reduce(begin, end, Stress(),
                                  Utils::Array<float, 6>{}, Plus());
};

template <std::size_t no_of_neighbours>
void lb_get_interpolated_velocity_gpu(double const *positions,
                                      double *velocities, int length) {
  auto const size = static_cast<unsigned>(length);
  thrust::host_vector<float3> positions_host(size);
  for (unsigned p = 0; p < 3 * size; p += 3) {
    // Cast double coming from python to float.
    positions_host[p / 3].x = static_cast<float>(positions[p]);
    positions_host[p / 3].y = static_cast<float>(positions[p + 1]);
    positions_host[p / 3].z = static_cast<float>(positions[p + 2]);
  }
  thrust::device_vector<float3> positions_device = positions_host;
  thrust::device_vector<float3> velocities_device(size);
  thrust::transform(
      positions_device.begin(), positions_device.end(),
      velocities_device.begin(),
      interpolation<no_of_neighbours>(*current_nodes, device_rho_v));
  thrust::host_vector<float3> velocities_host = velocities_device;
  unsigned index = 0;
  for (auto v : velocities_host) {
    velocities[index] = static_cast<double>(v.x);
    velocities[index + 1] = static_cast<double>(v.y);
    velocities[index + 2] = static_cast<double>(v.z);
    index += 3;
  }
}
template void lb_get_interpolated_velocity_gpu<8>(double const *positions,
                                                  double *velocities,
                                                  int length);
template void lb_get_interpolated_velocity_gpu<27>(double const *positions,
                                                   double *velocities,
                                                   int length);

void linear_velocity_interpolation(double const *positions, double *velocities,
                                   int length) {
  return lb_get_interpolated_velocity_gpu<8>(positions, velocities, length);
}

void quadratic_velocity_interpolation(double const *positions,
                                      double *velocities, int length) {
  return lb_get_interpolated_velocity_gpu<27>(positions, velocities, length);
}

void lb_coupling_set_rng_state_gpu(uint64_t counter) {
  rng_counter_coupling_gpu = Utils::Counter<uint64_t>(counter);
}

void lb_fluid_set_rng_state_gpu(uint64_t counter) {
  rng_counter_fluid_gpu = Utils::Counter<uint64_t>(counter);
}

uint64_t lb_coupling_get_rng_state_gpu() {
  assert(rng_counter_coupling_gpu);
  return rng_counter_coupling_gpu->value();
}
uint64_t lb_fluid_get_rng_state_gpu() {
  assert(rng_counter_fluid_gpu);
  return rng_counter_fluid_gpu->value();
}

#endif /* CUDA */
