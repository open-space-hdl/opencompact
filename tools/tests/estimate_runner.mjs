// ---------------------------------------------------------------------------------------------------
// Copyright (c) 2026 by Julian Schneider
// Authors: Julian Schneider
// ---------------------------------------------------------------------------------------------------
// Runs ocp_resources.mjs for a JSON file of generics sets and prints the results as JSON (one entry per set):
//   node tools/tests/estimate_runner.mjs <generics.json>
// tools/tests/test_ocp_estimate.py compares the output with the Python functions of tools/ocp_estimate.py.
import { readFileSync } from 'node:fs';
import { memories, ramBits } from '../estimate/ocp_resources.mjs';

const sets = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const out = sets.map((g) => ({ memories: memories(g), ramBits: ramBits(g) }));
process.stdout.write(JSON.stringify(out));
