/*
 * Copyright (c) 2020-2025, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 */

/** @file   takikawa_encoding.cuh
 *  @author Thomas Müller, NVIDIA
 *  @brief  An implementation of an encoding similar to the one described in
 *          Neural Geometric Level of Detail: Real-time Rendering with Implicit 3D Shapes
 *          by T. Takakawa et al.
 */

#pragma once

#include <neural-graphics-primitives/triangle_octree.cuh>

#include <tiny-cuda-nn/common.h>
#include <tiny-cuda-nn/encoding.h>
#include <tiny-cuda-nn/random.h>

namespace ngp {

template <typename T, uint32_t N_FEATURES_PER_LEVEL>
__global__ void kernel_takikawa(
	const uint32_t num_elements,
	const uint32_t n_levels,
	const uint32_t starting_level,
	const InterpolationType interpolation_type,
	const TriangleOctreeNode* octree_nodes,
	const TriangleOctreeDualNode* octree_dual_nodes,
	const T* __restrict__ grid,
	const MatrixView<const float> data_in,
	MatrixView<T> data_out,
	float* __restrict__ dy_dx
) {
	uint32_t n_features = N_FEATURES_PER_LEVEL * n_levels;

	uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
	const uint32_t encoded_index = i * n_features;
	if (encoded_index >= num_elements * n_features) return;

	int level = traverse(
		octree_nodes,
		octree_dual_nodes,
		n_levels + starting_level,
		{
			data_in(0u, i),
			data_in(1u, i),
			data_in(2u, i),
		},
		[&](const TriangleOctreeDualNode& node, uint32_t level, vec3 pos) {
			if (level < starting_level) {
				return;
			}
			level -= starting_level;

			vec3 pos_derivative;

			if (interpolation_type == InterpolationType::Linear) {
				NGP_PRAGMA_UNROLL
				for (uint32_t dim = 0; dim < 3; ++dim) {
					pos_derivative[dim] = 1.0f;
				}
			} else {
				NGP_PRAGMA_UNROLL
				for (uint32_t dim = 0; dim < 3; ++dim) {
					pos_derivative[dim] = smoothstep_derivative(pos[dim]);
					pos[dim] = smoothstep(pos[dim]);
				}
			}

			if (data_out) {
				// Tri-linear interpolation
				tvec<T, N_FEATURES_PER_LEVEL, sizeof(T) * N_FEATURES_PER_LEVEL> result = {(T)0.0f};

				NGP_PRAGMA_UNROLL
				for (uint32_t idx = 0; idx < 8; ++idx) {
					float weight = 1;

					NGP_PRAGMA_UNROLL
					for (uint32_t dim = 0; dim < 3; ++dim) {
						if ((idx & (1<<dim)) == 0) {
							weight *= 1 - pos[dim];
						} else {
							weight *= pos[dim];
						}
					}

					int param_idx = node.vertices[idx] * N_FEATURES_PER_LEVEL;
					result = fma((T)weight, *(tvec<T, N_FEATURES_PER_LEVEL, sizeof(T) * N_FEATURES_PER_LEVEL>*)&grid[param_idx], result);
				}

				NGP_PRAGMA_UNROLL
				for (uint32_t feature = 0; feature < N_FEATURES_PER_LEVEL; ++feature) {
					data_out(level * N_FEATURES_PER_LEVEL + feature, i) = result[feature];
				}
			}

			// Gradient
			if (dy_dx) {
				const float scale = scalbnf(1.0f, level + starting_level);

				NGP_PRAGMA_UNROLL
				for (uint32_t grad_dim = 0; grad_dim < 3; ++grad_dim) {
					vec<N_FEATURES_PER_LEVEL> grad = {0.0f};

					NGP_PRAGMA_UNROLL
					for (uint32_t idx = 0; idx < 4; ++idx) {
						float weight = scale;
						uint32_t child_idx = 0;

						NGP_PRAGMA_UNROLL
						for (uint32_t non_grad_dim = 0; non_grad_dim < 2; ++non_grad_dim) {
							const uint32_t dim = non_grad_dim >= grad_dim ? (non_grad_dim+1) : non_grad_dim;

							if ((idx & (1<<non_grad_dim)) == 0) {
								weight *= 1 - pos[dim];
							} else {
								weight *= pos[dim];
								child_idx |= 1 << dim;
							}
						}

						int param_idx = node.vertices[child_idx] * N_FEATURES_PER_LEVEL;
						auto val_left = *(tvec<T, N_FEATURES_PER_LEVEL>*)&grid[param_idx];

						child_idx |= 1 << grad_dim;
						param_idx = node.vertices[child_idx] * N_FEATURES_PER_LEVEL;
						auto val_right = *(tvec<T, N_FEATURES_PER_LEVEL>*)&grid[param_idx];

						NGP_PRAGMA_UNROLL
						for (uint32_t feature = 0; feature < N_FEATURES_PER_LEVEL; ++feature) {
							((float*)&grad)[feature] += weight * ((float)((T*)&val_right)[feature] - (float)((T*)&val_left)[feature]) * pos_derivative[grad_dim];
						}
					}

					const uint32_t fan_out_grad = n_features * 3;
					*(vec<N_FEATURES_PER_LEVEL>*)&dy_dx[i * fan_out_grad + level * N_FEATURES_PER_LEVEL + grad_dim * n_features] = grad;
				}
			}
		}
	);

	if (data_out) {
		// Set output to zero for levels that were not reached
		level = max(0, level-(int)starting_level);
		for (; level < n_levels; ++level) {
			NGP_PRAGMA_UNROLL
			for (uint32_t f = 0; f < N_FEATURES_PER_LEVEL; ++f) {
				data_out(level * N_FEATURES_PER_LEVEL + f, i) = (T)0.0f;
			}
		}
	}
}

template <typename T>
__global__ void kernel_takikawa_backward_input(
	const uint32_t num_elements,
	const uint32_t num_grid_features,
	const MatrixView<const T> dL_dy,
	const float* __restrict__ dy_dx,
	MatrixView<float> dL_dx
) {
	const uint32_t input_index = threadIdx.x + blockIdx.x * blockDim.x;
	if (input_index >= num_elements) return;

	const uint32_t fan_out_grad = num_grid_features * 3;

	const uint32_t i = input_index / 3;
	const uint32_t j = input_index - i * 3;

	float result = 0;
	for (uint32_t k = 0; k < num_grid_features; ++k) {
		result += (float)dL_dy(k, i) * dy_dx[i * fan_out_grad + j * num_grid_features + k];
	}

	dL_dx(j, i) = result;
}

template <typename T, typename GRAD_T, uint32_t N_FEATURES_PER_LEVEL>
__global__ void kernel_takikawa_backward(
	const uint32_t num_elements,
	const uint32_t n_levels,
	const uint32_t starting_level,
	const InterpolationType interpolation_type,
	const TriangleOctreeNode* octree_nodes,
	const TriangleOctreeDualNode* octree_dual_nodes,
	GRAD_T* __restrict__ param_gradients,
	const MatrixView<const float> data_in,
	const MatrixView<const T> dL_dy
) {
	uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
	const uint32_t encoded_index = i * N_FEATURES_PER_LEVEL * n_levels;
	if (encoded_index >= num_elements * N_FEATURES_PER_LEVEL * n_levels) return;

	traverse(
		octree_nodes,
		octree_dual_nodes,
		n_levels + starting_level,
		{
			data_in(0u, i),
			data_in(1u, i),
			data_in(2u, i),
		},
		[&](const TriangleOctreeDualNode& node, uint32_t level, vec3 pos) {
			if (level < starting_level) {
				return;
			}
			level -= starting_level;

			if (interpolation_type == InterpolationType::Smoothstep) {
				NGP_PRAGMA_UNROLL
				for (uint32_t dim = 0; dim < 3; ++dim) {
					pos[dim] = smoothstep(pos[dim]);
				}
			}

			tvec<T, N_FEATURES_PER_LEVEL> grad;

			NGP_PRAGMA_UNROLL
			for (uint32_t f = 0; f < N_FEATURES_PER_LEVEL; ++f) {
				grad[f] = dL_dy(N_FEATURES_PER_LEVEL * level + f, i);
			}

			// Tri-linear interpolation

			NGP_PRAGMA_UNROLL
			for (uint32_t idx = 0; idx < 8; ++idx) {
				float weight = 1;

				NGP_PRAGMA_UNROLL
				for (uint32_t dim = 0; dim < 3; ++dim) {
					if ((idx & (1<<dim)) == 0) {
						weight *= 1 - pos[dim];
					} else {
						weight *= pos[dim];
					}
				}

				int param_idx = node.vertices[idx] * N_FEATURES_PER_LEVEL;

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 600 // atomicAdd(__half2) is only supported with compute capability 60 and above
				if (N_FEATURES_PER_LEVEL > 1 && std::is_same<GRAD_T, __half>::value) {
					NGP_PRAGMA_UNROLL
					for (uint32_t feature = 0; feature < N_FEATURES_PER_LEVEL; feature += 2) {
						__half2 v = {(__half)((float)grad[feature] * weight), (__half)((float)grad[feature+1] * weight)};
						atomicAdd((__half2*)&param_gradients[param_idx + feature], v);
					}
				} else
#endif
				{
					if (std::is_same<GRAD_T, __half>::value) {
						// Should never happen
						//printf("Attempted to use atomicAdd(__half)\n")
					} else {
						NGP_PRAGMA_UNROLL
						for (uint32_t f = 0; f < N_FEATURES_PER_LEVEL; ++f) {
							atomicAdd((float*)&param_gradients[param_idx], (float)grad[f] * weight);
						}
					}
				}
			}
		}
	);
}

template <typename T, uint32_t N_FEATURES_PER_LEVEL=8>
class TakikawaEncoding : public Encoding<T> {
public:
#if TCNN_MIN_GPU_ARCH >= 60
	// The GPUs that we tested this on do not have an efficient 1D fp16
	// atomicAdd feature. Thus, we accumulate gradients at fp32 if we're
	// forced to use 1D atomicAdds. As soon as 2D or higher is possible,
	// we can make use the efficient atomicAdd(half2) function.
	using grad_t = std::conditional_t<N_FEATURES_PER_LEVEL == 1, float, T>;
#else
	// atomicAdd(__half2) is only supported with compute capability 60 and above.
	// Since atomicAdd(__half) is relatively slow / doesn't exist for low compute
	// capabilities, accumulate in fp32 instead.
	using grad_t = float;
#endif

