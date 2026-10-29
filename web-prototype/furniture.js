import * as THREE from './vendor/three.module.js';

// A small, deliberately restrained furniture library for the office scene.  All
// dimensions are metres and all roots are centred on a useful floor plan origin.
// The parts use ordinary Three.js primitives so the scene stays fast in a browser
// while still having real thickness, edge highlights and believable shadow mass.

const _cache = new Map();
const _mat = new Map();

function makeCanvasTexture(canvas, repeat = 2) {
  const texture = new THREE.CanvasTexture(canvas);
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.repeat.set(repeat, repeat);
  if ('colorSpace' in texture && THREE.SRGBColorSpace) texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  texture.needsUpdate = true;
  return texture;
}

// Generate low contrast maps locally so the materials remain self-contained.
// The guard keeps this module importable from Node for syntax checks and tests.
function makeWoodMaps() {
  if (typeof document === 'undefined') return { map: null, bumpMap: null };
  const size = 512;
  const colorCanvas = document.createElement('canvas');
  const bumpCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = bumpCanvas.width = bumpCanvas.height = size;
  const color = colorCanvas.getContext('2d');
  const bump = bumpCanvas.getContext('2d');
  const base = color.createLinearGradient(0, 0, size, size * 0.35);
  base.addColorStop(0, '#a87149');
  base.addColorStop(0.5, '#8e5b38');
  base.addColorStop(1, '#b27d50');
  color.fillStyle = base;
  color.fillRect(0, 0, size, size);
  bump.fillStyle = '#9b9b9b';
  bump.fillRect(0, 0, size, size);
  for (let i = -40; i < size + 80; i += 16) {
    const y = i + Math.sin(i * 0.17) * 4;
    color.beginPath();
    color.moveTo(-20, y);
    color.bezierCurveTo(size * 0.26, y - 7, size * 0.52, y + 6, size + 20, y - 3);
    color.strokeStyle = i % 48 === 0 ? 'rgba(54,29,17,.19)' : 'rgba(255,214,155,.10)';
    color.lineWidth = i % 48 === 0 ? 1.8 : 0.8;
    color.stroke();
    bump.beginPath();
    bump.moveTo(-20, y);
    bump.bezierCurveTo(size * 0.26, y - 7, size * 0.52, y + 6, size + 20, y - 3);
    bump.strokeStyle = i % 48 === 0 ? 'rgba(55,55,55,.42)' : 'rgba(215,215,215,.20)';
    bump.lineWidth = i % 48 === 0 ? 1.3 : 0.7;
    bump.stroke();
  }
  for (let i = 0; i < 115; i += 1) {
    const x = (i * 83) % size;
    const y = (i * 47 + Math.sin(i) * 19) % size;
    color.strokeStyle = 'rgba(43,24,14,.16)';
    color.lineWidth = 0.7;
    color.beginPath();
    color.ellipse(x, y, 4 + (i % 5), 1 + (i % 2), 0.2, 0, Math.PI * 2);
    color.stroke();
    bump.fillStyle = 'rgba(57,57,57,.25)';
    bump.fillRect(x - 2, y - 1, 4, 2);
  }
  return { map: makeCanvasTexture(colorCanvas, 2.2), bumpMap: makeCanvasTexture(bumpCanvas, 2.2) };
}

