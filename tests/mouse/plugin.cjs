const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const plugin = process.argv[2];
const html = fs.readFileSync(path.join(plugin, 'index.html'), 'utf8');
const source = fs.readFileSync(path.join(plugin, 'main.js'), 'utf8');
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

async function setup(failFirst = false) {
  const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'https://mouse.test/' });
  const w = dom.window, events = {}, calls = [];
  let failed = failFirst;
  let state = {
    config: { enabled: false, smoothness: 'regular', speed: 1, speedMode: 'custom', acceleration: 0.5, reverse: false,
      filterChatter: false, scrollStyle: 'trackpad', horizontalModifier: 'shift', preciseModifier: 'none', quickModifier: 'none', buttons: {} },
    trusted: true, running: false, learning: false, error: null,
    actions: [{ id: 'none', label: 'Default' }, { id: 'copy', label: 'Copy' }, { id: 'back', label: 'Back' }],
  };
  w.nook = { on(event, fn) { events[event] = fn; }, mouse: new Proxy({}, {
    get(_, fn) { return async (...args) => {
      calls.push([fn, ...args]);
      if (failed) { failed = false; throw new Error('Engine disconnected'); }
      if (fn === 'set') Object.assign(state.config, args[0]);
      if (fn === 'learn') state.learning = args[0];
      if (fn === 'setButton') state.config.buttons[args[0]] = { click: 'none', double: 'none', triple: 'none', hold: 'none', drag: 'none', scroll: 'none', ...state.config.buttons[args[0]], ...args[1] };
      if (fn === 'removeButton') delete state.config.buttons[args[0]];
      if (fn === 'applyPreset') {
        Object.assign(state.config, {smoothness: 'high', speedMode: 'medium', speed: 1, acceleration: 0.5, reverse: true, preciseModifier: 'option', quickModifier: 'control', zoomModifier: 'command'});
        Object.assign(state.config.buttons, {
        2: { click: 'lookUp', double: 'launchpad', triple: 'none', hold: 'showDesktop', drag: 'swipe', scroll: 'none' },
        4: { click: 'smartZoom', double: 'none', triple: 'none', hold: 'none', drag: 'scroll', scroll: 'zoom' },
      });
      }
      return JSON.parse(JSON.stringify(state));
    }; }
  }) };
  w.nook.native = { call(method, params) { return w.nook.mouse[method.slice(6)](...params.args); }, on(event, callback) { events[event] = callback; } };
  w.eval(source);
  await tick();
  return { w, events, state, calls, $: id => w.document.getElementById(id), close: () => w.close() };
}

