import * as THREE from './vendor/three.module.js';
import { createDesk, createChair, createPlant, createSofa, createCoffeeTable } from './voxel-assets.js';

/*
 * A small Nordic office world, authored in metres.  The room is intentionally
 * roofless: the camera can read the complete floor plan, while the back and left
 * walls give the scene enough scale to feel architectural.  Furniture remains a
 * separate library so this file only describes placement, materials and navigation.
 */

const PALETTE = {
  plaster: 0xf1eee5,
  plasterWarm: 0xe6e0d3,
  paleWood: 0xc9a579,
  trim: 0x53615b,
  sage: 0x9dbba0,
  sageDark: 0x627b69,
  peach: 0xe7b29a,
  butter: 0xe6d58e,
  terracotta: 0xb97d61,
  ink: 0x253b35,
  glass: 0xd7ebe4,
  brass: 0xc5a66d,
};

function mat(color, options = {}) {
  return new THREE.MeshStandardMaterial({ color, roughness: .78, metalness: 0, ...options });
}

function box(parent, name, size, position, material, options = {}) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
  mesh.name = name; mesh.position.set(...position);
  if (options.rotation) mesh.rotation.set(...options.rotation);
  mesh.castShadow = options.castShadow !== false; mesh.receiveShadow = options.receiveShadow !== false;
  parent.add(mesh); return mesh;
}

function canvasTexture(draw, width = 256, height = 256, nearest = false) {
  if (typeof document === 'undefined') return null;
  const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height;
  const context = canvas.getContext('2d'); draw(context, width, height);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 2;
  if (nearest) { texture.minFilter = THREE.NearestFilter; texture.magFilter = THREE.NearestFilter; }
  texture.needsUpdate = true; return texture;
}

function floorTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#d8c6a7'; ctx.fillRect(0, 0, w, h);
    const plankW = w / 24;
    for (let i = 0; i < 24; i += 1) {
      ctx.fillStyle = i % 2 ? '#d5c09e' : '#ddc9ab'; ctx.fillRect(i * plankW + 1, 0, plankW - 2, h);
      ctx.strokeStyle = 'rgba(110,88,62,.20)'; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(i * plankW, 0); ctx.lineTo(i * plankW, h); ctx.stroke();
      for (let y = ((i % 2) * 31); y < h; y += 82) { ctx.strokeStyle = 'rgba(118,93,64,.18)'; ctx.beginPath(); ctx.moveTo(i * plankW + 2, y); ctx.lineTo((i + 1) * plankW - 2, y); ctx.stroke(); }
    }
  }, 256, 256, true);
}

function rugTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#d5d6c1'; ctx.fillRect(0, 0, w, h);
    const stripes = ['#b5c8ac', '#e7b39c', '#e8d88f', '#b6c9bb'];
    stripes.forEach((color, i) => { ctx.fillStyle = color; ctx.fillRect(0, i * h / 4, w, h / 4 - 2); });
    ctx.fillStyle = 'rgba(255,250,233,.54)'; ctx.fillRect(w * .16, h * .16, w * .68, h * .68);
    ctx.strokeStyle = 'rgba(94,114,93,.45)'; ctx.lineWidth = 5; ctx.strokeRect(w * .16, h * .16, w * .68, h * .68);
  }, 256, 256, true);
}

function portfolioTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#263c37'; ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = '#e8dfc8'; ctx.fillRect(14, 14, w - 28, 28);
    ctx.fillStyle = '#b6ceb3'; ctx.font = 'bold 15px monospace'; ctx.fillText('PORTFOLIO / SELECTED WORK', 24, 34);
    const cards = [[0x9ebba4, 24, 62], [0xe6b39e, 120, 62], [0xe5d991, 216, 62]];
    cards.forEach(([color, x, y], i) => { ctx.fillStyle = `#${color.toString(16).padStart(6, '0')}`; ctx.fillRect(x, y, 80, 62); ctx.fillStyle = 'rgba(30,54,47,.5)'; ctx.fillRect(x + 11, y + 43, 54, 4); ctx.fillRect(x + 11, y + 51, 34 - i * 6, 3); });
  }, 320, 160, true);
}

