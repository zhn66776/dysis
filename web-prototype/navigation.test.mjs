import assert from 'node:assert/strict';
import test from 'node:test';
import { createNordicRoom } from './nordic-room.js';
import { findPath } from './navigation.js';

const agents = [
  { id: 'claude', name: 'Claude' },
  { id: 'codex', name: 'Codex' },
  { id: 'grok', name: 'Grok' },
  { id: 'gemini', name: 'Gemini' },
];

const room = createNordicRoom(agents);
const actors = new Map(agents.map((agent, index) => [agent.id, { ...agent, index }]));
actors.set('owner', { id: 'owner', name: 'Owner', index: -1 });

function seatFor(id, destination) {
  const actor = actors.get(id);
  assert.ok(actor, `unknown actor: ${id}`);
  if (destination === 'lounge') {
    const seat = room.loungeSeats[id === 'owner' ? 0 : actor.index + 1];
    assert.ok(seat, `${id} has no lounge seat`);
    return { position: [...seat.position], rotation: seat.rotation, lounge: true };
  }
  if (id === 'owner') return { position: [...room.ownerSeat], rotation: room.ownerSeatRotation ?? 0 };
  if (destination === 'office') return { position: [...room.officeSeat], rotation: room.officeSeatRotation ?? Math.PI };
  const station = room.stations.find(item => item.id === id);
  assert.ok(station, `${id} has no station`);
  return { position: [...station.seat], rotation: station.facing ?? station.rotation + Math.PI };
}

// This is intentionally the same coordinate convention as scene.js.  A person
// approaches a desk from the facing direction, and approaches a lounge seat
// from the front of its cushion.
function approach(spec) {
  const r = spec.rotation;
  return spec.lounge
    ? [spec.position[0] + Math.sin(r) * .72, 0, spec.position[2] + Math.cos(r) * .72]
    : [spec.position[0] + Math.cos(r) * .62, 0, spec.position[2] - Math.sin(r) * .62];
}

function distance(a, b) { return Math.hypot(a[0] - b[0], a[2] - b[2]); }

function inside(point, obstacle, padding = 0) {
  return point[0] > obstacle.minX - padding && point[0] < obstacle.maxX + padding &&
    point[2] > obstacle.minZ - padding && point[2] < obstacle.maxZ + padding;
}

function segmentHits(a, b, obstacle, step = .04) {
  const length = distance(a, b);
  const samples = Math.max(1, Math.ceil(length / step));
  for (let i = 0; i <= samples; i += 1) {
    const t = i / samples;
    if (inside([a[0] + (b[0] - a[0]) * t, 0, a[2] + (b[2] - a[2]) * t], obstacle)) return true;
  }
  return false;
}

function route(startSpec, endSpec) {
  const source = approach(startSpec);
  const target = approach(endSpec);
  return { source, target, path: findPath(source, target, room.obstacles), startSpec, endSpec };
}

function routeFailure(label, source, target, path, obstacle) {
  return `${label} source=${JSON.stringify(source)} target=${JSON.stringify(target)} ` +
    `path=${JSON.stringify(path)} obstacle=${JSON.stringify(obstacle)}`;
}

function assertClearMiddle(label, result) {
  assert.ok(result.path, `${label} returned null: source=${JSON.stringify(result.source)} target=${JSON.stringify(result.target)}`);
  const points = result.path;
  // The approach point for a lounge seat can be inside the coarse sofa footprint
  // by design.  Its first/last motion segment is the seat-ingress motion; audit
  // every corridor segment between those endpoint motions.
  const firstSegment = result.startSpec?.lounge ? 2 : 1;
  const lastSegment = points.length - (result.endSpec?.lounge ? 1 : 0);
  for (let i = firstSegment; i < lastSegment; i += 1) {
    for (const obstacle of room.obstacles) {
      assert.ok(!segmentHits(points[i - 1], points[i], obstacle), routeFailure(label, result.source, result.target, points, obstacle));
    }
  }
}

function doorwayCrossing(result, label) {
  const threshold = -1.7;
  const doorMin = -3.7;
  const doorMax = -2.6;
  const crossings = [];
  for (let i = 1; i < result.path.length; i += 1) {
    const a = result.path[i - 1], b = result.path[i];
    if ((a[2] > threshold && b[2] <= threshold) || (a[2] <= threshold && b[2] > threshold)) {
      const t = (threshold - a[2]) / (b[2] - a[2]);
      crossings.push(a[0] + (b[0] - a[0]) * t);
    }
  }
  assert.ok(crossings.some(x => x > doorMin && x < doorMax), `${label} did not cross the open doorway: crossings=${JSON.stringify(crossings)} path=${JSON.stringify(result.path)}`);
}

function assertSeatsOutsideWalls() {
  const wallObstacles = room.obstacles.slice(0, 8);
  const seats = [room.ownerSeat, room.officeSeat, ...room.stations.map(station => station.seat), ...room.loungeSeats.map(seat => seat.position)];
  seats.forEach((seat, index) => {
    wallObstacles.forEach(obstacle => assert.ok(!inside(seat, obstacle), `seat ${index} overlaps a wall/glass obstacle: seat=${JSON.stringify(seat)} obstacle=${JSON.stringify(obstacle)}`));
  });
}

test('Nordic room seats are clear of walls and glass', () => {
  assertSeatsOutsideWalls();
});

test('all agent routes have a path and clear obstacle-free middle segments', () => {
  for (const agent of agents) {
    const desk = seatFor(agent.id, 'desk');
    const office = seatFor(agent.id, 'office');
    const lounge = seatFor(agent.id, 'lounge');
    const routes = [
      ['desk → office', desk, office],
      ['office → desk', office, desk],
      ['desk → lounge', desk, lounge],
      ['lounge → desk', lounge, desk],
    ];
    for (const [name, start, end] of routes) {
      const label = `${agent.id} ${name}`;
      const result = route(start, end);
      assertClearMiddle(label, result);
      if (name === 'desk → office' || name === 'office → desk') doorwayCrossing(result, label);
    }
  }
});

test('owner can enter the lounge and return to the executive desk', () => {
  const desk = seatFor('owner', 'desk');
  const lounge = seatFor('owner', 'lounge');
  assertClearMiddle('owner desk → lounge', route(desk, lounge));
  assertClearMiddle('owner lounge → desk', route(lounge, desk));
});

