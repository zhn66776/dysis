import * as THREE from './vendor/three.module.js';
import { RoomEnvironment } from './vendor/RoomEnvironment.js';
import { EffectComposer } from './vendor/postprocessing/EffectComposer.js';
import { RenderPass } from './vendor/postprocessing/RenderPass.js';
import { SSAOPass } from './vendor/postprocessing/SSAOPass.js';
import { OutputPass } from './vendor/postprocessing/OutputPass.js';
import { createNordicRoom } from './nordic-room.js';
import { createVoxelPerson } from './voxel-assets.js';
import { createDaylight } from './daylight.js';
import { findPath } from './navigation.js';

const FIXED_VIEW = { position: [8.021618, 17.844741, 16.343807], target: [0, .1, 0], fov: 38 };
const STATUS = { arriving: '走过来', desk: '在工位', failed: '需留意', idle: '在工位', atDesk: '在工位', walking: '走过来', returning: '回工位', listening: '等你开口', working: '工作中', thinking: '思考中', answering: '回复中', ready: '已就座', error: '需留意' };
const vector = p => new THREE.Vector3(...p);
const distance = (a, b) => Math.hypot(a[0] - b[0], a[2] - b[2]);

export function createOfficeScene(container, options = {}) {
  const { agents = [], onAgentSelect, onLoungeSelect, onOwnerSelect, onPortfolioSelect } = options;
  const root = document.createElement('div'); root.className = 'office-scene';
  const canvas = document.createElement('canvas'); canvas.className = 'office-canvas'; canvas.tabIndex = 0;
  canvas.setAttribute('aria-label', '固定俯视的北欧像素办公室，点击人偶邀请到办公室，点击沙发集合');
  const labels = document.createElement('div'); labels.className = 'world-labels'; root.append(canvas, labels); container.replaceChildren(root);
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.6)); renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true; renderer.shadowMap.type = THREE.PCFSoftShadowMap; renderer.shadowMap.autoUpdate = false; renderer.shadowMap.needsUpdate = true;
  const scene = new THREE.Scene(); const camera = new THREE.PerspectiveCamera(FIXED_VIEW.fov, 1, .1, 110);
  camera.position.fromArray(FIXED_VIEW.position); camera.lookAt(vector(FIXED_VIEW.target));
  const pmrem = new THREE.PMREMGenerator(renderer), studio = new RoomEnvironment();
  const environment = pmrem.fromScene(studio, .06); scene.environment = environment.texture; scene.environmentIntensity = .3;
  studio.dispose(); pmrem.dispose();
  const room = createNordicRoom(agents); scene.add(room.group);
  const daylight = createDaylight(scene);
  room.practicals.forEach(light => scene.add(light));
  const renderTarget = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: 4 });
  const composer = new EffectComposer(renderer, renderTarget); composer.setPixelRatio(Math.min(devicePixelRatio, 1.4)); composer.addPass(new RenderPass(scene, camera));
  const ao = new SSAOPass(scene, camera, 1, 1, 16); ao.kernelRadius = .32; ao.minDistance = .0002; ao.maxDistance = .018;
  composer.addPass(ao); composer.addPass(new OutputPass());
  const picks = [], actors = new Map(), zones = [];
  let selected = null, destroyed = false, frame = 0, lastFrame = 0, width = 1, height = 1;
  function emit(name, detail) { root.dispatchEvent(new CustomEvent(name, { bubbles: true, detail })); }
  function pick(object, action) { object.traverse(node => { if (node.isMesh) { node.userData.action = action; picks.push(node); } }); }
  function seatFor(id, destination) {
    const actor = actors.get(id);
    if (destination === 'lounge') {
      const seat = room.loungeSeats[id === 'owner' ? 0 : actor.index + 1];
      return { position: [...seat.position], rotation: seat.rotation, lounge: true };
    }
    if (id === 'owner') return { position: [...room.ownerSeat], rotation: room.ownerSeatRotation ?? 0 };
    if (destination === 'office') return { position: [...room.officeSeat], rotation: room.officeSeatRotation ?? Math.PI };
    const station = room.stations.find(item => item.id === id);
    return { position: [...station.seat], rotation: station.facing ?? station.rotation + Math.PI };
  }
  function approach(spec) {
    const r = spec.rotation;
    return spec.lounge
      ? [spec.position[0] + Math.sin(r) * .72, 0, spec.position[2] + Math.cos(r) * .72]
      : [spec.position[0] + Math.cos(r) * .62, 0, spec.position[2] - Math.sin(r) * .62];
  }
  function updateActorLabel(actor) {
    actor.button.dataset.location = actor.location; actor.button.dataset.state = actor.motion ? 'walking' : actor.status;
    actor.button.querySelector('small').textContent = actor.motion ? (actor.destination === 'desk' ? '回工位' : '走过来') : (STATUS[actor.status] || '已就座');
    actor.button.setAttribute('aria-label', `${actor.id === 'owner' ? '你的办公室' : `邀请 ${actor.name}`} · ${actor.location === 'desk' ? '工位' : actor.location === 'office' ? '办公室' : '讨论区'}`);
  }
  for (const [index, agent] of [...agents, { id: 'owner', name: '你', color: '#e3c585', isOwner: true }].entries()) {
    const person = createVoxelPerson({ ...agent, variant: index, isOwner: agent.id === 'owner' }); scene.add(person);
    const button = document.createElement('button'); button.type = 'button'; button.className = 'world-label actor-label'; button.dataset.agentId = agent.id;
    button.style.setProperty('--agent-color', agent.color || '#7d9d87');
    const dot = document.createElement('i'), name = document.createElement('span'), status = document.createElement('small'); name.textContent = agent.name; button.append(dot, name, status); labels.append(button);
    const callback = () => agent.id === 'owner' ? onOwnerSelect?.() : onAgentSelect?.(agent.id);
    button.addEventListener('click', callback); pick(person, callback);
    const actor = { id: agent.id, name: agent.name, index, person, button, location: 'desk', destination: 'desk', status: 'idle', motion: null, pose: 'seated' };
    actors.set(agent.id, actor); const seat = seatFor(agent.id, 'desk'); person.position.fromArray(seat.position); person.rotation.y = seat.rotation; person.userData.setPose('seated'); updateActorLabel(actor);
  }
  room.stations.forEach(station => { pick(station.desk, () => onAgentSelect?.(station.id)); pick(station.chair, () => onAgentSelect?.(station.id)); });
  room.hitTargets.lounge.forEach(object => pick(object, () => onLoungeSelect?.()));
  room.hitTargets.owner.forEach(object => pick(object, () => onOwnerSelect?.()));
  room.hitTargets.portfolio.forEach(object => pick(object, () => onPortfolioSelect?.()));
  function zone(name, subtitle, position, callback, className) {
    const button = document.createElement('button'); button.type = 'button'; button.className = `zone-label ${className || ''}`;
    const main = document.createElement('strong'), detail = document.createElement('small'); main.textContent = name; detail.textContent = subtitle; button.append(main, detail);
    button.addEventListener('click', callback); labels.append(button); zones.push({ button, anchor: vector(position) });
  }
  zone('一起聊聊', 'THE COMMON ROOM', [3.7, .1, 4.6], () => onLoungeSelect?.(), 'lounge-zone');
  const projection = new THREE.Vector3();
  function projectedLabel(button, point, yOffset = 0) {
    projection.copy(point).project(camera); const visible = projection.z > -1 && projection.z < 1 && Math.abs(projection.x) < .96 && Math.abs(projection.y) < .94;
    button.hidden = !visible;
    if (visible) button.style.transform = `translate(-50%, -50%) translate(${(projection.x + 1) * width / 2}px, ${(-projection.y + 1) * height / 2 + yOffset}px)`;
  }
  function fitPosition() {
    const pos = vector(FIXED_VIEW.position), target = vector(FIXED_VIEW.target);
    return pos.sub(target).multiplyScalar(Math.max(1, 1.15 / camera.aspect)).add(target);
  }
  function syncProjection() { camera.updateProjectionMatrix(); ao.ssaoMaterial.uniforms.cameraProjectionMatrix.value.copy(camera.projectionMatrix); ao.ssaoMaterial.uniforms.cameraInverseProjectionMatrix.value.copy(camera.projectionMatrixInverse); }
  function resize() {
    const rect = container.getBoundingClientRect(); width = Math.max(1, rect.width); height = Math.max(1, rect.height); camera.aspect = width / height;
    camera.position.copy(fitPosition()); camera.lookAt(vector(FIXED_VIEW.target));
    renderer.setSize(width, height, false); composer.setSize(width, height); syncProjection();
  }
  const observer = new ResizeObserver(resize); observer.observe(container); resize();
  function finishMotion(actor) {
    const motion = actor.motion; actor.person.position.copy(motion.end); actor.person.rotation.y = motion.rotation;
    actor.location = actor.destination; if (!['working', 'thinking', 'answering'].includes(actor.status)) actor.status = actor.location === 'desk' ? 'idle' : 'ready'; actor.pose = ['working','thinking','answering'].includes(actor.status) ? 'working' : 'seated'; actor.person.userData.setPose(actor.pose);
    actor.motion = null; updateActorLabel(actor); emit('scene:actor', { id: actor.id, location: actor.location, state: actor.status }); motion.resolve(true);
  }
  function render(now) {
    if (destroyed) return; frame = requestAnimationFrame(render);
    if (document.hidden || now - lastFrame < 30) return; const delta = Math.min((now - lastFrame) / 1000, .1); lastFrame = now;
    daylight.update(delta);
    let moving = false;
    for (const actor of actors.values()) {
      if (actor.motion) {
        moving = true; const motion = actor.motion, elapsed = Math.max(0, now - motion.start), progress = Math.min(1, elapsed / motion.duration);
        const travel = progress * motion.total; let segment = 0;
        while (segment < motion.lengths.length - 1 && travel > motion.cumulative[segment + 1]) segment++;
        const local = motion.lengths[segment] > 0 ? THREE.MathUtils.clamp((travel - motion.cumulative[segment]) / motion.lengths[segment], 0, 1) : 1;
        actor.person.position.lerpVectors(motion.points[segment], motion.points[segment + 1], local);
        const direction = motion.points[segment + 1].clone().sub(motion.points[segment]);
        if (direction.lengthSq() > .001) actor.person.rotation.y = Math.atan2(direction.x, direction.z);
        actor.person.userData.setPose('walking', elapsed / 430);
        if (progress >= 1) finishMotion(actor);
      } else if (['thinking', 'working', 'answering'].includes(actor.status)) {
        actor.person.userData.setPose('working', now / 600); moving = true;
      }
      projectedLabel(actor.button, actor.person.position.clone().add(new THREE.Vector3(0, 1.96, 0)), -5);
    }
    zones.forEach(label => projectedLabel(label.button, label.anchor));
    if (moving) renderer.shadowMap.needsUpdate = true;
    composer.render();
  }
  function moveActor(id, destination) {
    const actor = actors.get(id); if (!actor || !['desk', 'office', 'lounge'].includes(destination)) return Promise.resolve(false);
    const previousMotion = actor.motion;
    if (previousMotion) { previousMotion.resolve(false); actor.motion = null; }
    const spec = seatFor(id, destination), end = vector(spec.position);
    if (actor.person.position.distanceTo(end) < .03) { actor.location = destination; actor.destination = destination; actor.person.rotation.y = spec.rotation; updateActorLabel(actor); return Promise.resolve(true); }
    const start = actor.person.position.toArray();
    const sourceApproach = previousMotion ? start : approach(seatFor(id, actor.location));
    const destinationApproach = approach(spec);
    const path = findPath(sourceApproach, destinationApproach, room.obstacles);
    if (!path) { actor.status = 'error'; actor.person.userData.setPose('standing'); updateActorLabel(actor); emit('scene:error', { id, message: '这条通道暂时无法通过' }); return Promise.resolve(false); }
    const raw = [start, ...path, spec.position]; const points = raw.filter((p, i) => !i || distance(p, raw[i - 1]) > .015).map(vector);
    const lengths = points.slice(1).map((p, i) => p.distanceTo(points[i])); const cumulative = [0]; lengths.forEach(length => cumulative.push(cumulative.at(-1) + length)); const total = cumulative.at(-1);
    actor.destination = destination; actor.pose = 'walking';
    return new Promise(resolve => {
      actor.motion = { points, lengths, cumulative, total, duration: Math.max(650, total / 2.3 * 1000), start: performance.now(), end, rotation: spec.rotation, resolve };
      updateActorLabel(actor); emit('scene:actor', { id, location: actor.location, destination, state: 'walking' });
    });
  }
  const raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2(); let pointerStart = null;
  canvas.addEventListener('pointerdown', e => { pointerStart = { x: e.clientX, y: e.clientY, time: performance.now() }; });
  canvas.addEventListener('pointerup', e => {
    if (!pointerStart || Math.hypot(e.clientX - pointerStart.x, e.clientY - pointerStart.y) > 5 || performance.now() - pointerStart.time > 550) { pointerStart = null; return; }
    const rect = canvas.getBoundingClientRect(); pointer.set((e.clientX - rect.left) / rect.width * 2 - 1, -(e.clientY - rect.top) / rect.height * 2 + 1); raycaster.setFromCamera(pointer, camera);
    raycaster.intersectObjects(picks, false)[0]?.object.userData.action?.(); pointerStart = null;
  });
  canvas.addEventListener('pointercancel', () => { pointerStart = null; });
  function practicalLight(result) {
    const period = typeof result === 'string' ? result : result?.period; root.dataset.lighting = period || 'afternoon';
    const intensity = period === 'night' ? 18 : period === 'dusk' ? 8 : 1.2;
    room.practicals.forEach(light => { light.intensity = intensity; });
    scene.environmentIntensity = period === 'night' ? .12 : .32; renderer.shadowMap.needsUpdate = true;
    return result;
  }
  const api = {
    root, agents, moveActor,
    moveActors(ids, destination) { return Promise.all(ids.map(id => moveActor(id, destination))); },
    select(id) { selected = id; actors.forEach(actor => { actor.button.classList.toggle('is-selected', actor.id === selected); actor.button.setAttribute('aria-pressed', String(actor.id === selected)); }); },
    setStatus(id, status) { const actor = actors.get(id); if (!actor) return; actor.status = status; if (!actor.motion) { actor.pose = ['thinking','working','answering'].includes(status) ? 'working' : 'seated'; actor.person.userData.setPose(actor.pose); } updateActorLabel(actor); },
    setPeriod(period) { return practicalLight(daylight.setPeriod(period) || period); },
    setTime(date) { return practicalLight(daylight.setTime(date)); },
    setPortfolio(snapshot) {
      const subtitle = labels.querySelector('.portfolio-zone small'); if (subtitle) subtitle.textContent = snapshot?.connected ? '已连接 · 点击查看' : '未连接';
      if (!room.portfolioScreen) return;
      const c = document.createElement('canvas'); c.width = 384; c.height = 192; const ctx = c.getContext('2d'); ctx.fillStyle = '#263c37'; ctx.fillRect(0,0,384,192);
      ctx.fillStyle = '#e8e4ca'; ctx.font = 'bold 24px monospace'; ctx.fillText('MY PORTFOLIO',22,40);
      ctx.fillStyle = '#a9baa4'; ctx.font = '16px monospace'; ctx.fillText(snapshot?.connected ? 'CONNECTED / READ ONLY' : 'AWAITING CONNECTION',22,72);
      ctx.fillStyle = '#ebd89e'; ctx.font = '32px monospace'; const value = snapshot?.totalValue; ctx.fillText(Number.isFinite(value) ? new Intl.NumberFormat(undefined, {style:'currency',currency:snapshot.currency || 'GBP',maximumFractionDigits:0}).format(value) : '—  —  —',22,124);
      ctx.fillStyle = '#77978a'; ctx.font = '13px monospace'; ctx.fillText('YOUR INVESTMENTS, AT A GLANCE',22,164);
      const texture = new THREE.CanvasTexture(c); texture.colorSpace = THREE.SRGBColorSpace; texture.magFilter = THREE.NearestFilter;
      room.portfolioScreen.material.map?.dispose(); room.portfolioScreen.material.map = texture; room.portfolioScreen.material.needsUpdate = true;
    },
    getSnapshot() { return [...actors.values()].map(actor => ({ id: actor.id, location: actor.location, destination: actor.destination, moving: !!actor.motion, status: actor.status, position: actor.person.position.toArray() })); },
    destroy() {
      destroyed = true; cancelAnimationFrame(frame); observer.disconnect(); actors.forEach(actor => actor.motion?.resolve(false)); daylight.dispose?.();
      const geometries = new Set(), materials = new Set(), textures = new Set(); scene.traverse(object => { if (!object.isMesh) return; geometries.add(object.geometry); (Array.isArray(object.material) ? object.material : [object.material]).forEach(material => { materials.add(material); Object.values(material).forEach(value => { if (value?.isTexture) textures.add(value); }); }); });
      geometries.forEach(g => g.dispose()); materials.forEach(m => m.dispose()); textures.forEach(t => t.dispose()); composer.passes.forEach(pass => pass.dispose?.()); composer.dispose(); environment.dispose(); renderer.dispose(); root.remove();
    },
  };
  api.setTime(new Date()); api.setPortfolio(null); frame = requestAnimationFrame(render); return api;
}