function addWindow(parent, material, { side = 'back', x = 0, z = 0, width = 1.8, height = 1.05 }) {
  const pane = new THREE.Mesh(new THREE.PlaneGeometry(width, height), material);
  pane.name = `${side}-window`; pane.position.set(x, 1.38, z);
  if (side === 'left') pane.rotation.y = Math.PI / 2;
  pane.castShadow = false; pane.receiveShadow = false; parent.add(pane);
  const frameMat = mat(PALETTE.trim, { roughness: .42, metalness: .35 });
  if (side === 'back') {
    box(parent, `${side}-window-sill`, [width + .16, .08, .12], [x, .8, z + .08], frameMat, { castShadow: false });
    box(parent, `${side}-window-head`, [width + .08, .055, .055], [x, 1.93, z - .015], frameMat, { castShadow: false });
    box(parent, `${side}-window-left`, [.055, height, .055], [x - width / 2, 1.38, z - .015], frameMat, { castShadow: false });
    box(parent, `${side}-window-right`, [.055, height, .055], [x + width / 2, 1.38, z - .015], frameMat, { castShadow: false });
  } else {
    box(parent, `${side}-window-sill`, [.12, .08, width + .16], [x + .08, .8, z], frameMat, { castShadow: false });
    box(parent, `${side}-window-head`, [.055, .055, width + .08], [x + .015, 1.93, z], frameMat, { castShadow: false });
    box(parent, `${side}-window-front`, [.055, height, .055], [x + .015, 1.38, z - width / 2], frameMat, { castShadow: false });
    box(parent, `${side}-window-back`, [.055, height, .055], [x + .015, 1.38, z + width / 2], frameMat, { castShadow: false });
  }
  return pane;
}

function addGlassSegment(parent, material, { x, z, width, height = 1.95, orientation = 'z', name = 'glass-panel' }) {
  const pane = new THREE.Mesh(new THREE.PlaneGeometry(width, height), material);
  pane.name = name; pane.position.set(x, height / 2 + .05, z);
  if (orientation === 'x') pane.rotation.y = Math.PI / 2;
  pane.castShadow = false; pane.receiveShadow = false; parent.add(pane);
  const trim = mat(PALETTE.trim, { roughness: .42, metalness: .34 });
  if (orientation === 'z') {
    box(parent, `${name}-top`, [width, .055, .055], [x, height + .05, z], trim, { castShadow: false });
    box(parent, `${name}-bottom`, [width, .055, .055], [x, .08, z], trim, { castShadow: false });
    box(parent, `${name}-left`, [.055, height, .055], [x - width / 2, height / 2 + .05, z], trim, { castShadow: false });
    box(parent, `${name}-right`, [.055, height, .055], [x + width / 2, height / 2 + .05, z], trim, { castShadow: false });
  } else {
    box(parent, `${name}-top`, [.055, .055, width], [x, height + .05, z], trim, { castShadow: false });
    box(parent, `${name}-bottom`, [.055, .055, width], [x, .08, z], trim, { castShadow: false });
    box(parent, `${name}-near`, [.055, height, .055], [x, height / 2 + .05, z - width / 2], trim, { castShadow: false });
    box(parent, `${name}-far`, [.055, height, .055], [x, height / 2 + .05, z + width / 2], trim, { castShadow: false });
  }
  return pane;
}

function place(group, position, rotation = 0) {
  group.position.set(position[0], position[1] || 0, position[2]); group.rotation.y = rotation; return group;
}

function seatOffset(position, rotation) {
  const offset = new THREE.Vector3(0, 0, .92).applyAxisAngle(new THREE.Vector3(0, 1, 0), rotation);
  return [position[0] + offset.x, 0, position[2] + offset.z];
}

function addLeftWallArt(parent, z, baseMaterial, accentA, accentB, name) {
  // The two panels sit in the narrow piers between windows, so they decorate the
  // wall without turning glazing into an opaque painted surface.
  box(parent, `${name}-back`, [.045, .62, .48], [-6.82, 1.42, z], baseMaterial, { castShadow: false });
  box(parent, `${name}-peach`, [.025, .22, .20], [-6.78, 1.55, z - .10], accentA, { castShadow: false });
  box(parent, `${name}-sage`, [.025, .18, .17], [-6.78, 1.29, z + .11], accentB, { castShadow: false });
}

