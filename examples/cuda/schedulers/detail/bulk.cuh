/*
 * Copyright (c) NVIDIA
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <execution.hpp>
#include <type_traits>

#include <thrust/system/cuda/detail/core/triple_chevron_launch.h>

#include "common.cuh"

namespace example::cuda::stream {

namespace bulk {

template <int BlockThreads, std::integral Shape, class Fun, class... As>
  __launch_bounds__(BlockThreads) 
  __global__ void bulk_kernel(Shape shape, Fun fn, As... as) {
    const int tid = static_cast<int>(threadIdx.x + blockIdx.x * blockDim.x);

    if (tid < static_cast<int>(shape)) {
      fn(tid, as...);
    }
  }

template <class Receiver, class... As>
  __launch_bounds__(1)
  __global__ void continuation_kernel(Receiver receiver, As... as) {
    std::execution::set_value(std::move(receiver), std::move(as)...);
  }

template <class ReceiverId, std::integral Shape, class Fun>
  class receiver_t
    : std::execution::receiver_adaptor<receiver_t<ReceiverId, Shape, Fun>, std::__t<ReceiverId>>
    , receiver_base_t {
    using Receiver = std::__t<ReceiverId>;
    friend std::execution::receiver_adaptor<receiver_t, Receiver>;

    Shape shape_;
    Fun f_;

    operation_state_base_t& op_state_;

    template <class... As>
    void set_value(As&&... as) && noexcept 
      requires std::__callable<Fun, Shape, std::decay_t<As>...> {

      constexpr int block_threads = 256;
      const int grid_blocks = (static_cast<int>(shape_) + block_threads - 1) / block_threads;

      // bulk_kernel<block_threads, Shape, Fun, std::decay_t<As>...><<<grid_blocks, block_threads, 0, op_state_.stream_>>>(shape_, f_, as...);
      thrust::cuda_cub::launcher::triple_chevron(grid_blocks, block_threads, 0, 0)
          .doit(bulk_kernel<block_threads, Shape, Fun, std::decay_t<As>...>, this->base(), as...);

      // continuation_kernel<Receiver, std::decay_t<As>...><<<1, 1>>>(this->base(), as...);
      thrust::cuda_cub::launcher::triple_chevron(1, 1, 0, 0)
          .doit(continuation_kernel<std::decay_t<Receiver>, std::decay_t<As>...>, this->base(), as...);
    }

   public:
    explicit receiver_t(Receiver rcvr, Shape shape, Fun fun, operation_state_base_t& op_state)
      : std::execution::receiver_adaptor<receiver_t, Receiver>((Receiver&&) rcvr)
      , shape_(shape)
      , f_((Fun&&) fun)
      , op_state_(op_state)
    {}
  };

}

template <class SenderId, std::integral Shape, class FunId>
  struct bulk_sender_t : sender_base_t {
    using Sender = std::__t<SenderId>;
    using Fun = std::__t<FunId>;

    Sender sndr_;
    Shape shape_;
    Fun fun_;

    using set_error_t = 
      std::execution::completion_signatures<
        std::execution::set_error_t(std::exception_ptr)>;

    template <class Receiver>
      using receiver_t = bulk::receiver_t<std::__x<Receiver>, Shape, Fun>;

    template <class... Tys>
    using set_value_t = 
      std::execution::completion_signatures<
        std::execution::set_value_t(std::decay_t<Tys>...)>;

    template <class Self, class Env>
      using completion_signatures =
        std::execution::__make_completion_signatures<
          std::__member_t<Self, Sender>,
          Env,
          set_error_t,
          std::__q<set_value_t>>;

    template <std::__decays_to<bulk_sender_t> Self, std::execution::receiver Receiver>
      requires std::execution::receiver_of<Receiver, completion_signatures<Self, std::execution::env_of_t<Receiver>>>
    friend auto tag_invoke(std::execution::connect_t, Self&& self, Receiver&& rcvr)
      -> stream_op_state_t<std::__member_t<Self, Sender>, receiver_t<Receiver>> {
        return stream_op_state<std::__member_t<Self, Sender>>(((Self&&)self).sndr_, [&](operation_state_base_t& stream_provider) -> receiver_t<Receiver> {
          return receiver_t<Receiver>((Receiver&&)rcvr, self.shape_, self.fun_, stream_provider);
        });
      }

    template <std::__decays_to<bulk_sender_t> Self, class Env>
    friend auto tag_invoke(std::execution::get_completion_signatures_t, Self&&, Env)
      -> std::execution::dependent_completion_signatures<Env>;

    template <std::__decays_to<bulk_sender_t> Self, class Env>
    friend auto tag_invoke(std::execution::get_completion_signatures_t, Self&&, Env)
      -> completion_signatures<Self, Env> requires true;

    template <std::execution::tag_category<std::execution::forwarding_sender_query> Tag, class... As>
      requires std::__callable<Tag, const Sender&, As...>
    friend auto tag_invoke(Tag tag, const bulk_sender_t& self, As&&... as)
      noexcept(std::__nothrow_callable<Tag, const Sender&, As...>)
      -> std::__call_result_if_t<std::execution::tag_category<Tag, std::execution::forwarding_sender_query>, Tag, const Sender&, As...> {
      return ((Tag&&) tag)(self.sndr_, (As&&) as...);
    }
  };

}

