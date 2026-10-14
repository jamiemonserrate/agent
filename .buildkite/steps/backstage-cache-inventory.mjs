import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import * as fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { gzipSync, gunzipSync } from 'node:zlib';

const manifestName = '.cache-benchmark-files.jsonl.gz';
const ignored = new Set([manifestName, '.cache-benchmark-seed']);
const hash = data => createHash('sha256').update(data).digest('hex');

function inventory(root) {
  const entries = [];
  function walk(relative) {
    for (const name of fs.readdirSync(path.join(root, relative)).sort()) {
      if (!relative && ignored.has(name)) continue;
      const file = path.join(relative, name);
      const absolute = path.join(root, file);
      const stat = fs.lstatSync(absolute);
      const entry = { path: file, mode: stat.mode & 0o777 };
      if (stat.isSymbolicLink()) {
        entries.push({ ...entry, type: 'symlink', target: fs.readlinkSync(absolute) });
      } else if (stat.isDirectory()) {
        entries.push({ ...entry, type: 'directory' });
        walk(file);
      } else {
        assert(stat.isFile(), `Unsupported file type: ${file}`);
        entries.push({ ...entry, type: 'file', bytes: stat.size, sha256: hash(fs.readFileSync(absolute)) });
      }
    }
  }
  walk('');
  return entries;
}

function record(mode, root, output) {
  assert(['seed', 'verify'].includes(mode), 'Specify seed or verify');
  const entries = inventory(root);
  const data = Buffer.from(entries.map(entry => JSON.stringify(entry)).join('\n') + '\n');
  const manifest = path.join(root, manifestName);
  if (mode === 'verify') {
    assert.equal(hash(data), hash(gunzipSync(fs.readFileSync(manifest))), 'Restored dependency inventory differs from the seed');
  } else {
    fs.writeFileSync(manifest, gzipSync(data));
  }
  const files = entries.filter(entry => entry.type === 'file');
  assert(files.length > 0, 'No regular dependency files found');
  const sizes = files.map(file => file.bytes).sort((a, b) => a - b);
  const quantile = fraction => sizes[Math.ceil(sizes.length * fraction) - 1];
  const bounds = [4096, 65536, 1048576, Infinity];
  const profile = {
    scope: 'Backstage root node_modules; benchmark manifest and seed marker excluded',
    regular_file_count: files.length,
    directory_count: entries.filter(entry => entry.type === 'directory').length,
    symlink_count: entries.filter(entry => entry.type === 'symlink').length,
    regular_file_bytes: files.reduce((sum, file) => sum + file.bytes, 0),
    median_file_bytes: (sizes[Math.floor((sizes.length - 1) / 2)] + sizes[Math.floor(sizes.length / 2)]) / 2,
    p90_file_bytes: quantile(0.9),
    p99_file_bytes: quantile(0.99),
    inventory_sha256: hash(data),
    restored_inventory_verified: mode === 'verify',
    size_buckets: bounds.map((upper, i) => {
      const lower = i === 0 ? -1 : bounds[i - 1];
      const bucket = files.filter(file => file.bytes > lower && file.bytes <= upper);
      return { min_bytes: lower + 1, max_bytes: upper === Infinity ? null : upper,
        file_count: bucket.length, bytes: bucket.reduce((sum, file) => sum + file.bytes, 0) };
    }),
    largest_files: [...files].sort((a, b) => b.bytes - a.bytes).slice(0, 10),
  };
  fs.mkdirSync(output, { recursive: true });
  fs.copyFileSync(manifest, path.join(output, 'file-inventory.jsonl.gz'));
  fs.writeFileSync(path.join(output, 'file-profile.json'), JSON.stringify(profile, null, 2) + '\n');
  return profile;
}

if (process.argv[2] === '--self-check') {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'backstage-inventory-'));
  try {
    const root = path.join(temp, 'modules');
    const output = path.join(temp, 'results');
    fs.mkdirSync(path.join(root, 'nested'), { recursive: true });
    fs.writeFileSync(path.join(root, 'a.js'), 'hello');
    fs.writeFileSync(path.join(root, 'nested', 'b.json'), '{}');
    fs.symlinkSync('a.js', path.join(root, 'link'));
    const profile = record('seed', root, output);
    assert.equal(profile.regular_file_count, 2);
    assert.equal(profile.regular_file_bytes, 7);
    assert.equal(profile.symlink_count, 1);
    assert.equal(record('verify', root, output).restored_inventory_verified, true);
    fs.writeFileSync(path.join(root, 'a.js'), 'changed');
    assert.throws(() => record('verify', root, output), /differs from the seed/);
    fs.writeFileSync(path.join(root, 'a.js'), 'hello');
    fs.unlinkSync(path.join(root, 'link'));
    fs.symlinkSync('nested/b.json', path.join(root, 'link'));
    assert.throws(() => record('verify', root, output), /differs from the seed/);
    console.log('Inventory self-check passed, including changed-file and changed-symlink detection.');
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
} else {
  const [mode, root, output] = process.argv.slice(2);
  assert(root && output, 'Usage: node backstage-cache-inventory.mjs seed|verify ROOT RESULTS');
  console.log(JSON.stringify(record(mode, root, output)));
}
