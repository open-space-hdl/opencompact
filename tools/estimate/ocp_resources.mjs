// SPDX-License-Identifier: MIT
// Copyright (c) 2026 by Julian Schneider
//
// Resource estimate of ocp_core from its generics, for web pages (the Open Space Composer): the JavaScript port of
// tools/ocp_estimate.py. tools/tests/ocp_resources.test.mjs compares it with the Python functions
// (tools/tests/golden_ocp_models.json, written by tools/ocp_estimate_golden.py).
// @ts-check
/**
 * Resource estimate of the OpenCompact compressor ocp_core (pure, no DOM).
 *
 * The generics are those of ocp_core as the Composer holds them: numbers and booleans, the names of the enumerations,
 * VHDL literals of the vectors ("(0 => 4)", "(2, 3, 4)"). Generics that a configuration does not set take the defaults
 * of ocp_core (RuntimeConfig_g, RuntimeParams_g and Speculation_g).
 *
 *   memories           every memory of ocp_core with its depth, its data width and the width of the stored SECDED
 *                      codeword; the sizes mirror the constants of the RTL, and lint/memory_check.py checks them
 *                      against the GHDL netlist of every configuration of the regression. They do not depend on the
 *                      FPGA vendor; how a synthesis tool maps a memory (block RAM, distributed RAM) does.
 *   logicFeatures      the structure features of the logic (datapath widths times their number, the optional blocks),
 *                      the inputs of the linear LUT and flip-flop model.
 *   estimateResources  the memories with their bits, and the logic (LUT, flip-flops) and the clock frequency of a
 *                      target where the model has data for it (see the notes of the result).
 *
 * The throughput (cycles per sample, period of consecutive images) is computed by ocp_throughput.mjs.
 */

import { intVector, latencies, strideParams } from './ocp_throughput.mjs';

// Codeword buffer of the entropy coders (ocp_pkg) and the depth of its FIFO
const CW_WIDTH = 96;
const CW_LEN_WIDTH = 7;
const CW_FIFO_DEPTH = 16;

/**
 * @typedef {object} Memory
 * @property {string} name
 * @property {number} channel    error injection channel of ocp_core (ErrInj_Channel)
 * @property {number} depth      words
 * @property {number} width      data bits per word
 * @property {number} codeword   stored bits per word (data and SECDED check bits)
 */

/**
 * @typedef {object} Resources
 * @property {{ data: number, stored: number }} ramBits   bits of all memories, of the data and stored with the check bits
 * @property {Memory[]} memories
 * @property {number | null} lut       look-up tables of the target, null without data for it
 * @property {number | null} ff        flip-flops of the target, null without data for it
 * @property {number | null} fmaxMHz   clock frequency of the target, null without data for it
 * @property {string[]} notes          the sources and the validity of the numbers
 */

/**
 * Width of the SECDED codeword of a data word (eccCodewordWidth of olo_ft_pkg_ecc): the data bits, the Hamming parity
 * bits and one overall parity bit.
 * @param {number} width
 */
export function eccCodewordWidth(width) {
  let r = 1;
  while (2 ** r < width + r + 1) r += 1;
  return width + r + 1;
}

/** @param {number} n */
function log2ceil(n) {
  return n > 1 ? Math.ceil(Math.log2(n)) : 0;
}

/**
 * The generics with the defaults of ocp_core for those that a configuration does not set.
 * @param {Record<string, any>} g
 * @returns {Record<string, any>}
 */
function withDefaults(g) {
  return { RuntimeConfig_g: false, RuntimeParams_g: false, Speculation_g: true, OutWidth_g: 8, ...g };
}

/**
 * The memories of ocp_core (memories() of tools/ocp_estimate.py).
 * @param {Record<string, any>} generics
 * @returns {Memory[]}
 */
export function memories(generics) {
  const g = withDefaults(generics);
  const nx = g.XSize_g;
  const ny = g.YSize_g;
  const nz = g.ZSize_g;
  const d = g.DynamicRange_g;
  const bsq = g.EncodingOrder_g === 'BSQ';
  const p = g.PredictionBands_g;
  const fid = g.Fidelity_g;
  const m = Math.min(g.SubFrameDepth_g, nz);
  const lat = latencies(g, g.Speculation_g === true);
  const periodic = g.PeriodicUpdate_g === true && fid !== 'LOSSLESS' && !bsq;
  const bandSlots = bsq ? 2 : Math.max(nz, 2);
  const diffBits = Math.max(p, 1) * (d + 3);
  let fifoDepth = 1;
  while (fifoDepth < lat.depth + 8) fifoDepth *= 2;
  /** @type {[number, string, number, number, boolean][]} */
  const list = [
    [0, 'sample representatives of the line', Math.max(bsq ? 3 * nx : nz * nx, 2), d, true],
    [1, 'window of the previous line', bandSlots, 2 * d, !(bsq || m === 1)],
    [2, 'previous sample representative', bandSlots, d, true],
    [3, 'first sample representative of the line', bandSlots, d, true],
    [4, 'central local differences', Math.max(bsq ? nx * ny : nx, 2), diffBits,
      p > 0 && (bsq || m < nz || (g.RuntimeParams_g === true && nz > 1))],
    [5, 'weights', bandSlots, Math.max(lat.c, 1) * (g.WeightResolution_g + 3), lat.c > 0 && !(lat.spec && lat.runRows)],
    [6, 'absolute error limits', nz + 1, 16,
      periodic && (fid === 'ABSOLUTE' || fid === 'ABSOLUTE_RELATIVE') && g.AbsBandDependent_g === true],
    [7, 'relative error limits', nz + 1, 16,
      periodic && (fid === 'RELATIVE' || fid === 'ABSOLUTE_RELATIVE') && g.RelBandDependent_g === true],
    [8, 'predictor output FIFO', fifoDepth, Math.max(d, 16) + 2 + log2ceil(nz + 1) + 3, true],
  ];
  // Stride order: not with the runtime configuration (PR-RC-04)
  const st = g.RuntimeConfig_g === true ? null : strideParams(g, lat);
  if (st) {
    const kCtx = 2 ** log2ceil(Math.floor(st.s / st.m) + 1);
    list.push([9, 'stride input buffer', 2 ** log2ceil(st.skew + st.m + 8), d, true]);
    list.push([10, 'stride output buffer', 2 ** log2ceil(st.skew + 2 * lat.depth + 16), d, true]);
    list.push([11, 'stride local differences', bandSlots * kCtx, diffBits, true]);
  }
  list.push([12, 'coder statistics', nz + 1, d + 2 * g.RescaleCounterSize_g + 3,
    g.EntropyCoder_g === 'SAMPLE_ADAPTIVE' || g.EntropyCoder_g === 'HYBRID']);
  list.push([13, 'codeword FIFO', CW_FIFO_DEPTH, CW_WIDTH + CW_LEN_WIDTH + 1, true]);
  return list
    .filter((e) => e[4])
    .sort((a, b) => a[0] - b[0])
    .map(([channel, name, depth, width]) => ({ name, channel, depth, width, codeword: eccCodewordWidth(width) }));
}

