/* Aurelia PMS interaction and upload reliability patch.
   Runs after the legacy inline scripts, so it can restore missing file-picker wiring
   without replacing existing PMS record handlers. */
(function () {
  'use strict';

  function notify(message) {
    if (typeof window.toast === 'function') window.toast(message);
    else console.info('[AURELIA]', message);
  }

  // A broken inline handler should not make every later action silently fail.
  window.addEventListener('error', function (event) {
    if (event && event.message) console.error('[AURELIA interaction patch]', event.message);
  });

  // Normalize file-picker labels: clicking a visible upload label/button opens its
  // associated file input even when legacy markup lost the label's for attribute.
  document.addEventListener('click', function (event) {
    const trigger = event.target && event.target.closest(
      'label[for], [data-file-input], button[data-upload-target], .upload-button'
    );
    if (!trigger) return;
    const targetId = trigger.getAttribute('for') ||
      trigger.getAttribute('data-file-input') ||
      trigger.getAttribute('data-upload-target');
    if (!targetId) return;
    const input = document.getElementById(targetId);
    if (!input || input.type !== 'file' || input.disabled) return;
    if (event.target === input) return;
    event.preventDefault();
    input.click();
  }, true);

  // Keep file inputs operable on mobile WebViews and expose useful errors.
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files.length) return;
    const file = input.files[0];
    if (file.size > 20 * 1024 * 1024) {
      input.value = '';
      notify('That file is larger than 20 MB. Choose a smaller image or document.');
    }
  }, true);

  // Reliable local JSON export/import fallback independent of optional cloud APIs.
  window.aureliaDownloadBackup = window.aureliaDownloadBackup || function () {
    try {
      if (!window.DB) throw new Error('PMS data is not ready yet.');
      const payload = {
        app: 'AURELIA PMS',
        formatVersion: 1,
        exportedAt: new Date().toISOString(),
        data: window.DB
      };
      const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'aurelia-pms-backup-' + new Date().toISOString().slice(0, 10) + '.json';
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
      notify('Full PMS JSON backup downloaded.');
    } catch (error) {
      notify('Backup failed: ' + (error && error.message ? error.message : String(error)));
    }
  };

  window.aureliaImportBackupFile = window.aureliaImportBackupFile || function (file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onerror = function () { notify('Could not read backup file.'); };
    reader.onload = function () {
      try {
        const parsed = JSON.parse(String(reader.result || ''));
        const data = parsed && parsed.data ? parsed.data : parsed;
        const required = ['guests', 'rooms', 'bookings', 'reservations', 'inventory', 'expenses'];
        if (!data || typeof data !== 'object' || !required.some(function (key) { return Array.isArray(data[key]); })) {
          throw new Error('This file does not look like an Aurelia PMS backup.');
        }
        if (!window.confirm('Restore this backup? Current local PMS data will be replaced. Download a backup first if needed.')) return;
        Object.keys(data).forEach(function (key) { window.DB[key] = data[key]; });
        if (typeof window.save === 'function') window.save();
        notify('Backup imported. Refreshing PMS view…');
        setTimeout(function () { window.location.reload(); }, 250);
      } catch (error) {
        notify('Import failed: ' + (error && error.message ? error.message : String(error)));
      }
    };
    reader.readAsText(file);
  };

  // HTML-only WebAuthn cannot run in file:// Android WebView. State the actual
  // platform requirement rather than repeatedly presenting it as a broken button.
  window.aureliaCheckDeviceAuthenticationSupport = function () {
    const note = document.getElementById('aureliaSecurityNote');
    const supported = !!(window.PublicKeyCredential && navigator.credentials && window.isSecureContext);
    if (!supported && note) {
      note.textContent = 'Device authentication is unavailable in this preview. WebAuthn requires HTTPS or localhost and a supported browser; Android app biometric login must be connected through the native Android authentication bridge.';
    }
    return supported;
  };

  document.addEventListener('DOMContentLoaded', function () {
    window.aureliaCheckDeviceAuthenticationSupport();
  });
})();
