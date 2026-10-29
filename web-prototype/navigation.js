// A small floor-grid search. Obstacles use the same metre coordinates as the room.
export function findPath(start, end, obstacles, { step = .25, padding = .16, bounds = [-6.65, 6.65, -5.1, 5.1] } = {}) {
  const [minX, maxX, minZ, maxZ] = bounds;
  const nx = Math.floor((maxX - minX) / step) + 1;
  const nz = Math.floor((maxZ - minZ) / step) + 1;
  const pos = (key) => [minX + (key % nx) * step, 0, minZ + Math.floor(key / nx) * step];
  const blocked = new Set();
  for (let j = 0; j < nz; j++) for (let i = 0; i < nx; i++) {
    const x = minX + i * step, z = minZ + j * step;
    if (obstacles.some(o => x > o.minX - padding && x < o.maxX + padding && z > o.minZ - padding && z < o.maxZ + padding)) blocked.add(j * nx + i);
  }
  const cell = p => Math.round((Math.max(minZ, Math.min(maxZ, p[2])) - minZ) / step) * nx + Math.round((Math.max(minX, Math.min(maxX, p[0])) - minX) / step);
  const nearest = p => {
    let candidate = cell(p); if (!blocked.has(candidate)) return candidate;
    let distance = Infinity;
    for (let k = 0; k < nx * nz; k++) if (!blocked.has(k)) {
      const at = pos(k), d = Math.hypot(at[0] - p[0], at[2] - p[2]);
      if (d < distance) { distance = d; candidate = k; }
    }
    return distance < 1.1 ? candidate : null;
  };
  const first = nearest(start), goal = nearest(end);
  if (first === null || goal === null) return null;
  const heuristic = key => Math.abs(key % nx - goal % nx) + Math.abs(Math.floor(key / nx) - Math.floor(goal / nx));
  const open = new Set([first]), scores = new Map([[first, 0]]), from = new Map();
  while (open.size) {
    let current = null, best = Infinity;
    for (const key of open) { const cost = scores.get(key) + heuristic(key); if (cost < best) { best = cost; current = key; } }
    if (current === goal) {
      const keys = [current]; while (from.has(keys[0])) keys.unshift(from.get(keys[0]));
      const points = keys.map(pos); const reduced = [start];
      for (let i = 1; i < points.length - 1; i++) {
        const a = points[i - 1], b = points[i], c = points[i + 1];
        if ((b[0] - a[0]) !== (c[0] - b[0]) || (b[2] - a[2]) !== (c[2] - b[2])) reduced.push(b);
      }
      reduced.push(end); return reduced;
    }
    open.delete(current);
    const i = current % nx, j = Math.floor(current / nx);
    for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      if (i + di < 0 || i + di >= nx || j + dj < 0 || j + dj >= nz) continue;
      const next = (j + dj) * nx + i + di;
      if (blocked.has(next)) continue;
      const score = scores.get(current) + 1;
      if (score < (scores.get(next) ?? Infinity)) { from.set(next, current); scores.set(next, score); open.add(next); }
    }
  }
  return null;
}
