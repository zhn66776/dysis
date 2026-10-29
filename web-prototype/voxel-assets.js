import * as THREE from './vendor/three.module.js';

// Local, deliberately authored voxel assets.  The room uses metres throughout;
// each object is made from chunky boxes so its silhouette survives an overhead
// camera instead of turning into a collection of smooth toy primitives.

const materialCache = new Map();
const geometryCache = new Map();

function toHex(value, fallback = 0xc8bdab) {
  try {
    return new THREE.Color(value).getHex();
  } catch (_) {
    return fallback;
  }
}

function mat(value, options = {}) {
  const color = toHex(value);
  const key = `${color}:${options.name || ''}:${options.roughness ?? 0.84}:${options.metalness ?? 0}:${options.emissive || 0}`;
  if (materialCache.has(key)) return materialCache.get(key);
  const material = new THREE.MeshStandardMaterial({
    color,
    roughness: options.roughness ?? 0.84,
    metalness: options.metalness ?? 0,
    flatShading: true,
    emissive: options.emissive || 0,
    emissiveIntensity: options.emissiveIntensity ?? 0,
  });
  materialCache.set(key, material);
  return material;
}

function cube(width, height, depth, material, bevel = 0) {
  const key = `${width}:${height}:${depth}:${bevel}`;
  let geometry = geometryCache.get(key);
  if (!geometry) {
    geometry = bevel
      ? new THREE.BoxGeometry(width, height, depth, 1, 1, 1)
      : new THREE.BoxGeometry(width, height, depth);
    geometry.computeVertexNormals();
    geometryCache.set(key, geometry);
  }
  const mesh = new THREE.Mesh(geometry, material);
  if (bevel) mesh.userData.voxelBevel = bevel;
  return mesh;
}

function shadowed(root) {
  root.traverse((node) => {
    if (node.isMesh) {
      node.castShadow = true;
      node.receiveShadow = true;
    }
  });
  return root;
}

const SKIN = [0xf1c29a, 0xd99b72, 0xc98261, 0x8c533e, 0x6f402f];
const HAIR = [0x2e2929, 0x4a3028, 0x6c442d, 0x9b6940, 0x3c4650];
const DARK = 0x202a2b;
const SAGE = 0x789782;
const OAK = 0xb88a5b;
const OAK_LIGHT = 0xd0ac7b;
const TERRACOTTA = 0xb46d52;
const CREAM = 0xc8bdab;

function addPixelFace(head, skinTone, hairTone, variant) {
  const face = new THREE.Group();
  const eye = mat(0x1c2527, { roughness: 0.52 });
  const eyeGlint = mat(0xf3f1e7, { roughness: 0.32 });
  const skinShadow = mat(new THREE.Color(skinTone).multiplyScalar(0.82), { roughness: 0.88 });
  const hair = mat(hairTone, { roughness: 0.89 });
  const top = cube(0.34, 0.075, 0.34, hair);
  top.position.set(0, 0.19, 0);
  face.add(top);
  const fringe = cube(0.29, 0.10, 0.075, hair);
  fringe.position.set(variant % 2 ? 0.05 : -0.04, 0.11, 0.145);
  face.add(fringe);
  const sideL = cube(0.065, 0.18, 0.28, hair);
  sideL.position.set(-0.145, 0.08, 0);
  face.add(sideL);
  const sideR = sideL.clone();
  sideR.position.x = 0.145;
  face.add(sideR);
  // Eyes sit a few millimetres proud of the +z face and remain readable at
  // small render sizes.  A one-pixel glint gives the dolls a little life.
  [-1, 1].forEach((side) => {
    const eyeBlock = cube(0.045, 0.045, 0.025, eye);
    eyeBlock.position.set(side * 0.065, 0.025, 0.163);
    face.add(eyeBlock);
    if ((variant + side) % 2 === 0) {
      const glint = cube(0.012, 0.012, 0.008, eyeGlint);
      glint.position.set(side * 0.056, 0.036, 0.179);
      face.add(glint);
    }
  });
  const mouth = cube(0.07, 0.018, 0.018, eye);
  mouth.position.set(0, -0.065, 0.164);
  face.add(mouth);
  if (Math.abs(variant) % 5 === 2) {
    // Grok's charcoal avatar gets a very small square frame, which remains
    // legible from the room camera without turning the doll into a realistic
    // face.
    const glasses = mat(0x252c2e, { roughness: 0.42, metalness: 0.12 });
    [-1, 1].forEach((side) => {
      const frame = cube(0.094, 0.065, 0.012, glasses, 0.004);
      frame.position.set(side * 0.065, 0.025, 0.18);
      face.add(frame);
    });
    const bridge = cube(0.05, 0.012, 0.012, glasses, 0.003);
    bridge.position.set(0, 0.03, 0.18);
    face.add(bridge);
  }
  [-1, 1].forEach((side) => {
    const cheek = cube(0.042, 0.035, 0.018, skinShadow);
    cheek.position.set(side * 0.105, -0.035, 0.165);
    face.add(cheek);
  });
  return face;
}

