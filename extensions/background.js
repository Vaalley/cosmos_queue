/* Cosmos Queue Web Extension - Background Service Worker (MV3)
 * - Adds context menu items on YouTube/SoundCloud pages and links
 * - Listens to messages from the popup to add the current tab or a manual URL
 * - Posts to {serverBase}/append-queue with JSON { url, device_name }
 */

const API = typeof chrome !== 'undefined' ? chrome : browser;

const CTX_ADD_PAGE = 'cq_add_page';
const CTX_ADD_LINK = 'cq_add_link';

const DEFAULTS = {
  serverBase: 'http://localhost:5283',
  deviceName: 'Browser',
};

// Utility: get active tab
async function getActiveTab() {
  return new Promise((resolve) => {
    API.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      resolve((tabs && tabs[0]) || null);
    });
  });
}

// Ask the content script(s) in the active tab for the currently hovered link
async function getHoveredLinkFromActiveTab() {
  try {
    const tab = await getActiveTab();
    if (!tab || !tab.id) return { href: '', tabUrl: '' };

    // Try all frames to handle iframes (e.g., YouTube embeds, complex pages)
    let frameIds = [0];
    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      if (API.webNavigation && API.webNavigation.getAllFrames) {
        const frames = await new Promise((resolve) => {
          API.webNavigation.getAllFrames({ tabId: tab.id }, (arr) => resolve(arr || []));
        });
        if (Array.isArray(frames) && frames.length) {
          frameIds = frames.map((f) => f.frameId).filter((id) => typeof id === 'number');
        }
      }
    } catch (_) {}

    let hovered = '';
    for (const frameId of frameIds) {
      try {
        const reply = await new Promise((resolve) => {
          API.tabs.sendMessage(
            tab.id,
            { type: 'cq_getHoveredLink' },
            { frameId },
            (r) => resolve(r || {})
          );
        });
        if (reply && reply.href) {
          hovered = reply.href;
          if (hovered) break;
        }
      } catch (_) {}
    }

    return { href: hovered || '', tabUrl: tab.url || '' };
  } catch (e) {
    return { href: '', tabUrl: '' };
  }
}

API.runtime.onInstalled.addListener(() => {
  try {
    API.contextMenus.removeAll(() => {
      // Current page on YouTube/SoundCloud
      API.contextMenus.create({
        id: CTX_ADD_PAGE,
        title: 'Add page to Cosmos Queue',
        contexts: ['page'],
        documentUrlPatterns: [
          '*://*.youtube.com/*',
          '*://youtu.be/*',
          '*://*.soundcloud.com/*',
        ],
      });

      // Any link (useful on search result pages)
      API.contextMenus.create({
        id: CTX_ADD_LINK,
        title: 'Add link to Cosmos Queue',
        contexts: ['link'],
        targetUrlPatterns: [
          '*://*.youtube.com/*',
          '*://youtu.be/*',
          '*://*.soundcloud.com/*',
        ],
      });
    });
  } catch (e) {
    console.warn('CQ: failed to create context menus', e);
  }
});

// Keyboard shortcut: add hovered link (fallback to current tab URL)
try {
  API.commands.onCommand.addListener(async (command) => {
    if (command !== 'add-hovered-link') return;
    try {
      const { href, tabUrl } = await getHoveredLinkFromActiveTab();
      const candidate = href || tabUrl;
      if (!candidate) {
        notify('Cosmos Queue', 'No hovered link or active tab URL');
        return;
      }
      const tab = await getActiveTab();
      // show optimistic toast immediately near cursor
      if (tab && tab.id) {
        try {
          API.tabs.sendMessage(tab.id, { type: 'cq_showToast', text: 'Adding to queue…', success: true });
        } catch (_) {}
      }
      await addToQueue(candidate);
      // on success, show success toast
      if (tab && tab.id) {
        try {
          API.tabs.sendMessage(tab.id, { type: 'cq_showToast', text: 'Added to queue', success: true });
        } catch (_) {}
      }
    } catch (e) {
      const tab = await getActiveTab().catch(() => null);
      if (tab && tab.id) {
        try {
          API.tabs.sendMessage(tab.id, { type: 'cq_showToast', text: 'Failed to add', success: false });
        } catch (_) {}
      }
      notify('Cosmos Queue', 'Failed to add: ' + (e?.message || e));
    }
  });
} catch (e) {
  console.warn('CQ: commands not available', e);
}

API.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === CTX_ADD_PAGE && info.pageUrl) {
      await addToQueue(info.pageUrl);
    } else if (info.menuItemId === CTX_ADD_LINK && info.linkUrl) {
      await addToQueue(info.linkUrl);
    }
  } catch (e) {
    notify('Cosmos Queue', 'Failed to add: ' + (e?.message || e));
  }
});

API.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === 'addUrl' && msg.url) {
    (async () => {
      try {
        const res = await addToQueue(msg.url);
        sendResponse({ ok: true, res });
      } catch (e) {
        sendResponse({ ok: false, error: String(e) });
      }
    })();
    return true; // async response
  }
});

async function getSettings() {
  return new Promise((resolve) => {
    API.storage.sync.get(DEFAULTS, (items) => resolve(items || DEFAULTS));
  });
}

async function addToQueue(url) {
  const { serverBase, deviceName } = await getSettings();
  const endpoint = new URL('/append-queue', serverBase).toString();

  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url, device_name: deviceName }),
  });

  if (!resp.ok) {
    const text = await safeText(resp);
    badge('ERR');
    notify('Cosmos Queue', `Server error (${resp.status}): ${text || 'Unknown error'}`);
    throw new Error(`HTTP ${resp.status}: ${text}`);
  }

  badge('OK');
  notify('Cosmos Queue', 'Added to queue');
  return await resp.json().catch(() => ({}));
}

async function safeText(resp) {
  try { return await resp.text(); } catch { return ''; }
}

function badge(text) {
  try {
    API.action.setBadgeText({ text });
    API.action.setBadgeBackgroundColor({ color: text === 'OK' ? '#16a34a' : '#dc2626' });
    setTimeout(() => API.action.setBadgeText({ text: '' }), 2000);
  } catch {}
}

function notify(title, message) {
  try {
    API.notifications.create('', {
      type: 'basic',
      iconUrl: 'icons/icon-128.png',
      title,
      message,
    });
  } catch (e) {
    // Notifications may be blocked or permission missing
    console.debug('CQ notify fallback:', message);
  }
}
