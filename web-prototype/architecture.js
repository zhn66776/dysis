import * as THREE from './vendor/three.module.js';

/*
 * Architectural shell for the studio.  The scene is deliberately built in metres:
 * a 12m x 10.5m room, 3.6m ceilings, 720mm desk standard, and glazing with real
 * frames and sills.  Furniture is a separate concern, so this module only owns the
 * room, millwork and the light that makes those objects read as a place.
 */

const C = {
  wall: 0xe8e5dc,
  wallWarm: 0xded9cc,
  plasterShadow: 0xbcb8ac,
  bronze: 0x3f4a48,
  bronzeLight: 0x69736b,
  wood: 0x9a6945,
  woodLight: 0xc08d5d,
  woodDark: 0x563a2d,
  stone: 0x514f4a,
  cream: 0xf0ece2,
  plant: 0x587357,
  green: 0x95c49b,
  coffee: 0x25302d,
};

function canvasTexture(draw, width = 512, height = 512) {
  if (typeof document === 'undefined') return null;
  const canvas = document.createElement('canvas');
  canvas.width = width; canvas.height = height;
  const ctx = canvas.getContext('2d');
  draw(ctx, width, height);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  texture.needsUpdate = true;
  return texture;
}

function woodTexture(light = false) {
  return canvasTexture((ctx, w, h) => {
    const base = light ? '#ba865b' : '#956443';
    ctx.fillStyle = base; ctx.fillRect(0, 0, w, h);
    const grain = light ? ['#d2a178', '#9a6847', '#c09368'] : ['#b37e54', '#76503a', '#a97249'];
    for (let i = -40; i < h + 40; i += 18 + Math.random() * 17) {
      ctx.beginPath(); ctx.moveTo(0, i);
      for (let x = 0; x <= w; x += 42) ctx.quadraticCurveTo(x + 20, i + (Math.random() - .5) * 9, x + 42, i + (Math.random() - .5) * 8);
      ctx.strokeStyle = grain[Math.floor(Math.random() * grain.length)];
      ctx.globalAlpha = .22 + Math.random() * .2; ctx.lineWidth = .7 + Math.random() * 1.5; ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }, 768, 768);
}

// One continuous floor texture keeps the room from reading as a repeated tile.
// Boards are long, pale oak planks with staggered end joints and restrained grain.
function floorTexture() {
  return canvasTexture((ctx, w, h) => {
    const boards = 18;
    const boardW = w / boards;
    ctx.fillStyle = '#bd9a70'; ctx.fillRect(0, 0, w, h);
    for (let i = 0; i < boards; i += 1) {
      const tone = ['#c6a57d', '#c0a078', '#c9aa82', '#bb966c'][i % 4];
      ctx.fillStyle = tone; ctx.fillRect(i * boardW + 1, 0, boardW - 2, h);
      // Grain runs with the long direction of each plank.
      for (let line = 0; line < 13; line += 1) {
        const x = i * boardW + 4 + line * (boardW - 8) / 13;
        ctx.beginPath(); ctx.moveTo(x, 0);
        for (let y = 0; y <= h; y += 72) ctx.quadraticCurveTo(x + Math.sin(y * .027 + i) * 3, y + 34, x + Math.sin(y * .019 + line) * 2, y + 72);
        ctx.strokeStyle = line % 3 === 0 ? 'rgba(124,87,57,.16)' : 'rgba(246,223,185,.16)';
        ctx.lineWidth = line % 3 === 0 ? 1.2 : .65; ctx.stroke();
      }
      // End joints are offset on alternate rows, like real staggered flooring.
      for (let row = 0; row < 5; row += 1) {
        const y = (row + 1) * h / 6;
        const offset = (row % 2 ? .48 : .22) * boardW;
        const x = i * boardW + offset;
        ctx.beginPath(); ctx.moveTo(x, y - 2); ctx.lineTo(x, y + 2);
        ctx.strokeStyle = 'rgba(91,65,47,.27)'; ctx.lineWidth = 1.2; ctx.stroke();
      }
    }
    ctx.strokeStyle = 'rgba(91,65,47,.28)'; ctx.lineWidth = 1.4;
    for (let i = 1; i < boards; i += 1) { ctx.beginPath(); ctx.moveTo(i * boardW, 0); ctx.lineTo(i * boardW, h); ctx.stroke(); }
  }, 1024, 1024);
}

function exteriorTexture() {
  return canvasTexture((ctx, w, h) => {
    const sky = ctx.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, '#a9c2cf'); sky.addColorStop(.54, '#c7d4cc'); sky.addColorStop(1, '#e0d7bd');
    ctx.fillStyle = sky; ctx.fillRect(0, 0, w, h);
    // A distant horizon, deliberately soft and low so it never reads as a painted wall.
    ctx.fillStyle = 'rgba(92,118,91,.42)'; ctx.beginPath(); ctx.moveTo(0, h * .7);
    for (let x = 0; x <= w; x += 26) ctx.lineTo(x, h * (.61 + .05 * Math.sin(x * .021) + .018 * Math.sin(x * .073)));
    ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath(); ctx.fill();
    ctx.fillStyle = 'rgba(61,91,70,.24)';
    for (let x = -20; x < w + 80; x += 76) {
      const height = 28 + 24 * Math.abs(Math.sin(x * .17));
      ctx.beginPath(); ctx.moveTo(x, h * .72); ctx.lineTo(x + 26, h * .72 - height); ctx.lineTo(x + 51, h * .72); ctx.closePath(); ctx.fill();
    }
  }, 1024, 512);
}

function fabricTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#eee9df'; ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = 'rgba(100,95,85,.09)'; ctx.lineWidth = 1;
    for (let x = 0; x < w; x += 5) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
    for (let y = 0; y < h; y += 5) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }
  }, 256, 256);
}

function signTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#2b3733'; ctx.fillRect(0, 0, w, h);
    ctx.strokeStyle = '#b6cbaa'; ctx.lineWidth = 4; ctx.strokeRect(13, 13, w - 26, h - 26);
    ctx.fillStyle = '#e8eee2'; ctx.font = '600 34px Arial'; ctx.letterSpacing = '4px'; ctx.fillText('AGENTDESK', 28, 65);
    ctx.fillStyle = '#9bbda0'; ctx.font = '16px monospace'; ctx.fillText('STUDIO 01  /  A QUIET PLACE TO THINK', 30, 94);
  }, 640, 150);
}

function artTexture() {
  return canvasTexture((ctx, w, h) => {
    ctx.fillStyle = '#d9ded2'; ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = '#8ba88d'; ctx.beginPath(); ctx.moveTo(0, 200); ctx.bezierCurveTo(110, 80, 180, 260, 310, 78); ctx.bezierCurveTo(400, -10, 450, 180, 520, 95); ctx.lineTo(520, 310); ctx.lineTo(0, 310); ctx.fill();
    ctx.fillStyle = '#d5a26d'; ctx.beginPath(); ctx.arc(335, 92, 52, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = '#314841'; ctx.lineWidth = 8; ctx.beginPath(); ctx.moveTo(35, 235); ctx.lineTo(480, 46); ctx.stroke();
  }, 512, 340);
}

function mat(color, roughness = .65, metalness = 0, extra = {}) {
  return new THREE.MeshStandardMaterial({ color, roughness, metalness, ...extra });
}

function box(name, size, position, material, options = {}) {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(...size), material);
  mesh.name = name; mesh.position.set(...position);
  mesh.castShadow = options.castShadow !== false; mesh.receiveShadow = options.receiveShadow !== false;
  if (options.rotation) mesh.rotation.set(...options.rotation);
  return mesh;
}

function cylinder(name, radius, height, position, material, radial = 20, rotation = [0, 0, 0]) {
  const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius * 1.04, height, radial), material);
  mesh.name = name; mesh.position.set(...position); mesh.rotation.set(...rotation); mesh.castShadow = true; mesh.receiveShadow = true;
  return mesh;
}

function frame(group, name, x, y, z, width, height, material, axis = 'z') {
  const t = .055;
  const depth = .09;
  if (axis === 'z') {
    group.add(box(`${name}-left`, [depth, height, t], [x, y, z - width / 2], material));
    group.add(box(`${name}-right`, [depth, height, t], [x, y, z + width / 2], material));
    group.add(box(`${name}-top`, [depth, t, width], [x, y + height / 2, z], material));
    group.add(box(`${name}-bottom`, [depth, t, width], [x, y - height / 2, z], material));
  }
}

