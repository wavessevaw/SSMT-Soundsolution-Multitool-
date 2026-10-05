'use strict';
/* global SSMT */
// Functions not yet ported from the Mac app. Each is replaced by its own file (sections/<id>.js) as it is ported.
(function () {
  const { t, esc, UI } = SSMT;
  for (const id of ['setup', 'inputList', 'show', 'handbook']) {
    if (SSMT.sections[id]) continue;
    SSMT.section({
      id,
      render: () => `<div style="padding:40px">${UI.panel(t('section.' + id), `<p class="secondary-text">${esc(SSMT.S.lang === 'ru' ? 'Этот раздел переносится с Mac.' : 'This section is being ported from the Mac app.')}</p>`)}</div>`,
    });
  }
})();