function makeFabricMaps() {
  if (typeof document === 'undefined') return { map: null, bumpMap: null };
  const size = 256;
  const colorCanvas = document.createElement('canvas');
  const bumpCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = bumpCanvas.width = bumpCanvas.height = size;
  const color = colorCanvas.getContext('2d');
  const bump = bumpCanvas.getContext('2d');
  color.fillStyle = '#d2c9b9';
  color.fillRect(0, 0, size, size);
  bump.fillStyle = '#a5a5a5';
  bump.fillRect(0, 0, size, size);
  color.lineWidth = bump.lineWidth = 1;
  for (let i = -size; i < size * 2; i += 7) {
    color.strokeStyle = i % 14 === 0 ? 'rgba(101,91,76,.11)' : 'rgba(255,255,255,.17)';
    color.beginPath(); color.moveTo(i, 0); color.lineTo(i + size, size); color.stroke();
    color.strokeStyle = 'rgba(119,109,92,.08)';
    color.beginPath(); color.moveTo(i, size); color.lineTo(i + size, 0); color.stroke();
    bump.strokeStyle = i % 14 === 0 ? 'rgba(64,64,64,.28)' : 'rgba(215,215,215,.16)';
    bump.beginPath(); bump.moveTo(i, 0); bump.lineTo(i + size, size); bump.stroke();
    bump.strokeStyle = 'rgba(210,210,210,.12)';
    bump.beginPath(); bump.moveTo(i, size); bump.lineTo(i + size, 0); bump.stroke();
  }
  return { map: makeCanvasTexture(colorCanvas, 3), bumpMap: makeCanvasTexture(bumpCanvas, 3) };
}

function makeMeshMaps() {
  if (typeof document === 'undefined') return { map: null, bumpMap: null };
  const size = 256;
  const colorCanvas = document.createElement('canvas');
  const bumpCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = bumpCanvas.width = bumpCanvas.height = size;
  const color = colorCanvas.getContext('2d');
  const bump = bumpCanvas.getContext('2d');
  color.fillStyle = '#383e40';
  color.fillRect(0, 0, size, size);
  bump.fillStyle = '#8e8e8e';
  bump.fillRect(0, 0, size, size);
  for (let i = -size; i < size * 2; i += 5) {
    color.strokeStyle = i % 10 === 0 ? 'rgba(214,225,219,.09)' : 'rgba(8,12,13,.14)';
    color.lineWidth = 1;
    color.beginPath(); color.moveTo(i, 0); color.lineTo(i + size, size); color.stroke();
    color.strokeStyle = i % 10 === 0 ? 'rgba(222,233,226,.06)' : 'rgba(9,12,13,.10)';
    color.beginPath(); color.moveTo(i, size); color.lineTo(i + size, 0); color.stroke();
    bump.strokeStyle = i % 10 === 0 ? 'rgba(222,222,222,.25)' : 'rgba(47,47,47,.24)';
    bump.beginPath(); bump.moveTo(i, 0); bump.lineTo(i + size, size); bump.stroke();
    bump.strokeStyle = i % 10 === 0 ? 'rgba(220,220,220,.18)' : 'rgba(53,53,53,.18)';
    bump.beginPath(); bump.moveTo(i, size); bump.lineTo(i + size, 0); bump.stroke();
  }
  return { map: makeCanvasTexture(colorCanvas, 4), bumpMap: makeCanvasTexture(bumpCanvas, 4) };
}

function makeScreenMap() {
  if (typeof document === 'undefined') return null;
  const size = 512;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#0d1920';
  ctx.fillRect(0, 0, size, size);
  ctx.fillStyle = '#1d3038';
  ctx.fillRect(22, 20, size - 44, 42);
  ctx.fillStyle = '#83ceb1';
  ctx.font = 'bold 19px ui-monospace, SFMono-Regular, Menlo, monospace';
  ctx.fillText('AGENTDESK / SESSION', 37, 47);
  ctx.fillStyle = '#69858a';
  ctx.font = '14px ui-monospace, SFMono-Regular, Menlo, monospace';
  ctx.fillText('LOCAL   READY', 371, 47);
  ctx.strokeStyle = 'rgba(123,213,180,.82)';
  ctx.lineWidth = 5;
  ctx.beginPath();
  ctx.moveTo(38, 275); ctx.lineTo(95, 236); ctx.lineTo(143, 250); ctx.lineTo(207, 172);
  ctx.lineTo(268, 198); ctx.lineTo(333, 123); ctx.lineTo(405, 148); ctx.lineTo(474, 89);
  ctx.stroke();
  ctx.strokeStyle = 'rgba(115,182,184,.18)';
  ctx.lineWidth = 2;
  for (let i = 0; i < 5; i += 1) {
    const y = 118 + i * 43;
    ctx.beginPath(); ctx.moveTo(34, y); ctx.lineTo(478, y); ctx.stroke();
  }
  ctx.fillStyle = '#72cfa6';
  ctx.font = '16px ui-monospace, SFMono-Regular, Menlo, monospace';
  ctx.fillText('quota  82%', 38, 337);
  ctx.fillStyle = '#d7ba75';
  ctx.fillText('context 42%', 38, 370);
  ctx.fillStyle = '#6e858a';
  ctx.font = '13px ui-monospace, SFMono-Regular, Menlo, monospace';
  ctx.fillText('> awaiting next task_', 38, 429);
  ctx.fillText('build  /  stable  /  14:32', 38, 456);
  return makeCanvasTexture(canvas, 1);
}