function addPendant(parent, x, z, practicals) {
  const lampMat = mat(PALETTE.butter, { color: PALETTE.butter, emissive: 0xd4a74c, emissiveIntensity: .7, roughness: .35 });
  box(parent, 'floating pendant cord', [.012, .55, .012], [x, 2.3, z], mat(PALETTE.trim, { roughness: .35, metalness: .35 }), { castShadow: false });
  const bulb = new THREE.Mesh(new THREE.SphereGeometry(.08, 8, 6), lampMat); bulb.name = 'floating warm lamp'; bulb.position.set(x, 2.0, z); bulb.castShadow = false; parent.add(bulb);
  const light = new THREE.PointLight(0xffd9a5, .42, 4.3, 1.8); light.position.set(x, 1.96, z); light.castShadow = false; practicals.push(light);
}

export function createNordicRoom(agents = []) {
  const group = new THREE.Group(); group.name = 'Nordic voxel office';
  const exterior = new THREE.Group(); exterior.name = 'exterior supplied by root scene';
  const practicals = [];
  const floorMat = mat(0xffffff, { map: floorTexture(), roughness: .82 });
  const rugMat = mat(0xffffff, { map: rugTexture(), roughness: .96 });
  const plaster = mat(PALETTE.plaster, { roughness: .92 });
  const plasterWarm = mat(PALETTE.plasterWarm, { roughness: .94 });
  const trim = mat(PALETTE.trim, { roughness: .42, metalness: .38 });
  const paleWood = mat(PALETTE.paleWood, { roughness: .75 });
  const sage = mat(PALETTE.sage, { roughness: .84 });
  const peach = mat(PALETTE.peach, { roughness: .84 });
  const butter = mat(PALETTE.butter, { roughness: .84 });
  const glass = new THREE.MeshPhysicalMaterial({ color: PALETTE.glass, roughness: .24, transmission: .08, transparent: true, opacity: .12, side: THREE.DoubleSide, depthWrite: false });
  const displayMat = mat(0xffffff, { map: portfolioTexture(), roughness: .68, emissive: 0x263c37, emissiveIntensity: .08 });
  const deskPodRugMat = mat(0xdcc8b4, { roughness: .98 });
  const artBase = mat(0xe6decb, { roughness: .94 });

  box(group, 'pale oak floor', [14, .14, 11], [0, -.07, 0], floorMat, { castShadow: false });
  // Wall openings are real gaps, not glass painted over a solid wall.  Low sills,
  // high heads and narrow piers leave the windows open for the root exterior layer.
  box(group, 'back wall window sill', [14, .72, .18], [0, .36, -5.5], plaster);
  box(group, 'back wall window head', [14, .35, .18], [0, 1.925, -5.5], plaster);
  [[-6.4, 1.2], [-3.8, .6], [-.75, 2.1], [2.35, .7], [5.7, 2.6]].forEach(([x, width], i) => box(group, `back wall pier ${i}`, [width, 1.2, .18], [x, 1.325, -5.5], plaster));
  box(group, 'left wall window sill', [.18, .72, 11], [-7, .36, 0], plaster);
  box(group, 'left wall window head', [.18, .35, 11], [-7, 1.925, 0], plaster);
  [[-5.125, .75], [-2.35, 1.0], [.55, 1.0], [3.225, .55], [5.45, .1]].forEach(([z, depth], i) => box(group, `left wall pier ${i}`, [.18, 1.2, depth], [-7, 1.325, z], plaster));
  box(group, 'right low plinth', [.18, .42, 11], [7, .21, 0], plasterWarm);
  box(group, 'front low plinth', [14, .42, .18], [0, .21, 5.5], plasterWarm);
  box(group, 'back wall baseboard', [14, .12, .15], [0, .12, -5.39], trim, { castShadow: false });
  box(group, 'left wall baseboard', [.15, .12, 11], [-6.9, .12, 0], trim, { castShadow: false });
  box(group, 'back wall cap', [14, .08, .12], [0, 2.03, -5.4], plasterWarm, { castShadow: false });

  [-4.95, -2.65, 1.15, 3.55].forEach((x) => addWindow(group, glass, { side: 'back', x, z: -5.38, width: 1.7, height: .95 }));
  [-3.8, -.9, 2.0, 4.45].forEach((z) => addWindow(group, glass, { side: 'left', x: -6.89, z, width: 1.9, height: .95 }));
  addLeftWallArt(group, -2.35, artBase, peach, sage, 'left-wall-art-lower');
  addLeftWallArt(group, 3.22, artBase, butter, peach, 'left-wall-art-upper');

  // A low credenza turns the long front-left wall into a lived-in working edge.
  const credenza = new THREE.Group(); credenza.name = 'low left credenza and books'; group.add(credenza);
  box(credenza, 'credenza back', [.08, .68, 1.22], [-6.82, .42, 3.72], trim, { castShadow: false });
  box(credenza, 'credenza top', [.55, .07, 1.30], [-6.54, .79, 3.72], paleWood);
  box(credenza, 'credenza lower shelf', [.50, .055, 1.18], [-6.54, .15, 3.72], paleWood, { castShadow: false });
  box(credenza, 'credenza upper shelf', [.50, .045, 1.18], [-6.54, .47, 3.72], paleWood, { castShadow: false });
  [-1, 1].forEach((side) => box(credenza, `credenza side ${side}`, [.50, .68, .055], [-6.54, .42, 3.72 + side * .60], paleWood, { castShadow: false }));
  [[3.28, .26, peach], [3.48, .21, butter], [3.74, .29, sage], [4.02, .19, peach]].forEach(([z, h, material], i) => box(credenza, `stacked pixel book ${i}`, [.28, .035 + h * .02, .16], [-6.23, .22 + i * .018, z], material, { castShadow: false }));
  const credenzaPlant = place(createPlant(.72), [-6.25, 0, 4.18], .15); credenzaPlant.name = 'small credenza plant'; credenza.add(credenzaPlant);

  // Private room shell at the back-left.  The opening stays clear so agents can
  // route to the owner desk without walking through a glass pane.
  const privateRoom = new THREE.Group(); privateRoom.name = 'owner private room'; group.add(privateRoom);
  const privateRug = new THREE.Mesh(new THREE.PlaneGeometry(4.15, 3.35), rugMat); privateRug.name = 'pale green office rug'; privateRug.rotation.x = -Math.PI / 2; privateRug.position.set(-4.6, .006, -3.45); privateRug.receiveShadow = true; privateRoom.add(privateRug);
  addGlassSegment(privateRoom, glass, { x: -2.4, z: -3.45, width: 3.5, orientation: 'x', name: 'owner-side-glass' });
  addGlassSegment(privateRoom, glass, { x: -5.2, z: -1.7, width: 2.95, orientation: 'z', name: 'owner-front-glass-left' });
  addGlassSegment(privateRoom, glass, { x: -2.5, z: -1.7, width: .18, orientation: 'z', name: 'owner-front-glass-right' });
  box(privateRoom, 'office-door-threshold', [1.05, .025, .14], [-3.15, .02, -1.38], trim, { castShadow: false, receiveShadow: false });
  box(privateRoom, 'office-door-left-jamb', [.06, 2.0, .06], [-3.7, 1.05, -1.7], trim, { castShadow: false });
  box(privateRoom, 'office-door-right-jamb', [.06, 2.0, .06], [-2.6, 1.05, -1.7], trim, { castShadow: false });
  box(privateRoom, 'office-door-head', [1.1, .06, .06], [-3.15, 2.03, -1.7], trim, { castShadow: false });
  const backWindow = addWindow(privateRoom, glass, { side: 'back', x: -4.55, z: -5.38, width: 2.35, height: 1.05 });

  const ownerDeskPosition = [-4.6, 0, -3.4];
  const ownerDesk = place(createDesk({ executive: true }), ownerDeskPosition, Math.PI);
  ownerDesk.name = 'owner executive desk'; privateRoom.add(ownerDesk);
  const ownerChair = place(createChair(), [-4.6, 0, -4.2], Math.PI); ownerChair.name = 'owner chair'; ownerChair.userData.facing = 0; privateRoom.add(ownerChair);
  const officeVisitor = place(createChair(), [-4.6, 0, -2.45], 0); officeVisitor.name = 'office visitor chair'; officeVisitor.userData.facing = Math.PI; privateRoom.add(officeVisitor);

  // Portfolio panel is a deliberate interactive target, above the executive desk.
  const portfolioFrame = box(privateRoom, 'portfolio display frame', [1.92, .82, .075], [-3.05, 2.46, -5.36], trim);
  const portfolioScreen = new THREE.Mesh(new THREE.PlaneGeometry(1.72, .62), displayMat);
  portfolioScreen.name = 'portfolio wall display'; portfolioScreen.position.set(-3.05, 2.46, -5.31); portfolioScreen.castShadow = false; privateRoom.add(portfolioScreen);
  portfolioScreen.userData.hitTarget = 'portfolio';

  const stationLayouts = [
    { x: -4.6, z: 1.1, rotation: 0 },
    { x: -2.2, z: 1.1, rotation: Math.PI },
    { x: -.6, z: -3.6, rotation: 0 },
    { x: 1.6, z: -3.6, rotation: 0 },
    { x: -.85, z: 2.95, rotation: 0 },
    { x: .75, z: 2.95, rotation: Math.PI },
  ];
  const stations = [];
  (agents.length ? agents : [{ id: 'agent-1', name: 'Agent 1' }, { id: 'agent-2', name: 'Agent 2' }, { id: 'agent-3', name: 'Agent 3' }, { id: 'agent-4', name: 'Agent 4' }]).forEach((agent, index) => {
    const layout = stationLayouts[index % stationLayouts.length];
    const pos = [layout.x, 0, layout.z];
    const desk = place(createDesk(), pos, layout.rotation); desk.name = `${agent.name || agent.id || `agent-${index}`} workstation`; group.add(desk);
    const seat = seatOffset(pos, layout.rotation);
    const chair = place(createChair(), seat, layout.rotation); chair.name = `${agent.name || agent.id || `agent-${index}`} chair`; group.add(chair);
    stations.push({ id: agent.id || `agent-${index}`, position: pos, seat, rotation: layout.rotation, facing: layout.rotation + Math.PI, desk, chair });
  });

  // Lounge is a softer, open composition on the right rather than another row of
  // desks: two sofas, two chairs and a low table on a warm Nordic rug.
  const lounge = new THREE.Group(); lounge.name = 'open lounge'; group.add(lounge);
  const loungeRug = new THREE.Mesh(new THREE.PlaneGeometry(5.55, 4.15), rugMat); loungeRug.name = 'sage peach butter lounge rug'; loungeRug.rotation.x = -Math.PI / 2; loungeRug.position.set(3.9, .008, 2.15); loungeRug.receiveShadow = true; lounge.add(loungeRug);
  const sofaRight = place(createSofa(), [5.65, 0, 2.3], -Math.PI / 2); sofaRight.name = 'right lounge sofa'; lounge.add(sofaRight);
  const sofaFront = place(createSofa(), [3.55, 0, .28], 0); sofaFront.name = 'front lounge sofa'; lounge.add(sofaFront);
  const loungeChairA = place(createChair(), [2.2, 0, 2.65], -Math.PI / 2); loungeChairA.name = 'lounge armchair sage'; lounge.add(loungeChairA);
  const loungeChairB = place(createChair(), [5.35, 0, .2], Math.PI); loungeChairB.name = 'lounge armchair butter'; lounge.add(loungeChairB);
  const coffeeTable = place(createCoffeeTable(), [3.95, 0, 1.68], 0); coffeeTable.name = 'lounge coffee table'; lounge.add(coffeeTable);
  const loungeSeats = [
    { position: [5.65, 0, 2.3], rotation: -Math.PI / 2 },
    { position: [5.65, 0, 1.5], rotation: -Math.PI / 2 },
    { position: [5.65, 0, 3.1], rotation: -Math.PI / 2 },
    { position: [2.75, 0, .28], rotation: 0 },
    { position: [3.55, 0, .28], rotation: 0 },
    { position: [4.35, 0, .28], rotation: 0 },
    { position: [2.2, 0, 2.65], rotation: -Math.PI / 2 },
  ];

  const deskPodRug = new THREE.Mesh(new THREE.PlaneGeometry(4.5, 2.8), deskPodRugMat);
  deskPodRug.name = 'muted peach desk pod rug'; deskPodRug.rotation.x = -Math.PI / 2; deskPodRug.position.set(-3.4, .006, 1.3); deskPodRug.receiveShadow = true; group.add(deskPodRug);

  // Coffee/bar/plant zone at the back-right keeps the active work corridor open.
  const service = new THREE.Group(); service.name = 'coffee and plant corner'; group.add(service);
  box(service, 'coffee bar base', [2.45, .72, .52], [4.95, .38, -4.63], paleWood);
  box(service, 'coffee bar top', [2.6, .08, .64], [4.95, .79, -4.58], trim);
  box(service, 'coffee shelf', [2.3, .055, .28], [4.95, 1.62, -4.92], paleWood, { castShadow: false });
  [4.1, 4.6, 5.15, 5.65].forEach((x, i) => box(service, `coffee-cup-${i}`, [.13, .16, .13], [x, 1.76, -4.8], i % 2 ? sage : peach, { castShadow: false }));
  box(service, 'coffee machine', [.46, .35, .34], [4.45, 1.0, -4.4], trim);
  box(service, 'coffee machine highlight', [.28, .12, .016], [4.45, 1.14, -4.22], butter, { castShadow: false });
  const servicePlant = place(createPlant(1.35), [5.95, 0, -4.25], 0); servicePlant.name = 'large back-right plant'; service.add(servicePlant);
  box(service, 'plant plinth', [.75, .12, .75], [5.95, .06, -4.25], peach, { castShadow: false });
  const privatePlantFront = place(createPlant(1.0), [-6.25, 0, -.95], .2); privatePlantFront.name = 'private room front plant'; group.add(privatePlantFront);
  const privatePlantSide = place(createPlant(1.15), [-6.2, 0, 2.15], -.3); privatePlantSide.name = 'private room side plant'; group.add(privatePlantSide);
  const deskPodPlant = place(createPlant(.82), [-5.9, 0, .7], -.2); deskPodPlant.name = 'low plant divider'; group.add(deskPodPlant);

  addPendant(group, -3.1, .75, practicals); addPendant(group, 3.55, 2.5, practicals); addPendant(group, 4.6, -2.7, practicals);
  // Small broad-area lamps keep the open room readable when root switches to dusk.
  [[-4.0, 2.35, -3.0], [0, 2.4, 1.2], [4.2, 2.35, 1.4]].forEach(([x, y, z], i) => { const light = new THREE.PointLight(0xffe0b1, .25, 5, 1.7); light.name = `nordic-practical-${i}`; light.position.set(x, y, z); light.castShadow = false; practicals.push(light); });

  const ownerSeat = [-4.6, 0, -4.2];
  const officeSeat = [-4.6, 0, -2.45];
  const officeDoor = [-3.15, 0, -1.4];
  const hitTargets = {
    lounge: [sofaRight, sofaFront, loungeChairA, loungeChairB, coffeeTable],
    owner: [ownerDesk, ownerChair, officeVisitor],
    portfolio: [portfolioScreen, portfolioFrame],
  };
  const footprint = (position, rotation = 0, width = 1.7, depth = .82, pad = .06) => {
    const rotated = Math.abs(Math.sin(rotation)) > .7;
    const halfX = (rotated ? depth : width) / 2 + pad;
    const halfZ = (rotated ? width : depth) / 2 + pad;
    return { minX: position[0] - halfX, maxX: position[0] + halfX, minZ: position[2] - halfZ, maxZ: position[2] + halfZ };
  };
  const stationFootprints = stations.map((station) => footprint(station.position, station.rotation));
  const obstacles = [
    { minX: -7.1, maxX: -6.8, minZ: -5.6, maxZ: 5.6 }, { minX: -7.1, maxX: 7.1, minZ: -5.6, maxZ: -5.32 },
    { minX: 6.8, maxX: 7.1, minZ: -5.6, maxZ: 5.6 }, { minX: -7.1, maxX: 7.1, minZ: 5.32, maxZ: 5.6 },
    { minX: -6.75, maxX: -2.42, minZ: -5.28, maxZ: -5.22 }, { minX: -2.46, maxX: -2.34, minZ: -5.25, maxZ: -1.66 },
    { minX: -6.75, maxX: -3.7, minZ: -1.76, maxZ: -1.62 }, { minX: -2.58, maxX: -2.34, minZ: -1.76, maxZ: -1.62 },
    { minX: -6.86, maxX: -6.08, minZ: 3.05, maxZ: 4.38 },
    footprint(ownerDeskPosition, Math.PI), ...stationFootprints,
    { minX: 4.35, maxX: 6.85, minZ: 1.1, maxZ: 3.45 }, { minX: 2.35, maxX: 4.8, minZ: -.2, maxZ: .8 },
    { minX: 3.6, maxX: 6.25, minZ: -5.1, maxZ: -4.15 },
  ];
  group.userData.obstacles = obstacles;
  group.userData.officeDoor = officeDoor;
  group.userData.stations = stations;

  return {
    group,
    stations,
    ownerSeat,
    ownerSeatRotation: 0,
    officeSeat,
    officeSeatRotation: Math.PI,
    officeDoor,
    loungeSeats,
    hitTargets,
    portfolioScreen,
    practicals,
    exterior: { group: exterior, leftWindows: [], backWindows: [backWindow] },
    obstacles,
    animate: (time = 0) => { loungeRug.material.opacity = .98 + Math.sin(time * .001) * .01; },
  };
}

export default createNordicRoom;