	TakikawaEncoding(uint32_t starting_level, std::shared_ptr<TriangleOctree> octree, InterpolationType interpolation_type)
		: m_starting_level{starting_level}, m_octree{octree}, m_interpolation_type{interpolation_type} {

		if (m_starting_level >= m_octree->depth()) {
			throw std::runtime_error{"Starting level must be below octree depth."};
		}

		m_n_output_dims = N_FEATURES_PER_LEVEL * n_levels();

		if (N_FEATURES_PER_LEVEL != 1 && N_FEATURES_PER_LEVEL != 2 && N_FEATURES_PER_LEVEL != 4 && N_FEATURES_PER_LEVEL != 8) {
			throw std::runtime_error{"Number of features per level must be 1, 2, 4, or 8."};
		}
	}

	virtual ~TakikawaEncoding() { }

	std::unique_ptr<Context> forward_impl(
		cudaStream_t stream,
		const GPUMatrixDynamic<float>& input,
		GPUMatrixDynamic<T>* output = nullptr,
		bool use_inference_params = false,
		bool prepare_input_gradients = false
	) override {
		auto forward = std::make_unique<ForwardContext>();

		if ((!output && !prepare_input_gradients) || padded_output_width() == 0) {
			return forward;
		}

		if (prepare_input_gradients) {
			forward->dy_dx = GPUMatrix<float>{3 * N_FEATURES_PER_LEVEL * n_levels(), input.n(), stream};
		}

		linear_kernel(kernel_takikawa<T, N_FEATURES_PER_LEVEL>, 0, stream,
			input.n(),
			n_levels(),
			m_starting_level,
			m_interpolation_type,
			m_octree->nodes_gpu(),
			m_octree->dual_nodes_gpu(),
			use_inference_params ? this->inference_params() : this->params(),
			input.view(),
			output ? output->view() : MatrixView<T>{},
			forward->dy_dx.data()
		);

		return forward;
	}

