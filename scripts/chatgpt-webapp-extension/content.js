(() => {
  const BANNER_SELECTOR = 'div.bg-token-main-surface-secondary.w-full';
  const TARGET_TEXT = 'A workspace member hit a limit';
  const CTA_TEXT = 'Turn on auto-reload';
  const BODY_TEXT = 'Turn on auto-reload to automatically add credits and prevent future interruptions.';
  const HIDDEN_ATTR = 'data-chatgpt-limit-banner-hidden';

  function normalizeText(value) {
    return (value || '').replace(/\s+/g, ' ').trim();
  }

  function isMatchingBanner(banner) {
    const title = banner.querySelector('p.text-lg.font-semibold');
    const body = banner.querySelector('p.md\\:ms-8');
    const button = banner.querySelector('button');
    const text = normalizeText(banner.textContent);

    return (
      normalizeText(title?.textContent) === TARGET_TEXT &&
      normalizeText(body?.textContent) === BODY_TEXT &&
      normalizeText(button?.textContent).includes(CTA_TEXT) &&
      text.includes(TARGET_TEXT) &&
      text.includes(CTA_TEXT)
    );
  }

  function hideMatchingBanner(root = document) {
    const banners = root.querySelectorAll(BANNER_SELECTOR);
    for (const banner of banners) {
      if (!isMatchingBanner(banner)) {
        continue;
      }

      if (banner.getAttribute(HIDDEN_ATTR) !== 'true') {
        banner.setAttribute(HIDDEN_ATTR, 'true');
        banner.style.setProperty('display', 'none', 'important');
        banner.style.setProperty('visibility', 'hidden', 'important');
        banner.setAttribute('aria-hidden', 'true');
      }
    }
  }

  hideMatchingBanner();

  const observer = new MutationObserver(() => hideMatchingBanner());
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
})();