const woodMaps = makeWoodMaps();
const fabricMaps = makeFabricMaps();
const meshMaps = makeMeshMaps();
const screenMap = makeScreenMap();

function material(name, color, options = {}) {
  const keyOptions = Object.fromEntries(Object.entries(options).filter(([key]) => !['map', 'bumpMap', 'normalMap', 'emissiveMap'].includes(key)));
  const key = `${name}:${color}:${JSON.stringify(keyOptions)}`;
  if (_mat.has(key)) return _mat.get(key);
  const m = new THREE.MeshStandardMaterial({
    color,
    roughness: options.roughness ?? 0.62,
    metalness: options.metalness ?? 0,
    envMapIntensity: options.envMapIntensity ?? 0.85,
    ...options,
  });
  _mat.set(key, m);
  return m;
}

const wood = material('oak', 0xffffff, { roughness: 0.46, map: woodMaps.map, bumpMap: woodMaps.bumpMap, bumpScale: 0.0015 });
const woodEdge = material('oak-edge', 0xc1aaa0, { roughness: 0.52, map: woodMaps.map, bumpMap: woodMaps.bumpMap, bumpScale: 0.0015 });
const oakLight = material('oak-light', 0xfff5e8, { roughness: 0.48, map: woodMaps.map, bumpMap: woodMaps.bumpMap, bumpScale: 0.0015 });
const steel = material('steel', 0x313a3b, { metalness: 0.8, roughness: 0.25 });
const steelSoft = material('steel-soft', 0x677174, { metalness: 0.78, roughness: 0.3 });
const screen = material('screen', 0xffffff, {
  roughness: 0.22,
  metalness: 0.2,
  emissive: 0xffffff,
  emissiveMap: screenMap,
  emissiveIntensity: 0.5,
  map: screenMap,
});
const screenGlow = material('screen-glow', 0x78cbb4, {
  roughness: 0.36,
  emissive: 0x5cae97,
  emissiveIntensity: 0.42,
});
const keycap = material('keycap', 0x425052, { roughness: 0.38 });
const ivory = material('ivory', 0xe9e1d2, { roughness: 0.78 });
const ceramic = material('ceramic', 0xd6d0c4, { roughness: 0.6 });
const leather = material('leather', 0xffffff, { roughness: 0.88, map: meshMaps.map, bumpMap: meshMaps.bumpMap, bumpScale: 0.0015 });
const rubber = material('rubber', 0x1b2325, { roughness: 0.88, metalness: 0.03 });
const creamFabric = material('cream-fabric', 0xc9c0af, { roughness: 0.91, map: fabricMaps.map, bumpMap: fabricMaps.bumpMap, bumpScale: 0.0015 });
const creamHighlight = material('cream-highlight', 0xe0d8ca, { roughness: 0.93, map: fabricMaps.map, bumpMap: fabricMaps.bumpMap, bumpScale: 0.0015 });
const green = material('leaf', 0x5d8c62, { roughness: 0.82, side: THREE.DoubleSide });
const greenDark = material('leaf-dark', 0x315943, { roughness: 0.88, side: THREE.DoubleSide });
const terracotta = material('terracotta', 0xa8634d, { roughness: 0.82 });
const soil = material('soil', 0x382b22, { roughness: 1 });
const warmLamp = material('lamp-glow', 0xffc66e, {
  color: 0xffdf9c,
  emissive: 0xffa735,
  emissiveIntensity: 1.4,
  roughness: 0.35,
});