	void backward_impl(
		cudaStream_t stream,
		const Context& ctx,
		const GPUMatrixDynamic<float>& input,
		const GPUMatrixDynamic<T>& output,
		const GPUMatrixDynamic<T>& dL_doutput,
		GPUMatrixDynamic<float>* dL_dinput = nullptr,
		bool use_inference_params = false,
		GradientMode param_gradients_mode = GradientMode::Overwrite
	) override {
		const uint32_t num_elements = input.n();
		if (padded_output_width() == 0 || num_elements == 0) {
			return;
		}

		const auto& forward = dynamic_cast<const ForwardContext&>(ctx);

		if (param_gradients_mode != GradientMode::Ignore) {
			// We accumulate gradients with grad_t precision, which, for performance reasons, is not always T.
			// If not, accumulate in a temporary buffer and cast later.
			grad_t* param_gradients;
			GPUMemoryArena::Allocation param_gradients_tmp;

			if (!std::is_same<grad_t, T>::value) {
				param_gradients_tmp = allocate_workspace(stream, n_params() * sizeof(grad_t));
				param_gradients = (grad_t*)param_gradients_tmp.data();
			} else {
				param_gradients = (grad_t*)this->gradients();
			}

			if (param_gradients_mode == GradientMode::Overwrite) {
				CUDA_CHECK_THROW(cudaMemsetAsync(param_gradients, 0, n_params() * sizeof(grad_t), stream));
			}

			linear_kernel(kernel_takikawa_backward<T, grad_t, N_FEATURES_PER_LEVEL>, 0, stream,
				num_elements,
				n_levels(),
				m_starting_level,
				m_interpolation_type,
				m_octree->nodes_gpu(),
				m_octree->dual_nodes_gpu(),
				param_gradients,
				input.view(),
				dL_doutput.view()
			);

			if (!std::is_same<grad_t, T>::value) {
				parallel_for_gpu(stream, n_params(), [grad=this->gradients(), grad_tmp=param_gradients] __device__ (size_t i) {
					grad[i] = (T)grad_tmp[i];
				});
			}
		}

		// Gradient computation w.r.t. input
		if (dL_dinput) {
			linear_kernel(kernel_takikawa_backward_input<T>, 0, stream,
				num_elements * input_width(),
				N_FEATURES_PER_LEVEL * n_levels(),
				dL_doutput.view(),
				forward.dy_dx.data(),
				dL_dinput->view()
			);
		}
	}