/**
 * Bits of all memories of ocp_core: of the data, and stored with the SECDED check bits.
 * @param {Record<string, any>} generics
 */
export function ramBits(generics) {
  const mems = memories(generics);
  return {
    data: mems.reduce((sum, mem) => sum + mem.depth * mem.width, 0),
    stored: mems.reduce((sum, mem) => sum + mem.depth * mem.codeword, 0),
  };
}

/**
 * Structure features of the logic of ocp_core, the inputs of the linear LUT and flip-flop model (logic_features() of
 * tools/ocp_estimate.py).
 * @param {Record<string, any>} generics
 * @returns {Record<string, number>}
 */
export function logicFeatures(generics) {
  const g = withDefaults(generics);
  const d = g.DynamicRange_g;
  const om = g.WeightResolution_g;
  const lat = latencies(g, g.Speculation_g === true);
  const c1 = Math.max(lat.c, 1);
  const fid = g.Fidelity_g;
  const qw = Math.max(d, 16) + 2;
  const stride = g.RuntimeConfig_g !== true && Boolean(strideParams(g, lat));
  const coder = g.EntropyCoder_g;
  const damping = intVector(g.Damping_g);
  const repIsSample = fid === 'LOSSLESS' && (g.SampleRepResolution_g === 0 || !damping.some((v) => v !== 0));
  return {
    base: 1,
    dyn_range: d,
    products: c1 * (d + om + 12),
    weights: c1 * (om + 3),
    speculation: lat.spec ? c1 * (d + om + 12) : 0,
    quantizer: fid !== 'LOSSLESS' ? qw * (d + 16) : 0,
    relative: fid === 'RELATIVE' || fid === 'ABSOLUTE_RELATIVE' ? d + 16 : 0,
    representatives: repIsSample ? 0 : d + om,
    stride: stride ? d : 0,
    periodic: g.PeriodicUpdate_g === true ? 1 : 0,
    hybrid: coder === 'HYBRID' ? 1 : 0,
    block: coder === 'BLOCK_ADAPTIVE' ? Math.floor((d * g.BlockSize_g) / 8) : 0,
    counters: log2ceil(g.XSize_g) + log2ceil(g.YSize_g) + log2ceil(g.ZSize_g),
    out_width: g.OutWidth_g,
    runtime_config: g.RuntimeConfig_g === true ? 1 : 0,
    runtime_params: g.RuntimeParams_g === true ? 1 : 0,
  };
}

/**
 * The linear LUT and flip-flop model of a target: the coefficient of every feature of logicFeatures() and the notes
 * on its source and accuracy (LOGIC_MODEL of tools/ocp_estimate.py).
 * @type {Record<string, { lut: Record<string, number>, ff: Record<string, number>, notes: string[] }>}
 */
const LOGIC_MODEL = {};

const MEMORY_NOTE =
  'Memories: exact for the generics; the sizes of the RTL, checked against the GHDL netlist of every configuration ' +
  'of the regression. Stored bits include the SECDED check bits.';

/**
 * sum(coefficient x feature), rounded to a multiple of 10 (halves up), in integer arithmetic on the coefficients in
 * tenths (linear_estimate() of tools/ocp_estimate.py).
 * @param {Record<string, number>} coef @param {Record<string, number>} features
 */
function linearEstimate(coef, features) {
  let tenths = 0;
  for (const [name, value] of Object.entries(features)) tenths += Math.round(coef[name] * 10) * value;
  return Math.floor((tenths + 50) / 100) * 10;
}

/**
 * Resource estimate of ocp_core (estimate_resources() of tools/ocp_estimate.py).
 * @param {Record<string, any>} generics
 * @returns {Resources}
 */
export function estimateResources(generics) {
  const model = LOGIC_MODEL.polarfire;
  const features = logicFeatures(generics);
  return {
    ramBits: ramBits(generics),
    memories: memories(generics),
    lut: model ? linearEstimate(model.lut, features) : null,
    ff: model ? linearEstimate(model.ff, features) : null,
    fmaxMHz: null,
    notes: [MEMORY_NOTE, ...(model ? model.notes : ['LUT, flip-flops and clock frequency: no model yet.'])],
  };
}