function roundedBox(width, height, depth, radius, mat) {
  const key = `rounded:${width}:${height}:${depth}:${radius}`;
  let geometry = _cache.get(key);
  if (!geometry) {
    const r = Math.min(radius, width * 0.5, height * 0.5);
    const shape = new THREE.Shape();
    shape.moveTo(-width / 2 + r, -height / 2);
    shape.lineTo(width / 2 - r, -height / 2);
    shape.quadraticCurveTo(width / 2, -height / 2, width / 2, -height / 2 + r);
    shape.lineTo(width / 2, height / 2 - r);
    shape.quadraticCurveTo(width / 2, height / 2, width / 2 - r, height / 2);
    shape.lineTo(-width / 2 + r, height / 2);
    shape.quadraticCurveTo(-width / 2, height / 2, -width / 2, height / 2 - r);
    shape.lineTo(-width / 2, -height / 2 + r);
    shape.quadraticCurveTo(-width / 2, -height / 2, -width / 2 + r, -height / 2);
    geometry = new THREE.ExtrudeGeometry(shape, {
      depth,
      bevelEnabled: true,
      bevelSegments: 2,
      bevelSize: Math.min(r * 0.32, 0.018),
      bevelThickness: Math.min(r * 0.28, 0.016),
      curveSegments: 4,
    });
    // ExtrudeGeometry is x/y/depth. Centre its bounding box so groups have
    // intuitive dimensions and all objects cast symmetrical shadows.
    geometry.translate(0, 0, -depth / 2);
    geometry.computeVertexNormals();
    _cache.set(key, geometry);
  }
  return new THREE.Mesh(geometry, mat);
}

function box(width, height, depth, mat, bevel = 0) {
  return bevel ? roundedBox(width, height, depth, bevel, mat) : new THREE.Mesh(new THREE.BoxGeometry(width, height, depth), mat);
}

function cylinder(radiusTop, radiusBottom, height, mat, radial = 20) {
  return new THREE.Mesh(new THREE.CylinderGeometry(radiusTop, radiusBottom, height, radial), mat);
}

function shadowed(object) {
  object.traverse((node) => {
    if (node.isMesh) {
      node.castShadow = true;
      node.receiveShadow = true;
    }
  });
  return object;
}

function torus(major, minor, mat) {
  return new THREE.Mesh(new THREE.TorusGeometry(major, minor, 10, 28), mat);
}

function addKeyboard(parent) {
  const keyboard = new THREE.Group();
  const plate = box(0.53, 0.022, 0.19, keycap, 0.022);
  plate.position.set(0, 0.022, 0);
  keyboard.add(plate);
  const rows = [10, 10, 9, 7];
  rows.forEach((count, row) => {
    for (let i = 0; i < count; i += 1) {
      const key = box(row === 3 && i === 3 ? 0.11 : 0.039, 0.012, 0.027, ivory, 0.006);
      const span = row === 3 && i === 3 ? 0.11 : 0.039;
      const x = (i - (count - 1) / 2) * 0.051 + (row % 2 ? 0.012 : 0);
      const z = (row - 1.5) * 0.039;
      key.position.set(x, 0.041, z);
      key.scale.x = span / 0.039;
      keyboard.add(key);
    }
  });
  // The plate's underside rests just above the 0.75 m desktop surface.
  keyboard.position.set(-0.01, 0.74, 0.13);
  parent.add(keyboard);
  return keyboard;
}

