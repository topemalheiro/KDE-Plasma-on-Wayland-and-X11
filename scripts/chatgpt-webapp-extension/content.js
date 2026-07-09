(() => {
  const BANNER_SELECTOR = 'div.bg-token-main-surface-secondary.w-full';
  const TARGET_TEXT = 'A workspace member hit a limit';
  const CTA_TEXT = 'Turn on auto-reload';

  function removeMatchingBanner(root = document) {
    const banners = root.querySelectorAll(BANNER_SELECTOR);
    for (const banner of banners) {
      const text = (banner.textContent || '').replace(/\s+/g, ' ').trim();
      if (text.includes(TARGET_TEXT) && text.includes(CTA_TEXT)) {
        banner.remove();
      }
    }
  }

  removeMatchingBanner();

  const observer = new MutationObserver(() => removeMatchingBanner());
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
})();