function addWindow(group, materials, { x, z, width = 2.38, height = 2.6, side = 'left' }) {
  const glass = new THREE.Mesh(new THREE.PlaneGeometry(width, height), materials.glass);
  glass.name = `${side}-window-glass`;
  glass.position.set(x, .63 + height / 2, z);
  glass.rotation.y = side === 'left' ? Math.PI / 2 : -Math.PI / 2;
  glass.receiveShadow = true;
  group.add(glass);
  const frameMat = materials.bronze;
  if (side === 'left') {
    frame(group, `${side}-${z}-frame`, x - .02, .63 + height / 2, z, width, height, frameMat);
    group.add(box(`${side}-${z}-mullion`, [.08, height, .04], [x - .035, .63 + height / 2, z], frameMat));
    group.add(box(`${side}-${z}-transom`, [.08, .045, width], [x - .035, 2.0, z], frameMat));
    group.add(box(`${side}-${z}-sill`, [.24, .09, width + .18], [x - .05, .57, z], materials.sill));
  } else {
    frame(group, `${side}-${z}-frame`, x + .02, .63 + height / 2, z, width, height, frameMat);
    group.add(box(`${side}-${z}-mullion`, [.08, height, .04], [x + .035, .63 + height / 2, z], frameMat));
    group.add(box(`${side}-${z}-transom`, [.08, .045, width], [x + .035, 2.0, z], frameMat));
    group.add(box(`${side}-${z}-sill`, [.24, .09, width + .18], [x + .05, .57, z], materials.sill));
  }
}

function addBooks(group, x, y, z, wood, dark) {
  const colors = [0x6e7e68, 0xc4865b, 0x5a6973, 0xcbb493, 0x7a6659];
  colors.forEach((color, i) => {
    const h = .25 + (i % 2) * .05;
    group.add(box(`book-${x}-${i}`, [.045, h, .22], [x + i * .058, y + h / 2, z], mat(color, .86), { castShadow: true }));
  });
}

