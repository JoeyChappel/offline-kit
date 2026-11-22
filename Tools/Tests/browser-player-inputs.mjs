// Run: node Tools/Tests/browser-player-inputs.mjs
// Exercises the shipped browser player's wire inputs without an emulator, network or save files.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../Sources/Mac/PlayScript.swift', import.meta.url), 'utf8');
let script = source.split('private static let js = #"""')[1]?.split('"""#')[0];
assert.ok(script, 'production player JavaScript exists');
script = script.replace('window.OKPlay = {', 'window.__inputs = {Player, B, retroKey};\nwindow.OKPlay = {');
class Element {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase(); this.children = []; this.style = {}; this.listeners = {};
    this.attributes = {}; this.className = ''; this.textContent = ''; this.value = '';
    const classes = () => new Set(this.className.split(/\s+/).filter(Boolean));
    const toggle = (name, force) => { const set = classes(), on = force ?? !set.has(name); if (on) set.add(name); else set.delete(name); this.className = [...set].join(' '); return on; };
    this.classList = {add: name => toggle(name, true), remove: name => toggle(name, false), toggle,
      contains: name => classes().has(name)};
  }
  appendChild(child) { child.parent = this; this.children.push(child); return child; }
  insertBefore(child, before) { child.parent = this; const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parent = null; }
  remove() { this.parent?.removeChild(this); }
  get firstChild() { return this.children[0]; }
  setAttribute(key, value) { this.attributes[key] = value; }
  getAttribute(key) { return this.attributes[key]; }
  hasAttribute(key) { return key in this.attributes; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener() {}
  querySelectorAll(selector) { return walk(this).filter(e => selector.startsWith('.') && e.className.split(' ').includes(selector.slice(1))); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest() { return null; }
  setPointerCapture() {}
  focus() {}
  get offsetWidth() { return parseFloat(this.style.width) || 256; }
  get offsetHeight() { return parseFloat(this.style.height) || 0; }
  getBoundingClientRect() {
    if (this.rect) return this.rect;
    const left = parseFloat(this.style.left) || 0, top = parseFloat(this.style.top) || 0;
    const width = parseFloat(this.style.width) || 256, height = parseFloat(this.style.height) || 192;
    return {left, top, width, height, right: left + width, bottom: top + height};
  }
}
const walk = root => root.children.flatMap(child => [child, ...walk(child)]);
let time = 100, gamepads = [], timers = [];
const document = new Element(); document.body = new Element(); document.documentElement = new Element();
document.createElement = tag => new Element(tag);
const window = new Element(); window.devicePixelRatio = 1;
const context = vm.createContext({window, document, navigator: {getGamepads: () => gamepads},
  location: {protocol: 'http:', host: 'fixture'}, performance: {now: () => time},
  getComputedStyle: () => ({paddingLeft: '0', paddingRight: '0', paddingTop: '0', paddingBottom: '0'}),
  setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout() {},
  setInterval() {}, clearInterval() {}, requestAnimationFrame() {}, cancelAnimationFrame() {},
  console, ArrayBuffer, DataView, Uint8Array, Int16Array, Float32Array, Set, Map, URL, Blob});
vm.runInContext(script, context);
const {Player, B, retroKey} = window.__inputs;
function player(layout = 'pad') {
  const p = Object.create(Player.prototype), packets = [];
  Object.assign(p, {root: new Element(), pad: new Element(), canvas: new Element('canvas'),
    titleEl: new Element(), mode: 'play', title: 'Fixture', state: 'playing', menuOpen: false,
    fps: 0, rtt: 0, decodeMs: 0,
    sources: {touch: new Set(), key: new Set(), pad: new Set()}, sent: new Set(), pointers: new Map(),
    zones: [], listeners: [], info: {saveStates: true}, pointerMode: 'relative',
    sound: {ms: 0, muted: false, setMuted(value) { this.muted = value; }},
    ws: {readyState: 1, send(data) { packets.push(typeof data === 'string' ? JSON.parse(data) : [...new Uint8Array(data)]); }}});
  // Input tests supply explicit touch geometry; browser visual checks exercise real responsive layout.
  p.layout = () => {};
  p.buildControls(layout);
  return {p, packets};
}
// Responsive console geometry uses the real layout function, independently of the input test's layout stub.
// Short landscape is deliberately included: stacked controls used to fall below the enclosure there.
for (const [width, height] of [[828, 368], [552, 298], [368, 667], [298, 546]]) {
  for (const [system, aspect, layout] of [['nes', 16 / 15, 'pad'], ['gameBoy', 10 / 9, 'pad'],
    ['gameBoyColor', 10 / 9, 'pad'], ['gameBoyAdvance', 1.5, 'pad-shoulders'], ['pcEngine', 6 / 5, 'pad']]) {
    const {p} = player(layout);
    p.root.clientWidth = width; p.root.clientHeight = height;
    p.info = {system, aspect}; p.canvas.width = 256; p.canvas.height = 240;
    p.stage = new Element(); p.bezel = new Element(); p.nameplate = new Element();
    p.compass = new Element(); p.menuButton = new Element(); p.soundButton = new Element();
    Player.prototype.layoutConsole.call(p);
    for (const z of p.zones) {
      const r = z.rect;
      assert.ok(r.left >= 0 && r.top >= 0 && r.right <= width + 1 && r.bottom <= height + 1,
        `${system} control ${z.button ?? 'dpad'} fits ${width}×${height}`);
    }
    const c = p.canvas.getBoundingClientRect();
    assert.ok(Math.abs(c.width / c.height - aspect) < 0.03, `${system} keeps its picture aspect ratio`);
    const d = p.zones[0].rect;
    for (const button of [p.btnSelect, p.btnStart, p.btnL, p.btnR].filter(Boolean)) {
      const r = button.getBoundingClientRect();
      assert.ok(r.right <= d.left || r.left >= d.right || r.bottom <= d.top || r.top >= d.bottom,
        `${system} ${button.textContent} does not overlap dpad at ${width}×${height}`);
    }
  }
}
const event = (type, extra = {}) => ({type, pointerId: 1, clientX: 0, clientY: 0,
  preventDefault() {}, stopPropagation() {}, ...extra});
const fire = (element, type, extra) => { for (const fn of element.listeners[type] || []) fn(event(type, extra)); };
const flush = () => { const pending = timers; timers = []; pending.forEach(fn => fn()); };
const buttonPackets = packets => packets.filter(p => Array.isArray(p) && p[0] === 1);

// Nintendo/libretro mappings, including GBA shoulders; overlapping input sources must not release each other.
{
  const {p, packets} = player('pad-shoulders');
  p.key(event('keydown', {code: 'KeyX', key: 'x'}), true);
  p.sources.touch.add(B.A); p.sync();
  p.key(event('keyup', {code: 'KeyX', key: 'x'}), false);
  assert.deepEqual(buttonPackets(packets), [[1, 8, 1]]);
  p.sources.touch.clear(); p.sync();
  p.key(event('keydown', {code: 'KeyQ', key: 'q'}), true);
  p.key(event('keydown', {code: 'KeyW', key: 'w'}), true);
  assert.deepEqual(buttonPackets(packets).slice(-3), [[1, 8, 0], [1, 10, 1], [1, 11, 1]]);
  assert.ok(p.btnL && p.btnR, 'GBA touch shoulder buttons are available');
}
// Two fingers can hold a diagonal and an action; cancelling one finger must retain the other.
{
  const {p, packets} = player();
  p.zones[0].rect = {left: 0, top: 0, width: 156, height: 156};
  p.zones.find(z => z.button === B.A).rect = {left: 300, top: 0, right: 366, bottom: 66, width: 66, height: 66};
  p.padPointer(event('pointerdown', {clientX: 125, clientY: 30}));
  p.padPointer(event('pointerdown', {pointerId: 2, clientX: 330, clientY: 30}));
  assert.deepEqual([...p.sources.touch].sort(), [B.UP, B.RIGHT, B.A].sort());
  p.padPointer(event('pointercancel'));
  assert.deepEqual([...p.sources.touch], [B.A]);
  p.padPointer(event('pointerup', {pointerId: 2}));
  assert.equal(p.sent.size, 0);
  assert.ok(buttonPackets(packets).some(p => p[1] === B.A && p[2] === 0));
  p.zones.find(z => z.button === B.A).rect = {left: 100, top: 0, right: 166, bottom: 66, width: 66, height: 66};
  assert.deepEqual([...p.hit(125, 30)], [B.A], 'direct button hits win over the d-pad generous margin');
}
// Physical controllers preserve Nintendo face mappings and can re-establish held input after a pause/blur release.
{
  const {p, packets} = player();
  const buttons = Array.from({length: 17}, () => ({pressed: false, value: 0}));
  buttons[0].pressed = buttons[4].pressed = true;
  gamepads = [{connected: true, buttons, axes: [-1, -1]}];
  p.tick();
  assert.ok(p.sources.pad.has(B.B) && p.sources.pad.has(B.L) && p.sources.pad.has(B.UP) && p.sources.pad.has(B.LEFT));
  p.releaseKeys();
  assert.equal(p.sources.pad.size, 0, 'release clears local physical-pad state');
  assert.equal(p.sent.size, 0, 'release clears sent-state cache');
  const before = packets.length; p.blurred = true; p.tick();
  assert.equal(packets.length, before, 'blurred pages cannot reassert controller input');
  p.blurred = false; p.tick();
  assert.ok(buttonPackets(packets.slice(before)).some(p => p[1] === B.B && p[2] === 1), 'held gamepad re-sends after release');
  gamepads = [];
}
// DOS physical keyboard carries key/character/modifier wire data, including function keys.
{
  const {p, packets} = player('pointer');
  p.key(event('keydown', {code: 'F5', key: 'F5', ctrlKey: true}), true);
  const data = new DataView(Uint8Array.from(packets.at(-1)).buffer);
  assert.equal(data.getUint8(0), 2); assert.equal(data.getUint16(2, true), 286);
  assert.equal(data.getUint16(8, true) & 2, 2);
  assert.equal(retroKey({code: 'ArrowUp', key: 'ArrowUp'}), 273);
  p.typer.value = 'A!'; p.typed();
  assert.ok(packets.some(p => Array.isArray(p) && p[0] === 2 && new DataView(Uint8Array.from(p).buffer).getUint32(4, true) === 33));
}
// ScummVM absolute coordinates/right-click and DOS scaled relative motion use the existing protocol.
for (const pointerMode of ['absolute', 'relative']) {
  const {p, packets} = player('pointer'); p.pointerMode = pointerMode;
  p.canvas.rect = {left: 10, top: 20, width: 512, height: 384}; p.canvas.width = 256; p.canvas.height = 192;
  fire(p.canvas, 'pointerdown', {pointerType: 'touch', clientX: 266, clientY: 212});
  time += 10;
  fire(p.canvas, 'pointermove', {pointerType: 'touch', clientX: 286, clientY: 232});
  fire(p.canvas, 'pointerup', {pointerType: 'touch', clientX: 286, clientY: 232}); flush();
  const motion = packets.find(p => Array.isArray(p) && p[0] === (pointerMode === 'absolute' ? 4 : 3));
  assert.ok(motion, pointerMode + ' sends its correct mouse packet');
  const view = new DataView(Uint8Array.from(motion).buffer);
  assert.equal(view.getFloat32(1, true), pointerMode === 'absolute' ? 0.5 : 16);
  p.rightClick = true;
  fire(p.canvas, 'pointerdown', {pointerType: 'touch', clientX: 100, clientY: 100});
  fire(p.canvas, 'pointerup', {pointerType: 'touch', clientX: 100, clientY: 100}); flush();
  assert.ok(packets.some(p => Array.isArray(p) && p.join() === '5,1,1'), pointerMode + ' supports right-click');
  fire(p.canvas, 'wheel', {deltaY: -100});
  assert.deepEqual(packets.at(-1), [8, 254], 'signed wheel packet remains intact');
  fire(p.canvas, 'pointerdown', {pointerType: 'touch', pointerId: 4, clientX: 120, clientY: 100});
  p.releaseKeys();
  const afterRelease = packets.length;
  fire(p.canvas, 'pointermove', {pointerType: 'touch', pointerId: 4, clientX: 150, clientY: 100});
  assert.equal(packets.length, afterRelease, 'a released touch cannot continue moving the pointer');
}
// Save-state capabilities and controller-only player switching remain distinct.
{
  const {p} = player('pointer'); p.info.saveStates = false; p.openMenu();
  const text = walk(p.root).map(e => e.textContent).join('\n');
  assert.ok(!text.includes('Save your place') && !text.includes('Go back to saved place'));
  const c = player(); c.p.mode = 'controller'; c.p.ctlTwo = true; c.p.ctlPlayer = 1; c.p.openMenu();
  const switcher = walk(c.p.root).find(e => e.textContent === 'Be player 2 instead');
  assert.ok(switcher, 'controller-only player2 remains available'); fire(switcher, 'click');
  assert.ok(c.packets.some(p => p.t === 'slot' && p.player === 2));
}
// PC Engine labels do not change libretro button values; ScummVM exposes its in-game F5 menu.
{
  const {p, packets} = player(); p.info.system = 'pcEngine'; p.buildControls('pad');
  assert.equal(p.btnA.textContent, 'I'); assert.equal(p.btnB.textContent, 'II'); assert.equal(p.btnStart.textContent, 'Run');
  assert.equal(p.zones.find(z => z.el === p.btnA).button, B.A);
  p.info = {system: 'scummvm', saveStates: false}; p.buildControls('pointer');
  const menu = walk(p.root).find(e => e.textContent === 'Game menu · F5');
  assert.ok(menu); fire(menu, 'pointerdown'); fire(menu, 'pointerup');
  const last = packets.filter(p => Array.isArray(p) && p[0] === 2).slice(-2);
  assert.deepEqual(last.map(p => [p[1], new DataView(Uint8Array.from(p).buffer).getUint16(2, true)]), [[1, 286], [0, 286]]);
}
// DOS modifier latches and function-key releases remain paired, and a host-configured joystick can switch views.
{
  const {p, packets} = player('pointer'); p.info = {system: 'dos', joystick: true}; p.buildControls('pointer');
  const find = text => walk(p.root).find(e => e.tagName === 'BUTTON' && e.textContent === text);
  fire(find('Ctrl'), 'click'); assert.equal(p.softMods(), 2);
  fire(find('F1'), 'pointerdown'); fire(find('F1'), 'pointerup');
  let keys = packets.filter(p => Array.isArray(p) && p[0] === 2);
  assert.equal(new DataView(Uint8Array.from(keys.at(-2)).buffer).getUint16(8, true), 2);
  fire(find('F2'), 'pointerdown'); p.releaseKeys();
  keys = packets.filter(p => Array.isArray(p) && p[0] === 2);
  assert.deepEqual(packets.at(-1), [6], 'host release-all clears held quick keys and modifiers');
  assert.equal(p.softMods(), 0); assert.equal(p.quickHeld.size, 0);
  fire(find('Joystick'), 'click'); assert.ok(p.joystickPad && p.zones.length >= 5);
  assert.ok(find('Keyboard') && find('Mouse & keys'), 'keyboard and return route survive joystick view');
  p.sources.touch.add(B.A); p.sync(); fire(find('Mouse & keys'), 'click');
  assert.equal(p.sent.size, 0); assert.equal(p.zones.length, 0);
  p.info.joystick = false; p.buildControls('pointer'); assert.ok(!find('Joystick'), 'no invented joystick mode for a keyboard-only host');
}
console.log('PASS browser inputs: pads, shoulders, diagonals, multi-source holds, releases, keyboard, pointer modes, wheel, save capabilities, controller slots');
