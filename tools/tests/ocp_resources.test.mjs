// SPDX-License-Identifier: MIT
// The resource estimate in JavaScript (tools/estimate/ocp_resources.mjs) against the Python functions
// (tools/tests/golden_ocp_models.json, written by tools/ocp_estimate_golden.py): every case of the checks of the
// estimate, the configurations of the regression, the runtime configurations and parameters, variants and the
// synthesis sweep, with the generics as the Composer holds them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { eccCodewordWidth, estimateResources, memories, ramBits } from '../estimate/ocp_resources.mjs';

const golden = JSON.parse(readFileSync(new URL('./golden_ocp_models.json', import.meta.url), 'utf-8'));
/** @type {{ name: string, generics: Record<string, any>, estimate: any }[]} */
const cases = golden.resources;

test('the golden data covers the configurations of the regression and of the sweep', () => {
  assert.ok(cases.length >= 119, `${cases.length}`);
  assert.equal(cases.filter((c) => /^r\d\d_random$/.test(c.name)).length, 24);
});

test('the estimate equals the Python function for every case', () => {
  for (const c of cases) {
    assert.deepEqual(estimateResources(c.generics), c.estimate, c.name);
  }
});

test('the bits are the sums over the memories', () => {
  for (const c of cases) {
    const mems = memories(c.generics);
    const bits = ramBits(c.generics);
    assert.equal(bits.data, mems.reduce((s, m) => s + m.depth * m.width, 0), c.name);
    assert.equal(bits.stored, mems.reduce((s, m) => s + m.depth * m.codeword, 0), c.name);
  }
});

test('SECDED codeword widths', () => {
  assert.deepEqual([1, 4, 11, 16, 26, 57, 104].map(eccCodewordWidth), [4, 8, 16, 22, 32, 64, 112]);
});
