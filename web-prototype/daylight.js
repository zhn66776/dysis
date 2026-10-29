import * as THREE from './vendor/three.module.js';

// Exterior world and the complete room lighting rig.  Geometry stays outside
// the room's x[-7,7], z[-5.5,5.5] envelope so the same module works with a
// cutaway overhead camera and with the side windows.

const PERIODS = ['dawn', 'morning', 'noon', 'afternoon', 'dusk', 'night'];
const PERIOD_NAMES = { dawn: '清晨', morning: '上午', noon: '中午', afternoon: '下午', dusk: '黄昏', night: '夜晚' };
const REPRESENTATIVE = { dawn: 6.5, morning: 9.5, noon: 12.5, afternoon: 15.5, dusk: 18.5, night: 22.0 };
const PALETTE = {
  dawn: { top: '#6e8194', bottom: '#e6b183', horizon: '#f7d2a4', sun: '#ffd397', ambient: '#9eb2bd', ground: '#3e4b45', sunIntensity: 1.05, ambientIntensity: .68, bounce: .24, warm: .82, glow: .42 },
  morning: { top: '#a8c4ce', bottom: '#e7dfc3', horizon: '#f6e7c7', sun: '#fff0c1', ambient: '#b4c7c5', ground: '#6f7d6c', sunIntensity: 1.35, ambientIntensity: .82, bounce: .32, warm: .44, glow: .18 },
  noon: { top: '#86b9d0', bottom: '#e6ede3', horizon: '#edf0df', sun: '#fff9e1', ambient: '#c2d6d4', ground: '#768771', sunIntensity: 1.62, ambientIntensity: 1.02, bounce: .39, warm: .20, glow: .08 },
  afternoon: { top: '#82aebd', bottom: '#e4d7b4', horizon: '#edd8ae', sun: '#ffe0a1', ambient: '#a9beb7', ground: '#6a7863', sunIntensity: 1.45, ambientIntensity: .88, bounce: .34, warm: .42, glow: .18 },
  dusk: { top: '#485b74', bottom: '#e1a06e', horizon: '#ecae74', sun: '#ffb06f', ambient: '#77818b', ground: '#3b4841', sunIntensity: .76, ambientIntensity: .58, bounce: .22, warm: 1.0, glow: .72 },
  night: { top: '#0d1b2b', bottom: '#2b4551', horizon: '#607078', sun: '#93a9c8', ambient: '#405568', ground: '#1e2b2f', sunIntensity: .11, ambientIntensity: .28, bounce: .12, warm: .68, glow: 1.0 },
};

const C = {
  grass: 0xc6c8b3,
  grassLight: 0xbcc4aa,
  trunk: 0x746351,
  foliage: 0x687d66,
  foliageLight: 0x89977a,
  cottage: 0xc9c6bb,
  cottageWarm: 0xbdb9ad,
  roof: 0x69736e,
  roofWarm: 0x766d66,
  trim: 0xede5d2,
  darkWindow: 0x263b3d,
  cloud: 0xe8e9e0,
};

function color(value) { return new THREE.Color(value); }

function box(w, h, d, material) {
  return new THREE.Mesh(new THREE.BoxGeometry(w, h, d), material);
}

function mat(value, options = {}) {
  return new THREE.MeshStandardMaterial({
    color: value,
    roughness: options.roughness ?? .86,
    metalness: options.metalness ?? 0,
    emissive: options.emissive ?? 0,
    emissiveIntensity: options.emissiveIntensity ?? 0,
    transparent: options.transparent ?? false,
    opacity: options.opacity ?? 1,
    flatShading: true,
  });
}

function shadowed(root, receive = true, cast = true) {
  root.traverse((node) => {
    if (node.isMesh) {
      node.castShadow = cast;
      node.receiveShadow = receive;
    }
  });
  return root;
}

