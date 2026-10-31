//
// Copyright (c) 2023-2026 Shaheryar Sohail and Lee Durbin
// SPDX-License-Identifier: AGPL-3.0-only
//

#ifndef STOCKDORY_NETWORKARCHITECTURE_H
#define STOCKDORY_NETWORKARCHITECTURE_H

#include <MantaRay/MantaRay.h>

// MantaRay already implements an AArch64 NEON backend. Fail the Android
// ARM64 build if the toolchain ever selects its scalar or another backend.
#if defined(__ANDROID__) && defined(__aarch64__)
    #include <type_traits>
    static_assert(std::is_same_v<MantaRay::Backend::Native, MantaRay::Backend::ISA::NEON>,
                  "StockDory Android ARM64 builds must use MantaRay's NEON backend");
#endif

// Architecture:
template<MantaRay::s00 HiddenSize, typename Activation = MantaRay::ClippedReLU<>, typename Schedule = MantaRay::Exact>
using PerspectiveArchitecture = MantaRay::Architecture<
    MantaRay::FeatureTransformer<MantaRay::Chess768, HiddenSize,
        MantaRay::Weights<MantaRay::i16, 255, MantaRay::Clip<-1.98, 1.98>>,
        MantaRay::Biases <MantaRay::i16, 255, MantaRay::Clip<-1.98, 1.98>>
    >,
    Activation,
    MantaRay::Concat,
    MantaRay::Affine<HiddenSize * 2, 1,
        MantaRay::Weights<MantaRay::i16,       64, MantaRay::Clip<-1.98, 1.98>>,
        MantaRay::Biases <MantaRay::i16, 255 * 64                             >,
        Schedule
    >,
    MantaRay::Output<400>
>;

using StarshardArchitecture = PerspectiveArchitecture< 256                                                         >;
using    AuroraArchitecture = PerspectiveArchitecture< 384                                                         >;
using     FlareArchitecture = PerspectiveArchitecture< 768                                                         >;
using    CoronaArchitecture = PerspectiveArchitecture< 768, MantaRay::SquaredClippedReLU<>, MantaRay::DivideBy<255>>;
using   EclipseArchitecture = PerspectiveArchitecture<1536, MantaRay::SquaredClippedReLU<>, MantaRay::DivideBy<255>>;

// Network:
using Starshard = MantaRay::Network<StarshardArchitecture>;
using    Aurora = MantaRay::Network<   AuroraArchitecture>;
using     Flare = MantaRay::Network<    FlareArchitecture>;
using    Corona = MantaRay::Network<   CoronaArchitecture>;
using   Eclipse = MantaRay::Network<  EclipseArchitecture>;

// Accumulator Stack:
constexpr size_t AccumulatorStackSize = StockDory::MaxDepth + 1;

// Defaults to lazy updates
template<typename Architecture>
using NetworkStack = MantaRay::AccumulatorStack<Architecture, AccumulatorStackSize>;

using StarshardStack = NetworkStack<StarshardArchitecture>;
using    AuroraStack = NetworkStack<   AuroraArchitecture>;
using     FlareStack = NetworkStack<    FlareArchitecture>;
using    CoronaStack = NetworkStack<   CoronaArchitecture>;
using   EclipseStack = NetworkStack<  EclipseArchitecture>;

#endif //STOCKDORY_NETWORKARCHITECTURE_H