export function createVoxelPerson({ id = 'agent', name = 'Agent', color = '#789782', variant = 0, isOwner = false } = {}) {
  const root = new THREE.Group();
  root.name = `voxel-person-${id}`;
  const style = [
    { shirt: 0xd48670, hair: 0x28282b }, // Claude: warm coral sweater
    { shirt: 0x789782, hair: 0x3f332c }, // Codex: sage hoodie
    { shirt: 0x3f4649, hair: 0x252a2d }, // Grok: charcoal jacket + glasses
    { shirt: 0x738fd1, hair: 0x9aa9e4 }, // Gemini: blue clothing + periwinkle hair
    { shirt: 0xe8dfcc, hair: 0x25272a }, // owner: light cream + dark hair
  ][Math.abs(variant) % 5];
  const skinTone = SKIN[Math.abs(variant) % SKIN.length];
  const hairTone = isOwner ? 0x25272a : style.hair;
  const shirtColor = color === '#789782' ? (isOwner ? 0xe8dfcc : style.shirt) : color;
  const skin = mat(skinTone, { roughness: 0.88 });
  const shirt = mat(shirtColor, { roughness: 0.86 });
  const shirtLight = mat(new THREE.Color(shirtColor).lerp(new THREE.Color(0xffffff), 0.18), { roughness: 0.88 });
  const trousers = mat(variant % 3 === 1 ? 0x405354 : 0x344249, { roughness: 0.90 });
  const sole = mat(0x252d2f, { roughness: 0.88 });
  const badge = mat(isOwner ? 0xd3aa62 : 0xa8c7a7, { roughness: 0.78 });

  const body = new THREE.Group();
  const pelvis = cube(0.28, 0.18, 0.23, trousers, 0.015);
  pelvis.position.y = 0.61;
  body.add(pelvis);
  const torso = cube(0.36, 0.39, 0.25, shirt, 0.018);
  torso.position.y = 0.88;
  body.add(torso);
  const collar = cube(0.16, 0.045, 0.26, shirtLight, 0.01);
  collar.position.set(0, 1.09, 0);
  body.add(collar);
  const chestPatch = cube(0.075, 0.075, 0.014, badge, 0.004);
  chestPatch.position.set(0.105, 0.91, 0.133);
  body.add(chestPatch);
  root.add(body);

  const head = new THREE.Group();
  const headBlock = cube(0.32, 0.32, 0.30, skin, 0.012);
  headBlock.position.y = 1.29;
  head.add(headBlock);
  const face = addPixelFace(head, skinTone, hairTone, variant);
  face.position.set(0, 1.29, 0);
  head.add(face);
  const ears = [];
  [-1, 1].forEach((side) => {
    const ear = cube(0.04, 0.10, 0.08, skin, 0.008);
    ear.position.set(side * 0.17, 1.29, 0);
    head.add(ear);
    ears.push(ear);
  });
  root.add(head);

  const legs = [-1, 1].map((side) => {
    const leg = new THREE.Group();
    const thigh = cube(0.12, 0.24, 0.13, trousers, 0.012);
    const shin = cube(0.105, 0.30, 0.12, trousers, 0.012);
    const foot = cube(0.13, 0.08, 0.22, sole, 0.012);
    leg.add(thigh, shin, foot);
    root.add(leg);
    return { leg, thigh, shin, foot, side };
  });
  const arms = [-1, 1].map((side) => {
    const arm = new THREE.Group();
    const upper = cube(0.105, 0.23, 0.12, shirt, 0.012);
    const lower = cube(0.10, 0.20, 0.11, shirtLight, 0.012);
    const hand = cube(0.09, 0.09, 0.10, skin, 0.012);
    arm.add(upper, lower, hand);
    root.add(arm);
    return { arm, upper, lower, hand, side };
  });

  let currentPose = 'standing';
  let currentPhase = 0;
  const setPose = (pose = 'standing', phase = 0) => {
    currentPose = pose;
    currentPhase = phase;
    const seated = pose === 'seated' || pose === 'working';
    pelvis.position.set(0, seated ? 0.55 : 0.61, seated ? 0.10 : 0);
    torso.position.set(0, seated ? 0.82 : 0.88, seated ? 0.09 : 0);
    collar.position.set(0, seated ? 1.03 : 1.09, seated ? 0.09 : 0);
    chestPatch.position.set(0.105, seated ? 0.85 : 0.91, seated ? 0.22 : 0.133);
    headBlock.position.set(0, seated ? 1.18 : 1.29, seated ? 0.09 : 0);
    face.position.set(0, seated ? 1.18 : 1.29, seated ? 0.09 : 0);
    ears.forEach((ear, index) => { ear.position.y = seated ? 1.18 : 1.29; ear.position.z = seated ? 0.09 : 0; ear.position.x = index ? 0.17 : -0.17; });
    head.position.y = 0;
    [-1, 1].forEach((side, index) => {
      const part = legs[index];
      part.leg.position.set(side * 0.095, seated ? 0.55 : 0.61, seated ? 0.10 : 0);
      part.thigh.rotation.set(0, 0, 0);
      part.shin.rotation.set(0, 0, 0);
      part.foot.rotation.set(0, 0, 0);
      if (seated) {
        part.thigh.position.set(0, 0.01, 0.13);
        part.thigh.rotation.x = -Math.PI / 2;
        part.shin.position.set(0, -0.16, 0.27);
        part.foot.position.set(0, -0.30, 0.34);
      } else {
        part.thigh.position.set(0, -0.10, 0);
        // Hip 0.61 - 0.37 places the extended calf from the thigh joint down
        // to the ankle; foot centre 0.61 - 0.57 = 0.04 keeps the boot sole on
        // the floor instead of leaving the whole doll hovering.
        part.shin.position.set(0, -0.37, 0.02);
        part.foot.position.set(0, -0.57, 0.075);
        if (pose === 'walking') {
          const swing = Math.sin(phase * Math.PI * 2 + index * Math.PI) * 0.22;
          // Keep the gait connected by translating the knee, ankle and toe as
          // one chain.  A small root bob sells a step without lifting both
          // soles at once.
          part.thigh.position.z = swing * 0.045;
          part.shin.position.z = 0.02 + swing * 0.13;
          part.foot.position.z = 0.075 + swing * 0.20;
          part.thigh.rotation.x = swing;
          part.shin.rotation.x = -swing * 0.45;
          part.foot.rotation.x = swing * 0.12;
        }
      }
    });
    [-1, 1].forEach((side, index) => {
      const part = arms[index];
      part.arm.position.set(side * 0.22, seated ? 0.98 : 1.05, seated ? 0.09 : 0);
      part.upper.rotation.set(0, 0, 0);
      part.lower.rotation.set(0, 0, 0);
      if (pose === 'walking') {
        const swing = Math.sin(phase * Math.PI * 2 + index * Math.PI) * 0.22;
        part.upper.position.set(0, -0.10, 0.02);
        part.lower.position.set(0, -0.31, 0.035);
        part.hand.position.set(0, -0.47, 0.05);
        part.upper.rotation.x = -swing;
        part.lower.rotation.x = swing * 0.38;
      } else if (pose === 'working') {
        part.upper.position.set(0, -0.10, 0.07);
        part.lower.position.set(0, -0.28, 0.19);
        part.hand.position.set(0, -0.27 + Math.sin(phase * Math.PI * 2 + index * Math.PI) * .025, 0.30);
        part.upper.rotation.x = -0.25;
        part.lower.rotation.x = -0.55;
      } else if (seated) {
        part.upper.position.set(0, -0.10, 0.04);
        part.lower.position.set(0, -0.30, 0.11);
        part.hand.position.set(0, -0.46, 0.15);
        part.upper.rotation.x = -0.10;
        part.lower.rotation.x = -0.18;
      } else {
        part.upper.position.set(0, -0.10, 0);
        part.lower.position.set(0, -0.31, 0.02);
        part.hand.position.set(0, -0.47, 0.05);
      }
    });
    const walkBob = pose === 'walking' ? (0.006 + Math.max(0, Math.sin(phase * Math.PI * 2)) * 0.012) : 0;
    body.position.y = walkBob;
    head.position.y = walkBob;
    legs.forEach((part) => { part.leg.position.y += walkBob; });
    arms.forEach((part) => { part.arm.position.y += walkBob; });
    root.userData.pose = pose;
    root.userData.phase = phase;
    return root;
  };

  root.userData = {
    id,
    name,
    variant,
    isOwner,
    headAnchor: head,
    setPose,
    animate: (phase = currentPhase + 0.018) => setPose(currentPose, phase),
  };
  root.animate = root.userData.animate;
  root.userData.setPose('standing', 0);
  root.traverse((node) => {
    if (node.isMesh) {
      node.userData.agentRoot = root;
      node.userData.agentId = id;
      node.userData.pickRoot = root;
    }
  });
  shadowed(root);
  return root;
}