function createTree(height = 3.0) {
  const tree = new THREE.Group();
  tree.name = 'voxel-exterior-tree';
  const trunk = mat(C.trunk, { roughness: 1 });
  const leaf = mat(C.foliage, { roughness: .95 });
  const leafLight = mat(C.foliageLight, { roughness: .94 });
  const trunkMesh = box(.22, height * .62, .22, trunk);
  trunkMesh.position.y = height * .31;
  tree.add(trunkMesh);
  const tiers = [
    { y: height * .53, w: height * .52, d: height * .42, m: leaf },
    { y: height * .73, w: height * .68, d: height * .52, m: leafLight },
    { y: height * .93, w: height * .46, d: height * .38, m: leaf },
  ];
  tiers.forEach((tier, index) => {
    const crown = box(tier.w, height * (index === 1 ? .30 : .26), tier.d, tier.m);
    crown.position.set(index % 2 ? -.03 : .03, tier.y, index === 2 ? .01 : 0);
    tree.add(crown);
  });
  // Small offset blocks break the perfect cube silhouette while remaining voxel
  // enough to read from above.
  [-1, 1].forEach((side) => {
    const branch = box(.16, height * .10, .16, leafLight);
    branch.position.set(side * height * .21, height * .56, 0);
    tree.add(branch);
  });
  shadowed(tree);
  return tree;
}

function gableRoof(width, height, depth, material) {
  const vertices = new Float32Array([
    -width / 2, 0, -depth / 2, width / 2, 0, -depth / 2, 0, height, -depth / 2,
    -width / 2, 0, depth / 2, width / 2, 0, depth / 2, 0, height, depth / 2,
  ]);
  const indices = [0, 1, 2, 3, 5, 4, 0, 3, 4, 0, 4, 1, 1, 4, 5, 1, 5, 2, 2, 5, 3, 2, 3, 0];
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
  geometry.setIndex(indices);
  geometry.computeVertexNormals();
  return new THREE.Mesh(geometry, material);
}

function createCottage(index = 0) {
  const cottage = new THREE.Group();
  cottage.name = `distant-nordic-cottage-${index}`;
  const wall = mat(index % 2 ? C.cottageWarm : C.cottage, { roughness: .92 });
  const roofMat = mat(index % 2 ? C.roofWarm : C.roof, { roughness: .94 });
  const trim = mat(C.trim, { roughness: .88 });
  const window = mat(C.darkWindow, { roughness: .28, emissive: 0xc28b54, emissiveIntensity: 0 });
  const width = 2.20 + (index % 2) * .32;
  const depth = 1.70;
  const wallMesh = box(width, 1.25, depth, wall);
  wallMesh.position.y = .625;
  cottage.add(wallMesh);
  const roof = gableRoof(width + .25, .62, depth + .28, roofMat);
  roof.position.y = 1.25;
  cottage.add(roof);
  const door = box(.32, .70, .035, trim);
  door.position.set(index % 2 ? -.38 : .38, .35, depth / 2 + .021);
  cottage.add(door);
  [-.72, .72].forEach((x) => {
    const windowMesh = box(.34, .25, .025, window);
    windowMesh.position.set(x, .70, depth / 2 + .024);
    windowMesh.userData.cityGlow = window;
    cottage.add(windowMesh);
  });
  const chimney = box(.18, .46, .18, roofMat);
  chimney.position.set(index % 2 ? .40 : -.40, 1.55, -.18);
  cottage.add(chimney);
  cottage.userData.windowMaterial = window;
  shadowed(cottage);
  return cottage;
}

function createCloud() {
  const cloud = new THREE.Group();
  cloud.name = 'slow-drifting-cloud';
  const cloudMat = mat(C.cloud, { roughness: 1, transparent: true, opacity: .72 });
  [[0, 0, 0, 1.0], [.48, .05, .04, .76], [-.50, -.02, .01, .72], [.18, .18, -.03, .62]].forEach(([x, y, z, scale]) => {
    const puff = box(.75 * scale, .30 * scale, .42 * scale, cloudMat);
    puff.position.set(x, y, z);
    cloud.add(puff);
  });
  cloud.userData.speed = .010 + Math.random() * .007;
  // Clouds drift continuously; keeping them out of the 2048² shadow map avoids
  // a stale shadow trail while they move across the sky.
  shadowed(cloud, false, false);
  return cloud;
}

