const API = typeof chrome !== 'undefined' ? chrome : browser;

function setStatus(text, ok = true) {
  const el = document.getElementById('status');
  el.textContent = text || '';
  el.style.color = ok ? '#a7f3d0' : '#fecaca';
}

async function getActiveTabUrl() {
  return new Promise((resolve) => {
    API.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const url = tabs && tabs[0] ? tabs[0].url : '';
      resolve(url || '');
    });
  });
}

function isSupported(url) {
  return /https?:\/\/(?:[^/]*\.)?(youtube\.com|youtu\.be|soundcloud\.com)\//i.test(url);
}

document.addEventListener('DOMContentLoaded', async () => {
  const currentUrl = await getActiveTabUrl();
  document.getElementById('currentUrl').textContent = currentUrl || 'No URL';

  document.getElementById('addCurrent').addEventListener('click', async () => {
    const url = await getActiveTabUrl();
    if (!url) return setStatus('No active tab URL', false);
    try {
      setStatus('Adding...');
      const res = await sendAdd(url);
      setStatus(res.ok ? 'Added!' : ('Failed: ' + (res.error || '')),
        !!res.ok);
    } catch (e) {
      setStatus('Error: ' + e, false);
    }
  });

  document.getElementById('addManual').addEventListener('click', async () => {
    const url = document.getElementById('manualUrl').value.trim();
    if (!url) return setStatus('Paste a URL first', false);
    try {
      setStatus('Adding...');
      const res = await sendAdd(url);
      setStatus(res.ok ? 'Added!' : ('Failed: ' + (res.error || '')),
        !!res.ok);
    } catch (e) {
      setStatus('Error: ' + e, false);
    }
  });

  document.getElementById('openOptions').addEventListener('click', () => {
    if (API.runtime.openOptionsPage) API.runtime.openOptionsPage();
  });
});

function sendAdd(url) {
  return new Promise((resolve) => {
    if (!isSupported(url)) {
      // Still allow, server will validate
      console.log('Non-YouTube/SoundCloud URL; sending anyway');
    }
    API.runtime.sendMessage({ type: 'addUrl', url }, (resp) => {
      resolve(resp || { ok: false, error: 'No response' });
    });
  });
}