export function createDesk({ executive = false } = {}) {
  const desk = new THREE.Group();
  desk.name = executive ? 'voxel-executive-desk' : 'voxel-desk';
  const width = executive ? 2.25 : 1.80;
  const depth = executive ? 1.03 : 0.85;
  const top = cube(width, 0.08, depth, mat(OAK, { name: 'pale-oak', roughness: 0.70 }), 0.02);
  top.position.y = 0.76;
  desk.add(top);
  const legMat = mat(0x687a6f, { name: 'sage-steel', roughness: 0.72, metalness: 0.25 });
  [-1, 1].forEach((x) => [-1, 1].forEach((z) => {
    const leg = cube(0.075, 0.72, 0.075, legMat, 0.012);
    leg.position.set(x * (width / 2 - 0.12), 0.36, z * (depth / 2 - 0.12));
    desk.add(leg);
  }));
  const screenBody = cube(0.64, 0.37, 0.055, mat(0x2f3b3d, { name: 'monitor-shell', roughness: 0.62 }), 0.02);
  screenBody.position.set(0, 1.00, -0.17);
  desk.add(screenBody);
  const screenMaterial = mat(0x15272a, { name: 'voxel-screen', roughness: 0.32, emissive: 0x122d2f, emissiveIntensity: 0.28 }).clone();
  screenMaterial.name = `voxel-screen-${desk.uuid}`;
  const front = cube(0.56, 0.29, 0.016, screenMaterial, 0.008);
  front.position.set(0, 1.00, -0.135);
  desk.add(front);
  const stand = cube(0.055, 0.18, 0.055, legMat, 0.008);
  stand.position.set(0, 0.79, -0.17);
  desk.add(stand);
  const standFoot = cube(0.24, 0.025, 0.13, legMat, 0.008);
  standFoot.position.set(0, 0.695, -0.17);
  desk.add(standFoot);
  const laptopBase = cube(0.44, 0.035, 0.27, mat(0x899a94, { name: 'laptop', roughness: 0.62 }), 0.012);
  laptopBase.position.set(0.42, 0.825, 0.16);
  desk.add(laptopBase);
  const keyboard = cube(0.48, 0.025, 0.17, mat(0x536460, { name: 'keyboard', roughness: 0.78 }), 0.012);
  keyboard.position.set(-0.20, 0.82, 0.18);
  desk.add(keyboard);
  const mug = cube(0.09, 0.10, 0.09, mat(CREAM, { name: 'mug', roughness: 0.72 }), 0.02);
  mug.position.set(-0.61, 0.85, 0.16);
  desk.add(mug);
  const coffee = cube(0.065, 0.008, 0.065, mat(0x442b20, { name: 'coffee', roughness: 0.35 }), 0.012);
  coffee.position.set(-0.61, 0.904, 0.16);
  desk.add(coffee);
  const book = cube(0.28, 0.025, 0.20, mat(0xd0c7a9, { name: 'book', roughness: 0.82 }), 0.008);
  book.position.set(-0.47, 0.82, -0.12);
  desk.add(book);
  desk.userData.screen = screenMaterial;
  desk.userData.pickMeshes = [front, top];
  shadowed(desk);
  return desk;
}

