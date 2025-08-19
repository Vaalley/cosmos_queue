// Cosmos Queue content script: tracks the currently hovered link
// Responds to messages from background with the latest hovered link href
(function() {
  const API = typeof chrome !== 'undefined' ? chrome : browser;
  let lastHref = '';
  let lastUpdateTs = 0;
  let lastX = -1;
  let lastY = -1;

  function findHrefFromNode(node) {
    if (!node) return '';
    const a = node.closest ? node.closest('a[href]') : null;
    if (a && a.href) {
      try {
        // Resolve relative links
        return new URL(a.getAttribute('href'), location.href).href;
      } catch (_) {
        return a.href || '';
      }
    }
    return '';
  }

  function updateFromEvent(e) {
    const now = Date.now();
    if (now - lastUpdateTs < 100) return; // throttle
    lastUpdateTs = now;
    const href = findHrefFromNode(e.target);
    if (href) lastHref = href;
  }

  function updateMousePos(e) {
    lastX = e.clientX;
    lastY = e.clientY;
  }

  // Fallback: check :hover stack occasionally
  function pollHoverStack() {
    try {
      const hovered = document.querySelectorAll(':hover');
      const node = hovered && hovered.length ? hovered[hovered.length - 1] : null;
      const href = findHrefFromNode(node);
      if (href) lastHref = href;
    } catch (_) {
      // Some pages may restrict :hover access, ignore
    }
  }

  document.addEventListener('mouseover', updateFromEvent, true);
  document.addEventListener('mousemove', updateMousePos, true);
  document.addEventListener('pointermove', updateMousePos, true);
  document.addEventListener('focusin', updateFromEvent, true);

  // Light polling as a backup (once per second)
  const poller = setInterval(pollHoverStack, 1000);

  // Simple toast utility (rendered only in top frame)
  function clamp(v, min, max) { return Math.max(min, Math.min(max, v)); }
  function showToast(text, success = true, x, y) {
    try {
      if (window.top !== window) return; // avoid duplicate toasts in iframes
      const doc = document;
      const root = doc.documentElement || doc.body;
      const toast = doc.createElement('div');
      toast.textContent = text || 'Added to queue';
      toast.style.position = 'fixed';
      toast.style.zIndex = '2147483647';
      toast.style.padding = '8px 12px';
      toast.style.borderRadius = '8px';
      toast.style.font = '13px system-ui, -apple-system, Segoe UI, Roboto, sans-serif';
      toast.style.color = '#fff';
      toast.style.background = success ? 'rgba(22,163,74,0.95)' : 'rgba(220,38,38,0.95)';
      toast.style.boxShadow = '0 4px 16px rgba(0,0,0,0.3)';
      toast.style.pointerEvents = 'none';
      toast.style.opacity = '0';
      toast.style.transition = 'opacity 120ms ease-out, transform 120ms ease-out';

      // Position near cursor if available, else bottom-right
      const vw = root.clientWidth;
      const vh = root.clientHeight;
      const margin = 16;
      const tw = 240; // approximate for clamping
      const th = 40;
      let px = (typeof x === 'number' ? x : lastX);
      let py = (typeof y === 'number' ? y : lastY);
      if (typeof px === 'number' && px >= 0 && typeof py === 'number' && py >= 0) {
        px = clamp(px + 12, margin, vw - tw - margin);
        py = clamp(py + 12, margin, vh - th - margin);
        toast.style.left = px + 'px';
        toast.style.top = py + 'px';
        toast.style.transform = 'translateY(-4px)';
      } else {
        toast.style.right = margin + 'px';
        toast.style.bottom = margin + 'px';
        toast.style.transform = 'translateY(4px)';
      }

      doc.body.appendChild(toast);
      requestAnimationFrame(() => {
        toast.style.opacity = '1';
        toast.style.transform = 'translateY(0)';
      });
      setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transform = 'translateY(4px)';
        setTimeout(() => toast.remove(), 180);
      }, 1800);
    } catch (_) {}
  }

  // Respond to background requests
  try {
    API.runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (msg && msg.type === 'cq_getHoveredLink') {
        // Best effort: compute current element under pointer
        let href = '';
        try {
          if (lastX >= 0 && lastY >= 0 && typeof document.elementFromPoint === 'function') {
            const el = document.elementFromPoint(lastX, lastY);
            href = findHrefFromNode(el);
          }
        } catch (_) {}
        if (!href) href = lastHref;
        // As a final fallback, if focused element is a link
        if (!href) {
          const ae = document.activeElement;
          href = findHrefFromNode(ae);
        }
        sendResponse({ href });
        return; // synchronous response
      }
      if (msg && msg.type === 'cq_showToast') {
        showToast(msg.text, !!msg.success, msg.x, msg.y);
        sendResponse && sendResponse({ ok: true });
        return; // synchronous response
      }
    });
  } catch (_) {}

  // Cleanup on unload
  window.addEventListener('unload', () => clearInterval(poller));
})();
