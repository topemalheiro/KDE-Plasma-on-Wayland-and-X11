(() => {
  const TARGET_TEXT = /A workspace member hit a limit/i;
  const CTA_TEXT = /Turn on auto-reload/i;
  const HIDDEN_CLASS = 'codex-chatgpt-limit-banner-hidden';

  const style = document.createElement('style');
  style.textContent = `.${HIDDEN_CLASS} { display: none !important; }`;
  document.documentElement.appendChild(style);

  function hideBanner(node) {
    if (!(node instanceof Element)) {
      return;
    }

    const wrapper = node.closest('div.bg-token-main-surface-secondary') || node;
    wrapper.classList.add(HIDDEN_CLASS);
  }

  function scan(root = document) {
    const nodes = root.querySelectorAll('p, button, div');
    for (const node of nodes) {
      const text = (node.textContent || '').trim();
      if (!TARGET_TEXT.test(text) && !CTA_TEXT.test(text)) {
        continue;
      }

      if (TARGET_TEXT.test(text)) {
        hideBanner(node);
      } else {
        const parent = node.closest('div.bg-token-main-surface-secondary');
        if (parent && TARGET_TEXT.test(parent.textContent || '')) {
          hideBanner(parent);
        }
      }
    }
  }

  scan();

  const observer = new MutationObserver(() => scan());
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
})();