export function createChair() {
  const chair = new THREE.Group();
  chair.name = 'voxel-chair';
  const fabric = mat(0x61786e, { name: 'chair-fabric', roughness: 0.89 });
  const oak = mat(OAK_LIGHT, { name: 'chair-oak', roughness: 0.76 });
  const seat = cube(0.58, 0.12, 0.52, fabric, 0.025);
  seat.position.y = 0.43;
  chair.add(seat);
  const back = cube(0.58, 0.58, 0.11, fabric, 0.025);
  back.position.set(0, 0.72, 0.22);
  chair.add(back);
  [-1, 1].forEach((side) => {
    const frontLeg = cube(0.055, 0.42, 0.055, oak, 0.01);
    frontLeg.position.set(side * 0.22, 0.20, -0.17);
    chair.add(frontLeg);
    const rearLeg = cube(0.055, 0.42, 0.055, oak, 0.01);
    rearLeg.position.set(side * 0.22, 0.20, 0.17);
    chair.add(rearLeg);
  });
  shadowed(chair);
  return chair;
}

export function createPlant(height = 1.4) {
  const plant = new THREE.Group();
  plant.name = 'voxel-plant';
  const potHeight = Math.max(0.22, height * 0.18);
  const pot = cube(height * 0.30, potHeight, height * 0.30, mat(TERRACOTTA, { name: 'terracotta', roughness: 0.86 }), 0.025);
  pot.position.y = potHeight / 2;
  plant.add(pot);
  const earth = cube(height * 0.22, 0.025, height * 0.22, mat(0x352a23, { name: 'plant-soil', roughness: 1 }), 0.008);
  earth.position.y = potHeight + 0.012;
  plant.add(earth);
  const leaf = mat(0x668a6b, { name: 'pixel-leaf', roughness: 0.88 });
  const leafDark = mat(0x3e624c, { name: 'pixel-leaf-dark', roughness: 0.92 });
  const count = 8;
  for (let i = 0; i < count; i += 1) {
    const angle = (Math.PI * 2 * i) / count;
    const level = 0.35 + (i % 4) * 0.14;
    const stem = cube(0.035, height * (0.46 + (i % 3) * 0.08), 0.035, leafDark, 0.008);
    stem.position.set(Math.cos(angle) * height * 0.07, potHeight + height * level * 0.4, Math.sin(angle) * height * 0.07);
    stem.rotation.z = Math.sin(angle) * 0.22;
    stem.rotation.x = Math.cos(angle) * 0.22;
    plant.add(stem);
    const blade = cube(height * (0.26 + (i % 3) * 0.025), height * 0.08, height * 0.045, i % 2 ? leaf : leafDark, 0.012);
    blade.position.set(Math.cos(angle) * height * (0.16 + (i % 3) * 0.02), potHeight + height * level, Math.sin(angle) * height * (0.16 + (i % 3) * 0.02));
    blade.rotation.y = -angle;
    blade.rotation.z = -0.10 + (i % 2) * 0.18;
    plant.add(blade);
  }
  shadowed(plant);
  return plant;
}