function addMonitor(parent) {
  const monitor = new THREE.Group();
  const body = box(0.67, 0.41, 0.045, steel, 0.028);
  body.position.set(0, 1.03, -0.17);
  monitor.add(body);
  // Screen materials are per-monitor: status/selection effects on one desk
  // must never change the neighbouring desks.
  const screenMaterial = screen.clone();
  const panel = box(0.60, 0.335, 0.014, screenMaterial, 0.012);
  panel.position.set(0, 1.03, -0.144);
  monitor.add(panel);
  // A restrained UI reflection and a status line make the glass read as a screen
  // without hard-coding any product branding into the furniture library.
  const glow = box(0.48, 0.006, 0.006, screenGlow, 0.002);
  glow.position.set(-0.035, 1.11, -0.134);
  monitor.add(glow);
  const glow2 = box(0.31, 0.005, 0.006, screenGlow, 0.002);
  glow2.position.set(-0.12, 0.99, -0.134);
  monitor.add(glow2);
  const webcam = cylinder(0.021, 0.021, 0.028, steelSoft, 14);
  webcam.rotation.x = Math.PI / 2;
  webcam.position.set(0, 1.255, -0.147);
  monitor.add(webcam);
  const neck = cylinder(0.031, 0.031, 0.08, steelSoft, 16);
  neck.position.set(0, 0.83, -0.17);
  monitor.add(neck);
  const foot = roundedBox(0.28, 0.025, 0.15, 0.012, steelSoft);
  foot.position.set(0, 0.77, -0.17);
  monitor.add(foot);
  parent.add(monitor);
  monitor.userData.screen = screenMaterial;
  monitor.userData.pickMeshes = [body, panel];
  return monitor;
}

function addDeskLamp(parent) {
  const lamp = new THREE.Group();
  const base = cylinder(0.09, 0.11, 0.028, steelSoft, 24);
  base.position.set(0.59, 0.78, 0.06);
  lamp.add(base);
  const lower = cylinder(0.012, 0.012, 0.30, steelSoft, 12);
  lower.position.set(0.59, 0.94, 0.06);
  lower.rotation.z = -0.12;
  lamp.add(lower);
  const shade = new THREE.Mesh(new THREE.ConeGeometry(0.095, 0.14, 24, 1, true), steelSoft);
  shade.position.set(0.62, 1.10, 0.02);
  shade.rotation.z = -0.22;
  lamp.add(shade);
  const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.035, 14, 10), warmLamp);
  bulb.position.set(0.63, 1.06, 0.01);
  lamp.add(bulb);
  parent.add(lamp);
  return lamp;
}

export function createDesk({ agent = {}, index = 0 } = {}) {
  const group = new THREE.Group();
  group.name = `desk-${agent.id || index}`;

  const top = roundedBox(1.70, 0.045, 0.82, 0.025, wood);
  top.position.y = 0.7275;
  group.add(top);
  // A slightly darker front edge catches grazing light and establishes the slab's
  // real thickness when the camera moves around the desk.
  const edge = box(1.58, 0.025, 0.018, woodEdge, 0.006);
  edge.position.set(0, 0.704, 0.402);
  group.add(edge);

  const legX = [-0.71, 0.71];
  const legZ = [-0.29, 0.29];
  legX.forEach((x) => legZ.forEach((z) => {
    const leg = cylinder(0.028, 0.031, 0.69, steel, 16);
    leg.position.set(x, 0.35, z);
    group.add(leg);
    const foot = cylinder(0.045, 0.045, 0.018, steelSoft, 16);
    foot.position.set(x, 0.015, z);
    group.add(foot);
  }));
  const modesty = box(1.38, 0.30, 0.022, woodEdge, 0.012);
  modesty.position.set(0, 0.55, -0.34);
  modesty.material = material('modesty', 0x805437, { roughness: 0.65 });
  group.add(modesty);

  const drawer = roundedBox(0.42, 0.10, 0.37, 0.014, woodEdge);
  drawer.position.set(0.49, 0.65, 0.20);
  group.add(drawer);
  const handle = cylinder(0.012, 0.012, 0.18, steelSoft, 12);
  handle.rotation.z = Math.PI / 2;
  handle.position.set(0.49, 0.65, 0.395);
  group.add(handle);

  addMonitor(group);
  addKeyboard(group);
  const mouse = new THREE.Mesh(new THREE.SphereGeometry(0.038, 18, 10), ceramic);
  mouse.scale.set(1.1, 0.48, 1.35);
  mouse.position.set(0.36, 0.775, 0.13);
  group.add(mouse);
  const mouseLine = box(0.006, 0.003, 0.11, steelSoft, 0.002);
  mouseLine.position.set(0.36, 0.778, 0.22);
  mouseLine.rotation.x = -0.2;
  group.add(mouseLine);

  const notebook = roundedBox(0.30, 0.012, 0.21, 0.008, ivory);
  notebook.position.set(-0.46, 0.758, 0.13);
  notebook.rotation.y = -0.06;
  group.add(notebook);
  for (let i = 0; i < 3; i += 1) {
    const line = box(0.19, 0.002, 0.004, screenGlow, 0.001);
    line.position.set(-0.46, 0.767 + i * 0.004, 0.13 + (i - 1) * 0.04);
    group.add(line);
  }
  const mug = new THREE.Mesh(new THREE.CylinderGeometry(0.045, 0.040, 0.085, 20), ceramic);
  mug.position.set(-0.60, 0.795, 0.12);
  group.add(mug);
  const coffee = new THREE.Mesh(new THREE.CylinderGeometry(0.035, 0.034, 0.004, 20), material('coffee', 0x3b2418, { roughness: 0.24 }));
  coffee.position.set(-0.60, 0.837, 0.12);
  group.add(coffee);
  const mugHandle = torus(0.027, 0.007, ceramic);
  mugHandle.rotation.y = Math.PI / 2;
  mugHandle.position.set(-0.557, 0.795, 0.12);
  group.add(mugHandle);
  addDeskLamp(group);

  // The object deliberately exposes the screen and pickable meshes so the scene
  // controller can highlight or raycast a whole desk without DOM overlays.
  group.userData.screen = group.children.find((child) => child.userData?.screen)?.userData.screen || null;
  group.userData.pickMeshes = [];
  group.traverse((node) => { if (node.isMesh) group.userData.pickMeshes.push(node); });
  shadowed(group);
  return group;
}

