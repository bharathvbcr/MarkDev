'use strict';

// Progressive enhancement: the example and every navigation link work without JS.
const controls = document.querySelector('.demo-controls');
const preview = document.getElementById('preview-example');
const source = document.getElementById('source-example');
const status = document.getElementById('mode-status');
if (controls && preview && source && status) {
  controls.hidden = false;
  document.querySelectorAll('.interactive-hint').forEach((hint) => { hint.hidden = false; });
  controls.addEventListener('click', (event) => {
    if (!(event.target instanceof Element)) return;
    const button = event.target.closest('button[data-mode]');
    if (!button || !controls.contains(button)) return;
    const isSource = button.dataset.mode === 'source';
    preview.hidden = isSource;
    source.hidden = !isSource;
    controls.querySelectorAll('button').forEach((item) => {
      item.setAttribute('aria-pressed', String(item === button));
    });
    status.textContent = isSource ? 'Source example' : 'Preview example';
  });
}