	uint32_t input_width() const override {
		return 3;
	}

	uint32_t padded_output_width() const override {
		return m_n_output_dims + m_n_to_pad;
	}

	uint32_t output_width() const override {
		return padded_output_width();
	}

	uint32_t required_input_alignment() const override {
		return 1;
	}

	void set_padded_output_width(uint32_t padded_output_width) override {
		CHECK_THROW(padded_output_width == m_n_output_dims);
	}

	uint32_t required_output_alignment() const override {
		return N_FEATURES_PER_LEVEL;
	}

	void set_params_impl(T* params, T* inference_params, T* gradients) override { }

	void initialize_params(pcg32& rnd, float* params_full_precision, float scale = 1) override {
		// Initialize the encoding from the GPU, because the number of parameters can be quite large.
		generate_random_uniform<float>(rnd, n_params(), params_full_precision, -1e-4f * scale, 1e-4f * scale);
	}

	size_t n_params() const override {
		return N_FEATURES_PER_LEVEL * m_octree->n_vertices();
	}

	uint32_t n_levels() const {
		return m_octree->depth() - m_starting_level;
	}

	MatrixLayout preferred_output_layout() const override {
		return AoS;
	}

	json hyperparams() const override {
		return {
			{"otype", "Takikawa"},
			{"starting_level", m_starting_level},
			{"n_levels", m_octree->depth()},
		};
	}

private:
	struct ForwardContext : public Context {
		GPUMatrix<float> dy_dx;
	};

	uint32_t m_starting_level;

	// derived sizes
	uint32_t m_n_input_dims;
	uint32_t m_n_output_dims;
	uint32_t m_n_to_pad = 0;

	std::shared_ptr<TriangleOctree> m_octree;
	InterpolationType m_interpolation_type;
};

}