export function createChair() {
  const chair = new THREE.Group();
  chair.name = 'ergonomic-chair';
  const seat = roundedBox(0.58, 0.13, 0.52, 0.055, leather);
  seat.position.set(0, 0.48, 0);
  chair.add(seat);
  const cushion = roundedBox(0.48, 0.045, 0.38, 0.035, material('seat-mesh', 0x383e40, { roughness: 0.90, map: meshMaps.map, bumpMap: meshMaps.bumpMap, bumpScale: 0.04 }));
  cushion.position.set(0, 0.555, -0.01);
  chair.add(cushion);
  const back = roundedBox(0.56, 0.66, 0.12, 0.06, leather);
  back.position.set(0, 0.86, 0.22);
  back.rotation.x = -0.11;
  chair.add(back);
  const lumbar = roundedBox(0.40, 0.17, 0.04, 0.018, material('lumbar', 0x383e40, { roughness: 0.90, map: meshMaps.map, bumpMap: meshMaps.bumpMap, bumpScale: 0.0015 }));
  lumbar.position.set(0, 0.77, 0.145);
  lumbar.rotation.x = -0.1;
  chair.add(lumbar);
  const column = cylinder(0.055, 0.065, 0.36, steel, 20);
  column.position.set(0, 0.24, 0);
  chair.add(column);
  const hub = cylinder(0.11, 0.12, 0.06, steel, 20);
  hub.position.set(0, 0.10, 0);
  chair.add(hub);
  for (let i = 0; i < 5; i += 1) {
    const angle = (Math.PI * 2 * i) / 5;
    const arm = box(0.39, 0.03, 0.035, steel, 0.012);
    arm.position.set(Math.cos(angle) * 0.16, 0.085, Math.sin(angle) * 0.16);
    arm.rotation.y = -angle;
    chair.add(arm);
    const wheelStem = cylinder(0.018, 0.018, 0.10, steelSoft, 12);
    wheelStem.position.set(Math.cos(angle) * 0.34, 0.095, Math.sin(angle) * 0.34);
    chair.add(wheelStem);
    // Twin rubber castors: each wheel has a horizontal axle and sits just above
    // the floor, so the chair never appears to sink below the room plane.
    const perpX = -Math.sin(angle) * 0.018;
    const perpZ = Math.cos(angle) * 0.018;
    [-1, 1].forEach((side) => {
      const wheel = new THREE.Mesh(new THREE.CylinderGeometry(0.042, 0.042, 0.028, 16), rubber);
      wheel.rotation.z = Math.PI / 2;
      wheel.rotation.y = -angle;
      wheel.position.set(Math.cos(angle) * 0.34 + perpX * side, 0.045, Math.sin(angle) * 0.34 + perpZ * side);
      chair.add(wheel);
    });
  }
  [-1, 1].forEach((side) => {
    const arm = cylinder(0.022, 0.022, 0.16, steelSoft, 12);
    arm.position.set(side * 0.34, 0.65, 0.08);
    chair.add(arm);
    const pad = roundedBox(0.12, 0.035, 0.25, 0.018, leather);
    pad.position.set(side * 0.34, 0.74, 0.08);
    chair.add(pad);
  });
  shadowed(chair);
  return chair;
}