function createStars() {
  const count = 42;
  const positions = new Float32Array(count * 3);
  for (let i = 0; i < count; i += 1) {
    positions[i * 3] = -14 + ((i * 37) % 28);
    positions[i * 3 + 1] = 4.7 + ((i * 17) % 55) / 10;
    positions[i * 3 + 2] = -14 - ((i * 13) % 5);
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  const material = new THREE.PointsMaterial({ color: 0xf3e8bf, size: .045, transparent: true, opacity: 0, depthWrite: false, sizeAttenuation: true });
  const stars = new THREE.Points(geometry, material);
  stars.name = 'quiet-night-stars';
  return stars;
}

function makeSkyCanvas() {
  if (typeof document === 'undefined') return { canvas: null, texture: null };
  const canvas = document.createElement('canvas');
  canvas.width = 768;
  canvas.height = 384;
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.needsUpdate = true;
  return { canvas, texture };
}

function drawSky(canvas, palette, sunHeight = .65) {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  const gradient = ctx.createLinearGradient(0, 0, 0, h);
  gradient.addColorStop(0, palette.top);
  gradient.addColorStop(.58, palette.bottom);
  gradient.addColorStop(1, palette.horizon);
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, w, h);
  const sunHex = `#${color(palette.sun).getHexString()}`;
  const glow = ctx.createRadialGradient(w * .65, h * (1 - sunHeight) * .7, 0, w * .65, h * (1 - sunHeight) * .7, h * .55);
  glow.addColorStop(0, `${sunHex}88`);
  glow.addColorStop(.36, `${sunHex}22`);
  glow.addColorStop(1, `${sunHex}00`);
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, w, h);
  ctx.fillStyle = 'rgba(255,255,255,.055)';
  for (let i = 0; i < 7; i += 1) {
    ctx.fillRect((i * 139) % w, h * (.22 + (i % 3) * .08), 70 + (i % 2) * 38, 2);
  }
}

function periodForHour(hour) {
  if (hour < 5 || hour >= 20) return 'night';
  if (hour < 8) return 'dawn';
  if (hour < 11) return 'morning';
  if (hour < 14) return 'noon';
  if (hour < 17) return 'afternoon';
  return 'dusk';
}

function samplePalette(decimalHour) {
  let hour = decimalHour % 24;
  if (hour < 0) hour += 24;
  const points = [
    { h: 2, period: 'night' }, { h: 6.5, period: 'dawn' }, { h: 9.5, period: 'morning' },
    { h: 12.5, period: 'noon' }, { h: 15.5, period: 'afternoon' }, { h: 18.5, period: 'dusk' },
    { h: 22, period: 'night' }, { h: 26, period: 'night' },
  ];
  const searchHour = hour < 2 ? hour + 24 : hour;
  let left = points[0];
  let right = points[1];
  for (let i = 0; i < points.length - 1; i += 1) {
    if (searchHour >= points[i].h && searchHour <= points[i + 1].h) { left = points[i]; right = points[i + 1]; break; }
  }
  const t = Math.max(0, Math.min(1, (searchHour - left.h) / (right.h - left.h)));
  const a = PALETTE[left.period];
  const b = PALETTE[right.period];
  const lerpColor = (key) => color(a[key]).lerp(color(b[key]), t).getStyle();
  const value = (key) => a[key] + (b[key] - a[key]) * t;
  const phase = ((searchHour - 5) / 15) * Math.PI;
  return {
    period: periodForHour(hour),
    top: lerpColor('top'), bottom: lerpColor('bottom'), horizon: lerpColor('horizon'), sun: lerpColor('sun'),
    ambient: lerpColor('ambient'), ground: lerpColor('ground'), sunIntensity: value('sunIntensity'),
    ambientIntensity: value('ambientIntensity'), bounce: value('bounce'), warm: value('warm'), glow: value('glow'),
    sunHeight: Math.max(.08, Math.sin(Math.max(0, Math.min(Math.PI, phase))) * .78),
  };
}

