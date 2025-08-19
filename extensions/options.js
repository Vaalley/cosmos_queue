const API = typeof chrome !== 'undefined' ? chrome : browser;

const DEFAULTS = {
  serverBase: 'http://localhost:5283',
  deviceName: 'Browser',
};

function setStatus(text, ok = true) {
  const el = document.getElementById('status');
  el.textContent = text || '';
  el.style.color = ok ? '#a7f3d0' : '#fecaca';
}

document.addEventListener('DOMContentLoaded', () => {
  API.storage.sync.get(DEFAULTS, (items) => {
    const cfg = items || DEFAULTS;
    document.getElementById('serverBase').value = cfg.serverBase || DEFAULTS.serverBase;
    document.getElementById('deviceName').value = cfg.deviceName || DEFAULTS.deviceName;
  });

  document.getElementById('save').addEventListener('click', () => {
    const serverBase = document.getElementById('serverBase').value.trim();
    const deviceName = document.getElementById('deviceName').value.trim() || DEFAULTS.deviceName;
    if (!/^https?:\/\//i.test(serverBase)) {
      return setStatus('Server must start with http:// or https://', false);
    }
    API.storage.sync.set({ serverBase, deviceName }, () => {
      setStatus('Saved!', true);
    });
  });

  document.getElementById('test').addEventListener('click', async () => {
    const serverBase = document.getElementById('serverBase').value.trim() || DEFAULTS.serverBase;
    try {
      setStatus('Testing...');
      const resp = await fetch(new URL('/health', serverBase).toString(), { method: 'GET' });
      if (resp.ok) {
        const text = await resp.text();
        setStatus('Health OK: ' + (text || 'OK'));
      } else {
        setStatus('Health failed: HTTP ' + resp.status, false);
      }
    } catch (e) {
      setStatus('Health error: ' + e, false);
    }
  });
});