function leafGeometry(length, width) {
  const segments = 8;
  const positions = [];
  for (let i = 0; i <= segments; i += 1) {
    const t = i / segments;
    const taper = Math.pow(Math.sin(Math.PI * t), 0.72);
    const halfWidth = width * taper;
    const bend = Math.sin(Math.PI * t) * length * 0.045;
    // Three cross-section points create a shallow centre ridge rather than a
    // paper-thin plane.  The centre row is fractionally lifted toward the light.
    positions.push(length * t, -halfWidth, bend * 0.35);
    positions.push(length * t, 0, bend + length * 0.012 * taper);
    positions.push(length * t, halfWidth, bend * 0.35);
  }
  const indices = [];
  for (let i = 0; i < segments; i += 1) {
    const row = i * 3;
    const next = (i + 1) * 3;
    indices.push(row, next, row + 1, row + 1, next, next + 1);
    indices.push(row + 1, next + 1, row + 2, row + 2, next + 1, next + 2);
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setIndex(indices);
  geometry.computeVertexNormals();
  return geometry;
}

function leafVeinGeometry(length) {
  const curve = new THREE.CatmullRomCurve3([
    new THREE.Vector3(0, 0, 0.018),
    new THREE.Vector3(length * 0.38, 0, length * 0.045 + 0.018),
    new THREE.Vector3(length, 0, 0.018),
  ]);
  return new THREE.TubeGeometry(curve, 8, 0.0045, 5, false);
}

export function createPlant({ height = 1.6 } = {}) {
  const plant = new THREE.Group();
  plant.name = 'leafy-plant';
  const potHeight = Math.max(0.24, height * 0.2);
  const pot = new THREE.Mesh(new THREE.CylinderGeometry(height * 0.14, height * 0.18, potHeight, 28), terracotta);
  pot.position.y = potHeight / 2;
  plant.add(pot);
  const rim = new THREE.Mesh(new THREE.TorusGeometry(height * 0.14, height * 0.018, 8, 28), terracotta);
  rim.rotation.x = Math.PI / 2;
  rim.position.y = potHeight;
  plant.add(rim);
  const earth = new THREE.Mesh(new THREE.CylinderGeometry(height * 0.125, height * 0.125, 0.018, 24), soil);
  earth.position.y = potHeight + 0.008;
  plant.add(earth);
  const branchCount = 14;
  for (let i = 0; i < branchCount; i += 1) {
    const angle = (i / branchCount) * Math.PI * 2 + 0.35;
    const lean = height * (0.10 + (i % 4) * 0.025);
    const heightFactor = 0.38 + (i % 8) * 0.075 + (i % 3) * 0.012;
    const base = new THREE.Vector3(0, potHeight + 0.01, 0);
    const tip = new THREE.Vector3(Math.cos(angle) * lean, potHeight + height * heightFactor, Math.sin(angle) * lean);
    const stemCurve = new THREE.CatmullRomCurve3([base, new THREE.Vector3(tip.x * 0.4, potHeight + height * (0.22 + (i % 3) * 0.035), tip.z * 0.4), tip]);
    const stem = new THREE.Mesh(new THREE.TubeGeometry(stemCurve, 10, Math.max(0.008, height * 0.012), 8, false), greenDark);
    plant.add(stem);
    const length = height * (0.25 + (i % 4) * 0.025);
    const leafRoot = new THREE.Group();
    leafRoot.position.copy(tip);
    leafRoot.rotation.set(-0.25 + (i % 3) * 0.18, -angle, 0.18 * Math.sin(angle));
    const leaf = new THREE.Mesh(leafGeometry(length, height * 0.055), i % 2 ? green : greenDark);
    leafRoot.add(leaf);
    const vein = new THREE.Mesh(leafVeinGeometry(length), greenDark);
    leafRoot.add(vein);
    plant.add(leafRoot);
  }
  shadowed(plant);
  return plant;
}

export function createSofa() {
  const sofa = new THREE.Group();
  sofa.name = 'cream-sofa';
  const frame = roundedBox(2.20, 0.34, 0.76, 0.09, creamFabric);
  frame.position.y = 0.22;
  sofa.add(frame);
  const seat = roundedBox(1.80, 0.16, 0.58, 0.075, creamHighlight);
  seat.position.set(0, 0.40, 0.05);
  sofa.add(seat);
  const back = roundedBox(1.86, 0.50, 0.20, 0.07, creamFabric);
  back.position.set(0, 0.64, -0.25);
  sofa.add(back);
  [-1, 1].forEach((side) => {
    const arm = roundedBox(0.22, 0.48, 0.72, 0.08, creamFabric);
    arm.position.set(side * 1.0, 0.53, 0);
    sofa.add(arm);
  });
  [-0.58, 0, 0.58].forEach((x) => {
    const seam = box(0.008, 0.13, 0.50, material('seam', 0xa39b8d, { roughness: 0.96 }), 0.002);
    seam.position.set(x, 0.49, 0.05);
    sofa.add(seam);
  });
  [-0.83, 0.83].forEach((x) => [-0.25, 0.25].forEach((z) => {
    const foot = cylinder(0.045, 0.055, 0.18, woodEdge, 16);
    foot.position.set(x, 0.09, z);
    sofa.add(foot);
  }));
  shadowed(sofa);
  return sofa;
}

export function createCoffeeTable() {
  const table = new THREE.Group();
  table.name = 'coffee-table';
  const top = roundedBox(1.16, 0.075, 0.62, 0.035, oakLight);
  top.position.y = 0.45;
  table.add(top);
  const shelf = roundedBox(0.77, 0.035, 0.38, 0.016, woodEdge);
  shelf.position.set(0, 0.16, 0);
  table.add(shelf);
  [-1, 1].forEach((x) => [-1, 1].forEach((z) => {
    const leg = cylinder(0.024, 0.028, 0.42, steelSoft, 16);
    leg.position.set(x * 0.43, 0.22, z * 0.20);
    table.add(leg);
  }));
  shadowed(table);
  return table;
}

export function createPendant() {
  const pendant = new THREE.Group();
  pendant.name = 'pendant-light';
  const cord = cylinder(0.008, 0.008, 1.15, steel, 10);
  cord.position.y = -0.575;
  pendant.add(cord);
  const canopy = cylinder(0.11, 0.09, 0.045, steelSoft, 24);
  canopy.position.y = -1.16;
  pendant.add(canopy);
  const shade = new THREE.Mesh(new THREE.ConeGeometry(0.26, 0.23, 32, 1, true), material('pendant-shade', 0xb9a47d, { roughness: 0.58, side: THREE.DoubleSide }));
  shade.position.y = -1.28;
  shade.rotation.x = Math.PI;
  pendant.add(shade);
  const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.065, 16, 10), warmLamp);
  bulb.position.y = -1.28;
  pendant.add(bulb);
  shadowed(pendant);
  return pendant;
}

export function createFurnitureKit() {
  return { createDesk, createChair, createPlant, createSofa, createCoffeeTable, createPendant };
}

export default createFurnitureKit;
