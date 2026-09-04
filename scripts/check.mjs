import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const profiles = ['stable', 'standard', 'responsive'].map(name =>
  JSON.parse(readFileSync(`config/profiles/${name}.json`, 'utf8'))
);
for (const profile of profiles) {
  assert.equal(profile.schema_version, 1);
  assert.ok(profile.drone.mass_kg <= 0.3, `${profile.name}: F9A-B mass exceeds 300 g`);
  assert.ok(profile.drone.cage_diameter_m <= 0.22, `${profile.name}: cage exceeds 22 cm`);
  assert.ok(profile.drone.thrust_to_weight > 1);
  assert.deepEqual(new Set(Object.values(profile.input.mapping)).size, 4, `${profile.name}: input axes must be unique`);
  for (const axis of ['pitch', 'roll', 'yaw']) {
    assert.ok(Number.isFinite(profile.pid[axis].p));
    assert.ok(profile.rates[axis].max_deg_s >= 30 && profile.rates[axis].max_deg_s <= 1500);
    assert.ok(profile.rates[axis].expo >= 0 && profile.rates[axis].expo <= 1);
  }
}

for (const schema of ['schemas/profile.schema.json', 'schemas/control-message.schema.json']) {
  const parsed = JSON.parse(readFileSync(schema, 'utf8'));
  assert.ok(parsed.$schema && parsed.type === 'object', `${schema}: malformed schema`);
}

const project = readFileSync('project.godot', 'utf8');
for (const match of project.matchAll(/res:\/\/[^"\n]+/g)) {
  const localPath = match[0].replace('res://', '');
  assert.ok(existsSync(localPath), `Missing project resource: ${localPath}`);
}

const jsCheck = spawnSync(process.execPath, ['--check', 'web/controller/app.js'], { encoding: 'utf8' });
assert.equal(jsCheck.status, 0, jsCheck.stderr);
const controllerHtml = readFileSync('web/controller/index.html', 'utf8');
for (const requiredId of ['leftZone', 'rightZone', 'armButton', 'modeButton', 'resetButton', 'turtleButton']) {
  assert.match(controllerHtml, new RegExp(`id=["']${requiredId}["']`), `Missing controller element: ${requiredId}`);
}

console.log(`PASS: ${profiles.length} profiles, 2 schemas, project resources, and controller syntax`);