export function createArchitecture() {
  const group = new THREE.Group();
  group.name = 'AgentDesk architectural shell';
  const glass = new THREE.MeshPhysicalMaterial({ color: 0xe4eeea, roughness: .2, metalness: .01, transmission: .1, transparent: true, opacity: .12, side: THREE.DoubleSide, depthWrite: false });
  // Kept separate from the glass itself so time-of-day changes never muddy every pane.
  const windowGlowMaterial = new THREE.MeshStandardMaterial({ color: 0xffe3af, emissive: 0xffd68b, emissiveIntensity: 0, transparent: true, opacity: .02, depthWrite: false, side: THREE.DoubleSide });
  const materials = {
    wall: mat(C.wall, .92), wallWarm: mat(C.wallWarm, .94), bronze: mat(C.bronze, .35, .75), bronzeLight: mat(C.bronzeLight, .32, .68),
    oak: mat(C.wood, .62, 0, { map: woodTexture(false) }), oakLight: mat(C.woodLight, .62, 0, { map: woodTexture(true) }),
    woodDark: mat(C.woodDark, .65, 0), stone: mat(C.stone, .84), cream: mat(C.cream, .95, 0, { map: fabricTexture() }), sill: mat(0xc7c0b3, .82),
    glass, windowGlow: [], windowGlowMaterial, sign: mat(0xffffff, .8, 0, { map: signTexture() }), art: mat(0xffffff, .95, 0, { map: artTexture() }),
    black: mat(C.coffee, .35, .55), green: mat(C.green, .68),
  };

  // Use the scanned hardwood maps for believable colour, grain depth and roughness.
  // The generated map remains a local fallback if the image assets are unavailable.
  const floorFallbackMap = floorTexture();
  const floorMaterial = mat(0xffffff, .78, 0, { map: floorFallbackMap });
  const floorLoader = new THREE.TextureLoader();
  const configureOak = (texture, colorSpace = false) => {
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
    texture.repeat.set(12 / 1.7, 10.55 / 1.7); texture.anisotropy = 8;
    if (colorSpace) texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
  };
  const loadFloorMap = (url, onLoad, colorSpace = false) => {
    floorLoader.load(url, (texture) => {
      configureOak(texture, colorSpace);
      onLoad(texture);
      // Assigning only after the image is decoded keeps the procedural fallback
      // valid during the first render and avoids an async needsUpdate warning.
      floorMaterial.needsUpdate = true;
    });
  };
  floorMaterial.color.set(0xffffff); floorMaterial.roughness = .85;
  loadFloorMap('./assets/wood-floor-color.jpg', (texture) => {
    floorMaterial.map = texture;
    if (floorFallbackMap && floorFallbackMap !== texture) floorFallbackMap.dispose();
  }, true);
  loadFloorMap('./assets/wood-floor-normal.jpg', (texture) => {
    floorMaterial.normalMap = texture;
    floorMaterial.normalScale.set(.22, .22);
  });
  loadFloorMap('./assets/wood-floor-roughness.jpg', (texture) => { floorMaterial.roughnessMap = texture; });
  const floor = box('continuous staggered oak floor', [12, .075, 10.55], [0, -.04, .25], floorMaterial, { castShadow: false });
  floor.receiveShadow = true; group.add(floor);
  // A real ceiling gives eye-level views a believable upper boundary.  The root
  // scene may hide this mesh for the cutaway overview camera.
  const ceilingMaterial = mat(0xe9e7df, .96, 0, { side: THREE.DoubleSide });
  const ceiling = new THREE.Mesh(new THREE.PlaneGeometry(12, 10.55), ceilingMaterial);
  ceiling.name = 'acoustic ceiling plane'; ceiling.rotation.x = Math.PI / 2; ceiling.position.set(0, 3.6, .25); ceiling.receiveShadow = true; ceiling.castShadow = true; group.add(ceiling);
  const channelMaterial = mat(0xc7c8c1, .9, 0);
  [-2.8, 2.8].forEach((x, i) => group.add(box(`recessed-ceiling-channel-${i}`, [.045, .014, 9.2], [x, 3.592, .1], channelMaterial, { castShadow: false })));
  // Back wall and its two perpendicular shadow planes.
  group.add(box('back wall', [12, 3.6, .12], [0, 1.8, -5.05], materials.wall));
  group.add(box('back-wall-baseboard', [12, .12, .16], [0, .12, -4.96], materials.sill));
  group.add(box('left lower wall', [.12, .65, 10.5], [-6.02, .325, .25], materials.wallWarm));
  group.add(box('right lower sill wall', [.12, .65, 10.5], [6.02, .325, .25], materials.wallWarm));
  group.add(box('left window head', [.12, .25, 10.5], [-6.02, 3.48, .25], materials.wallWarm));
  group.add(box('right window head', [.12, .25, 10.5], [6.02, 3.48, .25], materials.wallWarm));
  // Vertical piers around three tall windows at either side.
  [-4.5, -1.55, 1.4, 4.32].forEach((z, i) => {
    group.add(box(`left-pier-${i}`, [.12, 2.85, .22], [-6.02, 2.06, z], materials.wallWarm));
    group.add(box(`right-pier-${i}`, [.12, 2.85, .22], [6.02, 2.06, z], materials.wallWarm));
  });
  [-3.25, -.35, 2.55].forEach((z) => addWindow(group, materials, { x: -5.91, z, side: 'left' }));
  [-3.25, -.35, 2.55].forEach((z) => addWindow(group, materials, { x: 5.91, z, side: 'right' }));

  // A soft distant skyline behind the glazing.  It avoids the oversized sphere
  // trees that make a room feel like an illustration while still giving the eye a
  // real horizon to anchor the window view.
  const skyMat = new THREE.MeshBasicMaterial({ color: 0xffffff, map: exteriorTexture(), transparent: true, opacity: .62, side: THREE.DoubleSide, depthWrite: false });
  const outside = new THREE.Group(); outside.name = 'quiet exterior through windows';
  const sky = new THREE.Mesh(new THREE.PlaneGeometry(10, 3), skyMat); sky.name = 'left exterior backdrop'; sky.position.set(-6.28, 2.1, .25); sky.rotation.y = Math.PI / 2; sky.castShadow = false; sky.receiveShadow = false; outside.add(sky);
  const rightSkyMaterial = skyMat.clone();
  if (skyMat.map) {
    rightSkyMaterial.map = skyMat.map.clone();
    rightSkyMaterial.map.offset.set(.11, .025);
    rightSkyMaterial.map.needsUpdate = true;
  }
  const rightSky = new THREE.Mesh(new THREE.PlaneGeometry(10, 3), rightSkyMaterial); rightSky.name = 'right exterior backdrop'; rightSky.position.set(6.28, 2.1, .25); rightSky.rotation.y = -Math.PI / 2; rightSky.castShadow = false; rightSky.receiveShadow = false; outside.add(rightSky);
  group.add(outside);

  // Vertical oak slat feature at the rear, physically offset from the plaster.
  for (let i = 0; i < 27; i += 1) group.add(box(`oak-slat-${i}`, [.075, 2.86, .11], [-5.58 + i * .108, 2.04, -4.94], i % 3 === 0 ? materials.oakLight : materials.oak));
  const sign = new THREE.Mesh(new THREE.PlaneGeometry(2.75, .64), materials.sign); sign.name = 'physical wall sign'; sign.position.set(-1.3, 3.03, -4.925); sign.castShadow = true; group.add(sign);
  const artFrame = box('art frame', [1.62, 1.12, .07], [1.7, 2.26, -4.92], materials.bronze); group.add(artFrame);
  const art = new THREE.Mesh(new THREE.PlaneGeometry(1.42, .92), materials.art); art.name = 'abstract framed artwork'; art.position.set(1.7, 2.26, -4.87); group.add(art);

  // Low credenza and a coffee bar make the rear wall read as functional space.
  group.add(box('low storage carcass', [2.85, .72, .48], [-.35, .52, -4.68], materials.oakLight));
  group.add(box('storage top', [2.98, .075, .58], [-.35, .91, -4.66], materials.stone));
  for (let x = -1.45; x <= .75; x += .74) {
    group.add(box(`storage-door-${x}`, [.68, .57, .018], [x, .54, -4.40], materials.wallWarm));
    group.add(box(`storage-handle-${x}`, [.035, .09, .022], [x + .28, .54, -4.375], materials.bronze));
  }
  addBooks(group, -.98, .95, -4.54, materials.oak, materials.black);

  const barX = 4.35;
  group.add(box('coffee bar base', [2.65, .82, .58], [barX, .48, -4.66], materials.woodDark));
  group.add(box('coffee bar counter', [2.82, .085, .72], [barX, .94, -4.62], materials.stone));
  group.add(box('coffee backsplash', [2.64, 1.5, .06], [barX, 1.8, -4.93], materials.wallWarm));
  group.add(box('coffee shelf', [2.6, .07, .35], [barX, 2.7, -4.75], materials.oakLight));
  for (let x = 3.15; x <= 5.55; x += .8) group.add(box(`coffee-door-${x}`, [.69, .64, .025], [x, .48, -4.35], materials.woodDark));
  group.add(box('coffee machine body', [.58, .45, .4], [4.15, 1.23, -4.47], materials.black));
  group.add(cylinder('coffee machine group', .12, .2, [4.15, 1.57, -4.46], materials.black, 20));
  group.add(cylinder('coffee grinder', .1, .26, [4.65, 1.2, -4.46], materials.bronze, 18));
  [3.25, 3.72, 5.03, 5.42].forEach((x, i) => { group.add(cylinder(`shelf-mug-${i}`, .085, .18, [x, 2.84, -4.54], i % 2 ? materials.cream : materials.green, 18)); });
  group.add(box('coffee towel', [.34, .015, .22], [5.35, 1.0, -4.39], materials.cream));

  // Practical lights: the root scene may dim these when the lighting period changes.
  const practicals = [];
  [[-3.8, 3.25, -1.6], [0, 3.35, -1.1], [3.8, 3.2, -1.4]].forEach(([x, y, z], i) => {
    const light = new THREE.PointLight(0xffe2b7, .72, 6.4, 1.65); light.name = `ceiling-practical-${i}`; light.position.set(x, y, z); light.castShadow = false; practicals.push(light);
    const fixture = cylinder(`practical-fixture-${i}`, .09, .045, [x, y + .08, z], materials.bronze, 20); group.add(fixture);
  });
  const windowGlow = [windowGlowMaterial];
  return { group, glass: [glass], practicals, windowGlow, sky: skyMat, skyMaterials: [skyMat, rightSkyMaterial], ceiling };
}

export default createArchitecture;
