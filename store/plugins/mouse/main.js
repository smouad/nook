// Mouse — smooth scrolling, scroll modifiers and button remapping. Engine: JSON-RPC to an isolated Swift helper.
const $ = (id) => document.getElementById(id);
let state = null;
let view = 'scroll';
let built = false;

const SMOOTH = [['off', 'Off'], ['low', 'Low'], ['regular', 'Regular'], ['high', 'High']];
const MODIFIERS = [['none', 'Nothing'], ['shift', '⇧ Shift'], ['option', '⌥ Option'], ['control', '⌃ Control'], ['command', '⌘ Command']];
const DRAG_MODES = [['none', 'Nothing'], ['spaces', 'Spaces (shortcuts)'], ['swipe', 'Spaces & Mission Control swipe'], ['scroll', 'Scroll']];
const WHEEL_MODES = [['none', 'Nothing'], ['horizontal', 'Sideways'], ['quick', 'Fast'], ['precise', 'Slow'], ['zoom', 'Zoom'],
  ['rotate', 'Rotate'], ['pinch', 'Launchpad / desktop pinch'], ['swipe', 'Spaces swipe']];
const SCROLL_STYLES = [['trackpad', 'Trackpad-style'], ['classic', 'Classic']];
const SPEED_MODES = [['system', 'macOS'], ['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['custom', 'Custom']];
const BUTTON_NAMES = { 2: 'Middle', 3: 'Back', 4: 'Forward' };
const buttonName = (n) => BUTTON_NAMES[n] || `Button ${Number(n) + 1}`;

function showError(message, action) {
  const el = $('error');
  el.hidden = !message;
  if (!message) return;
  el.replaceChildren(Object.assign(document.createElement('span'), { className: 'nk-fill', textContent: message }));
  if (action) {
    const b = Object.assign(document.createElement('button'), { className: 'nk-btn nk-danger', textContent: action.label });
    b.onclick = action.run;
    el.append(b);
  }
}

async function call(fn, ...args) {
  try {
    const next = await nook.native.call('mouse.' + fn, { args });
    if (next) { state = next; render(); }
  } catch (err) {
    showError(`Couldn't ${fn.replace(/([A-Z])/g, ' $1').toLowerCase()}: ${err.message || err}`);
  }
}

/** Slider drags fire a lot; send at most one write per 120 ms, always ending on the final value. */
const timers = {};
function setSoon(key, value) {
  state.config[key] = value;
  clearTimeout(timers[key]);
  timers[key] = setTimeout(() => call('set', { [key]: value }), 120);
}

// ---- Scroll form -------------------------------------------------------------

function field(label, control, extra = '', hint = '') {
  const row = document.createElement('div');
  row.className = `field ${extra}`;
  if (hint) row.title = hint;
  const l = Object.assign(document.createElement('span'), { className: 'name', textContent: label });
  const input = control.matches('input,select,button') ? control : control.querySelector('input,select');
  input?.setAttribute('aria-label', label);
  row.append(l, control);
  return row;
}

function select(options, key) {
  const el = document.createElement('select');
  el.className = 'nk-input pick';
  for (const [value, text] of options) el.append(Object.assign(document.createElement('option'), { value, textContent: text }));
  el.onchange = () => call('set', { [key]: el.value });
  el.dataset.key = key;
  return el;
}

function slider(key, min, max, step, format) {
  const wrap = document.createElement('div');
  wrap.className = 'nk-row-flex nk-fill';
  const input = Object.assign(document.createElement('input'), { type: 'range', min, max, step, className: 'nk-fill' });
  const value = Object.assign(document.createElement('span'), { className: 'value' });
  input.dataset.key = key;
  input.oninput = () => { value.textContent = format(+input.value); setSoon(key, +input.value); };
  wrap.append(input, value);
  wrap.sync = (v) => { if (document.activeElement !== input) input.value = v; value.textContent = format(v); };
  return wrap;
}

function toggle(key) {
  const label = document.createElement('label');
  label.className = 'nk-switch';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.dataset.key = key;
  input.onchange = () => call('set', { [key]: input.checked });
  label.append(input, document.createElement('span'));
  return label;
}

function buildScroll() {
  const form = $('scroll');
  form.replaceChildren(); // the loading spinner
  const seg = document.createElement('div');
  seg.className = 'nk-seg nk-roving';
  seg.dataset.nkOrientation = 'horizontal';
  seg.setAttribute('aria-label', 'Smoothness');
  seg.dataset.key = 'smoothness';
  for (const [value, text] of SMOOTH) {
    const b = Object.assign(document.createElement('button'), { textContent: text });
    b.dataset.value = value;
    b.dataset.nkItem = value;
    b.onclick = () => call('set', { smoothness: value });
    seg.append(b);
  }
  form.append(
    field('Smoothness', seg),
    field('Reverse direction', toggle('reverse')),
    field('Filter wheel chatter', toggle('filterChatter')),
    field('Speed', select(SPEED_MODES, 'speedMode')),
    field('Custom speed', slider('speed', 0.3, 3, 0.1, (v) => `${v.toFixed(1)}×`), 'custom-speed'),
    field('Acceleration', slider('acceleration', 0, 1, 0.05, (v) => `${Math.round(v * 100)}%`), 'custom-speed'),
  );
  const sub = Object.assign(document.createElement('div'), { className: 'sub', textContent: 'While scrolling, hold…' });
  form.append(
    sub,
    field('Sideways', select(MODIFIERS, 'horizontalModifier')),
    field('Slow (precise)', select(MODIFIERS, 'preciseModifier')),
    field('Fast', select(MODIFIERS, 'quickModifier')),
    field('Zoom', select(MODIFIERS, 'zoomModifier')),
    field('Scroll style', select(SCROLL_STYLES, 'scrollStyle'), '',
      'Trackpad-style sends a swipe-like gesture and momentum, so pages that snap (YouTube Shorts, Safari) work. Classic sends plain scroll events.'),
  );
  built = true;
}

function syncScroll() {
  const c = state.config;
  for (const el of $('scroll').querySelectorAll('.custom-speed')) el.hidden = c.speedMode !== 'custom';
  for (const b of $('scroll').querySelectorAll('[data-key=smoothness] button')) b.classList.toggle('nk-on', b.dataset.value === c.smoothness);
  for (const el of $('scroll').querySelectorAll('select[data-key]')) el.value = c[el.dataset.key];
  for (const el of $('scroll').querySelectorAll('input[type=checkbox][data-key]')) el.checked = !!c[el.dataset.key];
  for (const wrap of $('scroll').querySelectorAll('.nk-row-flex')) {
    const input = wrap.querySelector('input[type=range]');
    if (input) wrap.sync(c[input.dataset.key]);
  }
}

// ---- Buttons -----------------------------------------------------------------

let selectedButton = null;
let buttonIDs = [];
let listShown = '';
let editorShown = '';

function actionSelect(rule, key, none) {
  const options = state.actions.map(a => [a.id, a.id === 'none' ? none : a.label]);
  return buttonSelect(rule, key, options);
}

function buttonSelect(rule, key, options) {
  const el = document.createElement('select');
  el.className = 'nk-input pick';
  for (const [value, text] of options) {
    el.append(Object.assign(document.createElement('option'), { value, textContent: text }));
  }
  el.dataset.rule = key;
  el.dataset.button = selectedButton;
  el.value = rule[key] || 'none';
  el.onchange = () => call('setButton', el.dataset.button, { [key]: el.value });
  return el;
}

function opt(label, control) {
  const wrap = document.createElement('label');
  wrap.className = 'opt';
  control.setAttribute('aria-label', `${buttonName(selectedButton)} button: ${label}`);
  wrap.append(Object.assign(document.createElement('span'), { textContent: label }), control);
  return wrap;
}

function renderRules() {
  const list = $('buttonList'), editor = $('buttonEditor');
  const entries = Object.entries(state.config.buttons).sort((a, b) => Number(a[0]) - Number(b[0]));
  const ids = entries.map(([button]) => button);
  const focused = document.activeElement;
  const focusButton = focused?.dataset.button;
  const focusRule = focused?.dataset.rule;
  const focusedList = list.contains(focused);
  const focusedEditor = editor.contains(focused);
  const oldSelection = editor.dataset.button;
  if (!ids.includes(selectedButton)) {
    const oldIndex = Math.max(0, buttonIDs.indexOf(selectedButton));
    selectedButton = ids[Math.min(oldIndex, ids.length - 1)] ?? null;
  }
  buttonIDs = ids;
  list.hidden = editor.hidden = !ids.length;
  $('buttonsEmpty').hidden = !!ids.length;

  const listSignature = JSON.stringify(ids);
  if (listSignature !== listShown) {
    listShown = listSignature;
    const top = list.scrollTop;
    list.replaceChildren(...ids.map(button => {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'nk-item button-choice';
      item.dataset.button = button;
      item.dataset.nkItem = button;
      item.innerHTML = '<svg aria-hidden="true"><use href="#i-mouse"/></svg>';
      item.append(Object.assign(document.createElement('span'), { className: 'nk-ellipsis', textContent: buttonName(button) }));
      item.onclick = () => { selectedButton = button; renderRules(); };
      return item;
    }));
    list.scrollTop = top;
    if (focusedList) {
      const target = [...list.children].find(el => el.dataset.button === focusButton) ||
        [...list.children].find(el => el.dataset.button === selectedButton) || $('learn');
      target.focus({ preventScroll: true });
    }
  }
  for (const item of list.children) {
    const chosen = item.dataset.button === selectedButton;
    item.classList.toggle('nk-selected', chosen);
    item.setAttribute('aria-pressed', String(chosen));
  }

  if (!selectedButton) {
    editor.replaceChildren();
    editorShown = '';
    delete editor.dataset.button;
    if (focusedEditor) $('learn').focus();
    return;
  }
  const rule = state.config.buttons[selectedButton];
  const editorSignature = JSON.stringify([selectedButton, state.actions]);
  if (editorSignature !== editorShown) {
    editorShown = editorSignature;
    editor.dataset.button = selectedButton;
    const top = oldSelection === selectedButton ? editor.scrollTop : 0;
    const header = document.createElement('div');
    header.className = 'nk-row-flex button-editor-header';
    const heading = Object.assign(document.createElement('h2'), { className: 'nk-title nk-fill', textContent: buttonName(selectedButton) });
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'nk-icon-btn';
    remove.title = 'Remove button';
    remove.dataset.button = selectedButton;
    remove.dataset.rule = 'remove';
    remove.setAttribute('aria-label', `Remove ${buttonName(selectedButton)} button`);
    remove.innerHTML = '<svg aria-hidden="true"><use href="#i-x"/></svg>';
    remove.onclick = () => call('removeButton', remove.dataset.button);
    header.append(heading, remove);
    const fields = document.createElement('div');
    fields.className = 'button-fields';
    fields.append(
      opt('Single click', actionSelect(rule, 'click', 'Default')),
      opt('Double click', actionSelect(rule, 'double', 'Default')),
      opt('Triple click', actionSelect(rule, 'triple', 'Default')),
      opt('Hold', actionSelect(rule, 'hold', 'Nothing')),
      opt('Drag', buttonSelect(rule, 'drag', DRAG_MODES)),
      opt('Wheel while held', buttonSelect(rule, 'scroll', WHEEL_MODES)),
    );
    editor.replaceChildren(header, fields);
    editor.scrollTop = top;
    if (focusedEditor) {
      const next = [...editor.querySelectorAll('[data-rule]')].find(el => el.dataset.rule === focusRule);
      (next || remove).focus({ preventScroll: true });
    }
  } else {
    // Keep the actual selects alive across native notices and remap replies. This also keeps
    // an open dropdown, the focused field and the editor's scroll position intact.
    for (const control of editor.querySelectorAll('select[data-rule]')) {
      const value = rule[control.dataset.rule] || 'none';
      if (control.value !== value) control.value = value;
    }
  }
}

// ---- Page --------------------------------------------------------------------

function render() {
  if (!state) return;
  const c = state.config;
  if (!built) buildScroll();
  $('enabled').checked = c.enabled;
  syncScroll();
  renderRules();

  const pill = $('status');
  const needsPermission = c.enabled && !state.trusted;
  pill.className = `nk-pill ${!c.enabled ? '' : needsPermission ? 'nk-bad' : state.running ? 'nk-good' : 'nk-accent'}`;
  pill.lastElementChild.textContent = !c.enabled ? 'Off' : needsPermission ? 'Needs permission' : state.error ? 'Unavailable' : state.running ? 'Active' : 'Starting…';

  const learning = state.learning;
  $('learn').textContent = learning ? 'Cancel' : 'Add a button';
  $('learn').classList.toggle('nk-primary', !learning);
  $('learnHint').textContent = learning ? 'Press the mouse button you want to set up…' : '';
  $('learnHint').classList.toggle('learning', learning);

  if (needsPermission || (learning && !state.trusted)) {
    showError('Allow Nook in Accessibility so it can read your mouse.', { label: 'Open Settings', run: () => call('openPrivacy') });
  } else if (state.error && (c.enabled || learning)) {
    showError(state.error, { label: 'Retry', run: refresh });
  } else {
    showError('');
  }
  $('enabled').disabled = false;
  $('learn').disabled = false;
  $('preset').disabled = false;
}

async function refresh() {
  try {
    state = await nook.native.call('mouse.state', { args: [] });
    render();
  } catch (err) {
    if (!state) {
      $('scroll').replaceChildren();
      built = false;
      $('status').lastElementChild.textContent = 'Unavailable';
    }
    showError(`Couldn't reach the mouse engine: ${err.message || err}`, { label: 'Retry', run: refresh });
  }
}

$('enabled').onchange = (e) => call('set', { enabled: e.target.checked });
$('preset').onclick = () => call('applyPreset', 'defaults');
$('learn').onclick = () => call('learn', !state?.learning);
$('view').onclick = (e) => {
  const b = e.target.closest('button[data-view]');
  if (!b) return;
  view = b.dataset.view;
  for (const x of $('view').children) x.classList.toggle('nk-on', x === b);
  $('scroll').hidden = view !== 'scroll';
  $('buttons').hidden = view !== 'buttons';
};

nook.native.on('mouse', (d) => {
  if (d.button !== undefined && state) {
    // Select the learned button, including one that is already configured.
    selectedButton = String(d.button);
    if (!state.config.buttons[d.button]) call('setButton', selectedButton, {});
    else refresh();
  } else {
    refresh();
  }
});
nook.native.on('ready', refresh);
nook.native.on('mouseActionUnavailable', ({ message }) => showError(message));
nook.on('show', refresh);
nook.on('open', refresh);
nook.on('close', () => { if (state?.learning) call('learn', false); });
document.addEventListener('keydown', (event) => {
  // Native buttons support Enter/Space; also provide the requested Command-Enter path outside roving groups.
  const button = event.target.closest('button');
  if (event.key === 'Enter' && event.metaKey && button && !event.defaultPrevented && !button.closest('.nk-roving')) {
    event.preventDefault(); button.click();
  }
});
document.addEventListener('nk:alt', (event) => {
  const button = event.target.closest('button');
  if (button) { event.preventDefault(); button.click(); }
});
refresh();