(async () => {
  const x = await setup(true);
  assert.match(x.$('error').textContent, /Engine disconnected/);
  assert.equal(x.$('enabled').disabled, true);
  x.$('error').querySelector('button').click(); await tick();
  assert.equal(x.$('error').hidden, true);
  assert.equal(x.$('enabled').disabled, false);
  assert.equal(x.$('status').lastElementChild.textContent, 'Off');
  assert.match(x.$('rules').textContent, /No buttons yet/);
  assert.equal(x.$('scroll').querySelector('[data-key="filterChatter"]').checked, false);
  for (const el of x.w.document.querySelectorAll('select,input')) {
    assert.ok(el.getAttribute('aria-label'), 'Every form control has an accessible name');
  }
  const chatter = x.$('scroll').querySelector('[data-key="filterChatter"]');
  chatter.checked = true; chatter.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.filterChatter, true);
  const style = x.$('scroll').querySelector('[data-key="scrollStyle"]');
  assert.equal(style.value, 'trackpad');
  style.value = 'classic'; style.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.scrollStyle, 'classic');
  const speedMode = x.$('scroll').querySelector('[data-key="speedMode"]');
  speedMode.value = 'medium'; speedMode.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.speedMode, 'medium');
  assert.equal(x.$('scroll').querySelector('.custom-speed').hidden, true);
  speedMode.value = 'custom'; speedMode.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.$('scroll').querySelector('.custom-speed').hidden, false);
  x.events.mouseActionUnavailable({message: 'Assign a shortcut in Keyboard settings.'});
  assert.match(x.$('error').textContent, /Assign a shortcut/);
  const enabled = x.$('enabled');
  enabled.checked = true; enabled.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.enabled, true);
  x.state.error = "Couldn't start the mouse event tap. Check Accessibility; Nook will retry automatically.";
  x.events.mouse({}); await tick();
  assert.equal(x.$('status').lastElementChild.textContent, 'Unavailable');
  assert.match(x.$('error').textContent, /retry automatically/);
  x.state.error = null; x.state.running = true; x.events.mouse({}); await tick();
  assert.equal(x.$('error').hidden, true);
  assert.equal(x.$('status').lastElementChild.textContent, 'Active');
  x.state.trusted = false; x.events.mouse({}); await tick();
  assert.match(x.$('error').textContent, /Allow Nook in Accessibility/);
  x.$('error').querySelector('button').click(); await tick();
  assert.ok(x.calls.some(([fn]) => fn === 'openPrivacy'));
  x.state.trusted = true;
  x.$('view').querySelector('[data-view="buttons"]').click();
  assert.equal(x.$('scroll').hidden, true); assert.equal(x.$('buttons').hidden, false);
  x.$('learn').dispatchEvent(new x.w.KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true, cancelable: true })); await tick();
  assert.equal(x.state.learning, true);
  x.state.learning = false;
  x.events.mouse({ button: 3 }); await tick();
  assert.ok(x.state.config.buttons['3']);
  let select = x.$('rules').querySelector('[data-rule="click"]');
  select.focus(); select.value = 'copy'; select.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.buttons['3'].click, 'copy');
  assert.equal(x.w.document.activeElement.dataset.rule, 'click', 'Focus survives rule repaint');
  assert.equal(x.w.document.activeElement.dataset.button, '3');
  x.$('rules').querySelector('[data-rule="remove"]').click(); await tick();
  assert.match(x.$('rules').textContent, /No buttons yet/);
  // Every control of a button's card: click levels, hold, drag and wheel-while-held.
  x.events.mouse({ button: 3 }); await tick();
  for (const rule of ['click', 'double', 'triple', 'hold', 'drag', 'scroll']) {
    assert.ok(x.$('rules').querySelector(`[data-rule="${rule}"]`), `A button card has a ${rule} control`);
  }
  const wheel = x.$('rules').querySelector('[data-rule="scroll"]');
  wheel.value = 'zoom'; wheel.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.state.config.buttons['3'].scroll, 'zoom');
  x.$('rules').querySelector('[data-rule="remove"]').click(); await tick();
  // Restore Nook's default buttons in one click.
  x.$('preset').click(); await tick();
  assert.ok(x.calls.some(([fn, name]) => fn === 'applyPreset' && name === 'defaults'), 'The defaults button uses the neutral bridge name');
  assert.equal(x.state.config.speedMode, 'medium');
  assert.equal(x.state.config.preciseModifier, 'option');
  assert.equal(x.state.config.reverse, true);
  assert.equal(x.$('buttonList').querySelectorAll('.button-choice').length, 2);
  assert.equal(x.$('buttonEditor').querySelectorAll('select').length, 6, 'Only the selected button has an editor');
  assert.equal(x.$('rules').querySelector('[data-button="2"][data-rule="drag"]').value, 'swipe');
  for (const button of [2, 4]) {
    x.$('buttonList').querySelector(`[data-button="${button}"]`).click();
    x.$('buttonEditor').querySelector('[data-rule="remove"]').click(); await tick();
  }
  assert.equal(x.$('buttonList').hidden, true);
  assert.equal(x.$('buttonEditor').hidden, true);
  assert.equal(x.$('buttonsEmpty').hidden, false);

  const blankRule = () => ({click: 'none', double: 'none', triple: 'none', hold: 'none', drag: 'none', scroll: 'none'});
  x.state.config.buttons = {'2': blankRule(), '3': blankRule(), '4': blankRule()};
  x.events.mouse({}); await tick();
  const chosen = () => x.$('buttonList').querySelector('.nk-selected')?.dataset.button;
  const choose = button => x.$('buttonList').querySelector(`[data-button="${button}"]`).click();
  assert.equal(chosen(), '2', 'The first button is selected initially');
  assert.equal(x.$('buttonList').querySelectorAll('.button-choice').length, 3);
  choose('3');
  assert.equal(chosen(), '3');
  assert.equal(x.$('buttonEditor').querySelector('h2').textContent, 'Back');
  assert.deepEqual([...x.$('buttonEditor').querySelectorAll('label > span')].map(el => el.textContent),
    ['Single click', 'Double click', 'Triple click', 'Hold', 'Drag', 'Wheel while held']);
  let focusedDrag = x.$('buttonEditor').querySelector('[data-rule="drag"]');
  focusedDrag.focus();
  x.$('buttonEditor').scrollTop = 40;
  focusedDrag.value = 'scroll'; focusedDrag.dispatchEvent(new x.w.Event('change')); await tick();
  assert.equal(x.w.document.activeElement, focusedDrag, 'Remapping retains the actual focused selector');
  assert.equal(x.$('buttonEditor').scrollTop, 40, 'Remapping retains editor scroll position');
  x.events.mouse({}); await tick();
  assert.equal(chosen(), '3', 'Native status notices retain selection');
  assert.equal(x.w.document.activeElement, focusedDrag, 'Native notices retain the focused selector');
  x.state.config.buttons['2'].click = 'copy'; x.events.mouse({}); await tick();
  assert.equal(x.$('buttonEditor').querySelector('[data-rule="drag"]'), focusedDrag, 'Other button changes retain this editor');
  x.events.mouse({button: 4}); await tick();
  assert.equal(chosen(), '4', 'Learning an existing button selects it');
  assert.equal(x.$('buttonEditor').scrollTop, 0, 'Changing selection resets the editor scroll position');
  x.events.mouse({button: 9}); await tick();
  assert.equal(chosen(), '9', 'Learning a new button selects it after the save');
  assert.ok(x.state.config.buttons['9']);
  x.$('buttonEditor').querySelector('[data-rule="remove"]').click(); await tick();
  assert.equal(chosen(), '4', 'Removing the last button selects its previous neighbor');
  choose('3');
  x.$('buttonEditor').querySelector('[data-rule="remove"]').click(); await tick();
  assert.equal(chosen(), '4', 'Removing a middle button selects its next neighbor');
  assert.equal(x.w.document.activeElement.dataset.button, '4', 'Removal moves editor focus to the replacement button');

  x.state.config.buttons = Object.fromEntries(Array.from({length: 300}, (_, i) => [String(i + 2), blankRule()]));
  x.events.mouse({}); await tick();
  assert.equal(x.$('buttonList').querySelectorAll('.button-choice').length, 300, 'Large button lists remain inside their own scroll region');
  assert.equal(x.$('buttonEditor').querySelectorAll('select').length, 6, 'A large list still renders only six editor selectors');
  assert.equal(chosen(), '4', 'Growing the list preserves the selected button');
  choose('301');
  const lastClick = x.$('buttonEditor').querySelector('[data-rule="click"]');
  lastClick.focus(); x.events.mouse({}); await tick();
  assert.equal(x.w.document.activeElement, lastClick, 'Focus remains on the selected editor with 300 buttons');
  assert.ok(!/Mac Mouse Fix|MMF/.test(x.w.document.body.textContent), 'Visible settings use neutral Nook names');
  assert.equal(x.$('preset').textContent, 'Restore defaults');
  x.state.config.buttons = {}; x.events.mouse({}); await tick();
  assert.equal(x.$('buttonEditor').hidden, true);
  assert.equal(x.$('buttonEditor').querySelectorAll('select').length, 0);
  assert.equal(x.w.document.activeElement, x.$('learn'), 'Removing all buttons leaves focus on Add a button');
  x.state.learning = true; x.events.mouse({}); await tick(); x.events.close(); await tick();
  assert.equal(x.state.learning, false, 'Closing cancels learning');
  assert.ok(x.$('view').classList.contains('nk-roving'));
  assert.equal(x.$('view').dataset.nkOrientation, 'horizontal');
  x.close();
  console.log('PASS: Mouse plugin mocked window.nook loading/error/retry/permission/recovery, chatter setting, learn/remap/remove, focus and keyboard actions (under /tmp)');
})().catch(error => { console.error(error); process.exitCode = 1; });
