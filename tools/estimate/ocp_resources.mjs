// ---------------------------------------------------------------------------------------------------
// Copyright (c) 2026 by Julian Schneider
// Authors: Julian Schneider
// ---------------------------------------------------------------------------------------------------
// @ts-check
/**
 * Resource estimate of ocp_core from its generics (pure functions, no DOM): the JavaScript twin of
 * tools/ocp_estimate.py. tools/tests/test_ocp_estimate.py runs it with node and compares every result with the Python
 * functions for every configuration of tools/ocp_configs.py.
 *
 * The generics carry the names of the VHDL generics of ocp_core (XSize_g, DynamicRange_g, ...), with the values that
 * tools/ocp_generics.py gives them: numbers, booleans, strings of the enumerations, vector generics as comma-separated
 * strings. Generics that the configuration does not set take the defaults of ocp_core (RuntimeConfig_g,
 * RuntimeParams_g, Speculation_g).
 *
 * memories(g) lists every memory with its depth, its data width and the width of the stored SECDED codeword; the sizes
 * mirror the constants of the RTL. They do not depend on the FPGA vendor; how a synthesis tool maps a memory does. The
 * throughput (cycles per sample, image period) is not part of this module: the Composer computes it with its port of
 * tools/ocp_throughput.py.
 */

// Codeword buffer of the entropy coders (ocp_pkg) and the depth of its FIFO
const CW_WIDTH = 96;
const CW_LEN_WIDTH = 7;
const CW_FIFO_DEPTH = 16;

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

/** @param {number} n */
function treeStages(n) {
  let stages = 1;
  let reach = 4;
  while (reach < n) {
    reach *= 4;
    stages += 1;
  }
  return stages;
}

/** @param {number} a @param {number} b */
function gcd(a, b) {
  while (b) [a, b] = [b, a % b];
  return a;
}

/** @param {unknown} v the elements of a vector generic ("0,1,2", a number) */
function intVector(v) {
  if (typeof v === 'number') return [v];
  return String(v ?? '0').split(',').map((x) => Number(x.trim()));
}

/** @param {Record<string, any>} g with the defaults of ocp_core */
function withDefaults(g) {
  return { RuntimeConfig_g: false, RuntimeParams_g: false, Speculation_g: true, ...g };
}

/**
 * The part of the pipeline structure of the predictor that sizes its memories (latencies() of tools/ocp_throughput.py):
 * the pipeline depth, the speculative weight loop, the issue distance to the previous band at the same pixel.
 * @param {Record<string, any>} g
 */
function structure(g) {
  const d = g.DynamicRange_g;
  const nx = g.XSize_g;
  const ny = g.YSize_g;
  const nz = g.ZSize_g;
  const bsq = g.EncodingOrder_g === 'BSQ';
  const m = Math.min(g.SubFrameDepth_g, nz);
  const p = g.PredictionBands_g;
  const full = g.PredictionMode_g === 'FULL';
  const narrow = g.LocalSum_g === 'NARROW_NEIGHBOR' || g.LocalSum_g === 'NARROW_COLUMN';
  const fid = g.Fidelity_g;
  const lossless = fid === 'LOSSLESS';
  const repIsSample = lossless && (g.SampleRepResolution_g === 0 || !intVector(g.Damping_g).some((v) => v !== 0));
  const c = p + 3 * (full ? 1 : 0);
  const wUsed = full || !narrow;
  const gap1 = bsq || m === 1;
  const runRows = bsq || nz === 1;
  const ts = treeStages(Math.max(c, 1) + 1);
  const threshSign = fid !== 'RELATIVE' && fid !== 'ABSOLUTE_RELATIVE';
  const spec = g.Speculation_g && threshSign && gap1 && c > 0 && ts === 1 && (repIsSample || !wUsed);
  const sgn = 5 + ts + 1;
  const limit = sgn + 3;
  const upd = (threshSign ? sgn : limit) + 1;
  const repSum = limit + (lossless ? 0 : Math.max(d, 16) + 2) + 3;
  const out = Math.max(repSum, upd);
  const dz = repIsSample ? 3 : repSum;
  const lRep = repSum + 2;
  const lDw = dz + 2;
  const diffRam = p > 0 && (bsq || m < nz);
  const diffGap = bsq ? nx * ny : (nx - 1) * m + 1;
  const crossRep = !repIsSample && (p > 0 || narrow);
  const lCross = Math.max(crossRep ? lRep : 0, diffRam && diffGap < lDw ? lDw : 0);
  return { depth: out + 1, spec, runRows, c, m, crossRep, lCross };
}

/**
 * The memories of ocp_core: name, error injection channel (ErrInj_Channel), depth, data width and stored width
 * (codeword) per word.
 * @param {Record<string, any>} generics
 * @returns {{ name: string, channel: number, depth: number, width: number, codeword: number }[]}
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
  const s = structure(g);
  const periodic = g.PeriodicUpdate_g && fid !== 'LOSSLESS' && !bsq;
  const bandSlots = bsq ? 2 : Math.max(nz, 2);
  const diffBits = Math.max(p, 1) * (d + 3);
  let fifoDepth = 1;
  while (fifoDepth < s.depth + 8) fifoDepth *= 2;
  /** @type {[number, string, number, number, boolean][]} */
  const list = [
    [0, 'sample representatives of the line', Math.max(bsq ? 3 * nx : nz * nx, 2), d, true],
    [1, 'window of the previous line', bandSlots, 2 * d, !(bsq || s.m === 1)],
    [2, 'previous sample representative', bandSlots, d, true],
    [3, 'first sample representative of the line', bandSlots, d, true],
    [4, 'central local differences', Math.max(bsq ? nx * ny : nx, 2), diffBits,
      p > 0 && (bsq || s.m < nz || (g.RuntimeParams_g && nz > 1))],
    [5, 'weights', bandSlots, Math.max(s.c, 1) * (g.WeightResolution_g + 3), s.c > 0 && !(s.spec && s.runRows)],
    [6, 'absolute error limits', nz + 1, 16,
      periodic && (fid === 'ABSOLUTE' || fid === 'ABSOLUTE_RELATIVE') && g.AbsBandDependent_g],
    [7, 'relative error limits', nz + 1, 16,
      periodic && (fid === 'RELATIVE' || fid === 'ABSOLUTE_RELATIVE') && g.RelBandDependent_g],
    [8, 'predictor output FIFO', fifoDepth, Math.max(d, 16) + 2 + log2ceil(nz + 1) + 3, true],
  ];
  // Stride order: BI order with M = NZ and dependencies between the bands of a pixel, not with the runtime
  // configuration (stride_params() of tools/ocp_throughput.py)
  const strideUsed = !bsq && s.m === nz && nz > 1 && s.crossRep && !(g.PeriodicUpdate_g && fid !== 'LOSSLESS') &&
    !g.RuntimeConfig_g;
  if (strideUsed) {
    let st = Math.max(s.lCross, 2);
    while (gcd(st, s.m) !== 1) st += 1;
    const skew = (s.m - 1) * (st - 1);
    const kCtx = 2 ** log2ceil(Math.floor(st / s.m) + 1);
    list.push([9, 'stride input buffer', 2 ** log2ceil(skew + s.m + 8), d, true]);
    list.push([10, 'stride output buffer', 2 ** log2ceil(skew + 2 * s.depth + 16), d, true]);
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
    data: mems.reduce((sum, m) => sum + m.depth * m.width, 0),
    stored: mems.reduce((sum, m) => sum + m.depth * m.codeword, 0),
  };
}