export function createDaylight(scene) {
  const world = new THREE.Group();
  world.name = 'daylight exterior world';
  const previousBackground = scene.background;
  const sky = makeSkyCanvas();
  if (sky.texture) scene.background = sky.texture;

  const groundMat = mat(C.grass, { roughness: 1 });
  // Keep the exterior as a shallow rear strip rather than a second room-sized
  // floor; its front edge is safely behind z=-7.
  const rearGround = box(18, .06, 2.8, groundMat);
  rearGround.position.set(0, -.25, -8.6);
  world.add(rearGround);
  const leftGround = box(2.25, .06, 8.6, mat(C.grassLight, { roughness: 1 }));
  leftGround.position.set(-9.15, -.25, -.8);
  world.add(leftGround);

  [-6.3, 1.6, 6.8].forEach((x, index) => {
    const cottage = createCottage(index);
    cottage.scale.setScalar(.72);
    cottage.position.set(x * .88, 0, -9.55 - (index % 2) * .42);
    cottage.rotation.y = index % 2 ? .045 : -.035;
    world.add(cottage);
  });
  [-6.4, -1.8, 2.5, 6.2].forEach((x, index) => {
    const tree = createTree(1.85 + (index % 3) * .22);
    tree.position.set(x, 0, -7.7 - (index % 2) * .45);
    tree.rotation.y = index * .4;
    world.add(tree);
  });
  [-9.4, -10.8, -12.1].forEach((x, index) => {
    const tree = createTree(1.70 + index * .20);
    tree.position.set(x, 0, -3.0 + index * 2.7);
    tree.rotation.y = index * .8;
    world.add(tree);
  });

  const clouds = [];
  [-4.8, 2.0, 8.3].forEach((x, index) => {
    const cloud = createCloud();
    cloud.position.set(x, 4.3 + (index % 2) * .38, -13 - index * .5);
    cloud.scale.setScalar(.72 + (index % 2) * .12);
    clouds.push(cloud);
    world.add(cloud);
  });
  const stars = createStars();
  world.add(stars);
  const sunDisc = new THREE.Mesh(new THREE.SphereGeometry(.22, 12, 8), new THREE.MeshBasicMaterial({ color: 0xffd58d, transparent: true, opacity: .95 }));
  sunDisc.name = 'distant-sun-disc';
  world.add(sunDisc);
  const moonDisc = new THREE.Mesh(new THREE.SphereGeometry(.20, 12, 8), new THREE.MeshBasicMaterial({ color: 0xd5e2ef, transparent: true, opacity: .9 }));
  moonDisc.name = 'distant-moon-disc';
  world.add(moonDisc);
  const cityGlows = [];
  world.traverse((node) => { if (node.userData?.cityGlow) cityGlows.push(node.userData.cityGlow); });
  scene.add(world);

  const sun = new THREE.DirectionalLight(0xffd59a, 1.2);
  sun.name = 'daylight sun';
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  sun.shadow.camera.left = -7; sun.shadow.camera.right = 7;
  sun.shadow.camera.top = 5.5; sun.shadow.camera.bottom = -5.5;
  sun.shadow.camera.near = .1; sun.shadow.camera.far = 44;
  sun.shadow.bias = -0.0003;
  const target = new THREE.Object3D();
  target.position.set(0, 0, 0);
  scene.add(target);
  sun.target = target;
  scene.add(sun);
  const ambient = new THREE.HemisphereLight(0xaec5c8, 0x556451, .82);
  ambient.name = 'daylight hemisphere bounce';
  scene.add(ambient);
  const bounce = new THREE.AmbientLight(0x9aab9c, .28);
  bounce.name = 'daylight ambient fill';
  scene.add(bounce);

  let currentHour = new Date().getHours() + new Date().getMinutes() / 60;
  let clockMode = true;
  let disposed = false;
  let timezone = (typeof Intl !== 'undefined' && Intl.DateTimeFormat().resolvedOptions().timeZone) || 'local';

  function renderAt(decimalHour) {
    const state = samplePalette(decimalHour);
    drawSky(sky.canvas, state, state.sunHeight);
    if (sky.texture) sky.texture.needsUpdate = true;
    sun.color.set(state.sun);
    sun.intensity = state.sunIntensity;
    ambient.color.set(state.ambient);
    ambient.groundColor.set(state.ground);
    ambient.intensity = state.ambientIntensity;
    bounce.color.set(state.horizon);
    bounce.intensity = state.bounce;
    const sunAngle = (decimalHour / 24) * Math.PI * 2 - Math.PI * .5;
    sun.position.set(Math.cos(sunAngle) * 8, 5.8 + state.sunHeight * 4.4, -18);
    sunDisc.position.set(Math.cos(sunAngle) * 7.5, 5.8 + state.sunHeight * 4.2, -18);
    moonDisc.position.set(-Math.cos(sunAngle) * 6.5, 7.0 - state.sunHeight * 1.6, -18);
    sunDisc.material.color.set(state.sun);
    sunDisc.material.opacity = state.period === 'night' ? .08 : .95;
    moonDisc.material.opacity = state.period === 'night' ? .88 : .02;
    stars.material.opacity = state.period === 'night' ? .68 : 0;
    cityGlows.forEach((windowMaterial) => { windowMaterial.emissiveIntensity = state.glow; });
    return state;
  }

  function setPeriod(period) {
    if (!PERIODS.includes(period)) return { period: samplePalette(currentHour).period, timezone };
    clockMode = false;
    currentHour = REPRESENTATIVE[period];
    const state = renderAt(currentHour);
    return { period, timezone, label: `${PERIOD_NAMES[period]} · ${currentHour.toFixed(1)}`, warmLightIntensity: state.warm, state };
  }

  function setTime(date = new Date()) {
    timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'local';
    clockMode = true;
    const localDate = date instanceof Date ? date : new Date(date);
    currentHour = localDate.getHours() + localDate.getMinutes() / 60 + localDate.getSeconds() / 3600;
    const state = renderAt(currentHour);
    const time = localDate.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    return { period: state.period, timezone, label: `${PERIOD_NAMES[state.period]} · ${time}`, warmLightIntensity: state.warm, state };
  }

  function update(seconds = 0) {
    if (disposed) return;
    if (clockMode) currentHour = (currentHour + seconds / 3600) % 24;
    clouds.forEach((cloud) => {
      cloud.position.x += cloud.userData.speed * seconds;
      if (cloud.position.x > 17) cloud.position.x = -17;
    });
    const state = renderAt(currentHour);
    if (state.period === 'night') stars.material.opacity = .62 + Math.sin(currentHour * Math.PI * 1.7) * .08;
    return { period: state.period, timezone, warmLightIntensity: state.warm, state };
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    scene.remove(world, sun, ambient, bounce, target);
    if (scene.background === sky.texture) scene.background = previousBackground;
    world.traverse((node) => {
      if (node.geometry) node.geometry.dispose();
      if (node.material) {
        const materials = Array.isArray(node.material) ? node.material : [node.material];
        materials.forEach((m) => m.dispose());
      }
    });
    if (sky.texture) sky.texture.dispose();
  }

  renderAt(currentHour);
  return { setPeriod, setTime, update, dispose, sun, ambient, bounce, world, timezone };
}

export default createDaylight;