export function createSofa({ width = 2.7, color = '#c8bdab' } = {}) {
  const sofa = new THREE.Group();
  sofa.name = 'voxel-sofa';
  const upholstery = mat(color, { name: `sofa-${toHex(color)}`, roughness: 0.92 });
  const highlight = mat(new THREE.Color(color).lerp(new THREE.Color(0xffffff), 0.12), { name: `sofa-highlight-${toHex(color)}`, roughness: 0.94 });
  const frame = cube(width, 0.32, 0.78, upholstery, 0.035);
  frame.position.y = 0.22;
  sofa.add(frame);
  const seatWidth = Math.max(0.42, (width - 0.32) / 3);
  for (let i = 0; i < 3; i += 1) {
    const cushion = cube(seatWidth - 0.035, 0.16, 0.57, highlight, 0.028);
    cushion.position.set((i - 1) * seatWidth, 0.42, 0.04);
    sofa.add(cushion);
    const back = cube(seatWidth - 0.035, 0.38, 0.16, upholstery, 0.028);
    back.position.set((i - 1) * seatWidth, 0.67, -0.27);
    sofa.add(back);
  }
  [-1, 1].forEach((side) => {
    const arm = cube(0.20, 0.48, 0.74, upholstery, 0.035);
    arm.position.set(side * (width / 2 - 0.10), 0.50, 0);
    sofa.add(arm);
    const foot = cube(0.09, 0.14, 0.09, mat(OAK, { name: 'sofa-foot', roughness: 0.78 }), 0.012);
    foot.position.set(side * (width / 2 - 0.17), 0.07, 0.25);
    sofa.add(foot);
  });
  shadowed(sofa);
  return sofa;
}

export function createCoffeeTable() {
  const table = new THREE.Group();
  table.name = 'voxel-coffee-table';
  const oak = mat(OAK_LIGHT, { name: 'coffee-oak', roughness: 0.75 });
  const top = cube(1.20, 0.08, 0.80, oak, 0.025);
  top.position.y = 0.40;
  table.add(top);
  [-1, 1].forEach((x) => [-1, 1].forEach((z) => {
    const leg = cube(0.07, 0.36, 0.07, mat(0x687b6d, { name: 'coffee-leg', roughness: 0.78 }), 0.012);
    leg.position.set(x * 0.46, 0.19, z * 0.28);
    table.add(leg);
  }));
  const lower = cube(0.78, 0.035, 0.38, mat(OAK, { name: 'coffee-shelf', roughness: 0.78 }), 0.012);
  lower.position.y = 0.16;
  table.add(lower);
  shadowed(table);
  return table;
}

