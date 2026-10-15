/* Aurelia PMS interaction and upload reliability patch. */
(function () {
  'use strict';
  const MAX_BACKUP_BYTES = 20 * 1024 * 1024;
  const FORBIDDEN_KEYS = new Set(['__proto__', 'prototype', 'constructor']);
  function notify(message) {
    if (typeof window.toast === 'function') window.toast(message);
    else console.info('[AURELIA]', message);
  }
  function errorMessage(error) { return error && error.message ? error.message : String(error); }

  window.addEventListener('error', function (event) {
    if (event && event.message) console.error('[AURELIA interaction patch]', event.message);
  });
  document.addEventListener('click', function (event) {
    const trigger = event.target && event.target.closest('label[for], [data-file-input], button[data-upload-target], .upload-button');
    if (!trigger) return;
    const targetId = trigger.getAttribute('for') || trigger.getAttribute('data-file-input') || trigger.getAttribute('data-upload-target');
    if (!targetId) return;
    const input = document.getElementById(targetId);
    if (!input || input.type !== 'file' || input.disabled || event.target === input) return;
    event.preventDefault(); input.click();
  }, true);
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files.length) return;
    if (input.files[0].size > MAX_BACKUP_BYTES) {
      input.value = ''; notify('That file is larger than 20 MB. Choose a smaller image or document.');
    }
  }, true);

  function validateTree(value, depth, counter) {
    if (depth > 40) throw new Error('Backup data is nested too deeply.');
    if (++counter.nodes > 250000) throw new Error('Backup contains too many data items.');
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
    if (typeof value === 'number') {
      if (!Number.isFinite(value)) throw new Error('Backup contains an invalid number.');
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(function (item) { validateTree(item, depth + 1, counter); }); return;
    }
    if (typeof value !== 'object' || Object.getPrototypeOf(value) !== Object.prototype) throw new Error('Backup contains an unsupported data value.');
    Object.keys(value).forEach(function (key) {
      if (FORBIDDEN_KEYS.has(key)) throw new Error('Backup contains an unsafe property name.');
      validateTree(value[key], depth + 1, counter);
    });
  }
  function validateBackup(data) {
    if (!data || typeof data !== 'object' || Array.isArray(data) || Object.getPrototypeOf(data) !== Object.prototype) {
      throw new Error('Backup data must be a JSON object.');
    }
    const keys = Object.keys(data);
    if (!keys.length) throw new Error('Backup contains no PMS records.');
    keys.forEach(function (key) {
      if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(key) || FORBIDDEN_KEYS.has(key)) throw new Error('Backup contains an invalid data section name.');
    });
    ['guests', 'rooms'].forEach(function (key) {
      if (!Array.isArray(data[key])) throw new Error('Backup is missing the required "' + key + '" list.');
    });
    if (!Array.isArray(data.bookings) && !Array.isArray(data.reservations)) throw new Error('Backup must contain a bookings or reservations list.');
    ['guests','rooms','bookings','reservations','inventory','expenses','payments'].forEach(function (key) {
      if (Object.prototype.hasOwnProperty.call(data, key) && !Array.isArray(data[key])) throw new Error('The "' + key + '" section must be a list.');
    });
    validateTree(data, 0, {nodes:0});
    return JSON.parse(JSON.stringify(data));
  }

  // JSON backups are plaintext. Warn before generating a file that may contain PII.
  window.aureliaDownloadBackup = function () {
    try {
      if (!window.DB || typeof window.DB !== 'object' || Array.isArray(window.DB)) throw new Error('PMS data is not ready yet.');
      if (!window.confirm('WARNING: This backup is NOT encrypted and may contain guest and payment records. Anyone who gets the file may read them. Store it securely and never share it publicly. Continue?')) return;
      const serialized = JSON.stringify({app:'AURELIA PMS',formatVersion:1,exportedAt:new Date().toISOString(),data:window.DB}, null, 2);
      if (new Blob([serialized]).size > MAX_BACKUP_BYTES) throw new Error('Backup exceeds the 20 MB limit.');
      const url = URL.createObjectURL(new Blob([serialized], {type:'application/json;charset=utf-8'}));
      const a = document.createElement('a');
      a.href = url; a.download = 'aurelia-pms-backup-' + new Date().toISOString().slice(0,10) + '.json';
      a.style.display = 'none'; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
      notify('Plaintext PMS backup downloaded. Keep this file private and secure.');
    } catch (error) { notify('Backup failed: ' + errorMessage(error)); }
  };

  window.aureliaImportBackupFile = function (file) {
    if (!file) return;
    if (file.size > MAX_BACKUP_BYTES) { notify('Import failed: backup exceeds the 20 MB limit.'); return; }
    const reader = new FileReader();
    reader.onerror = function () { notify('Could not read backup file.'); };
    reader.onload = async function () {
      try {
        const parsed = JSON.parse(String(reader.result || ''));
        if (parsed && parsed.app && parsed.app !== 'AURELIA PMS') throw new Error('This backup belongs to a different application.');
        if (parsed && parsed.formatVersion !== undefined && parsed.formatVersion !== 1) throw new Error('Unsupported backup format version.');
        const candidate = validateBackup(parsed && parsed.data ? parsed.data : parsed);
        if (!window.DB || typeof window.DB !== 'object' || Array.isArray(window.DB) || typeof window.save !== 'function') {
          throw new Error('PMS storage is not ready; current data was not changed.');
        }
        if (!window.confirm('Restore this backup? Current local PMS data will be replaced. Only restore a backup you trust.')) return;
        const previous = JSON.parse(JSON.stringify(window.DB));
        try {
          Object.keys(window.DB).forEach(function (key) { delete window.DB[key]; });
          Object.keys(candidate).forEach(function (key) {
            Object.defineProperty(window.DB, key, {value:candidate[key],enumerable:true,configurable:true,writable:true});
          });
          await Promise.resolve(window.save());
        } catch (saveError) {
          Object.keys(window.DB).forEach(function (key) { delete window.DB[key]; });
          Object.keys(previous).forEach(function (key) {
            Object.defineProperty(window.DB, key, {value:previous[key],enumerable:true,configurable:true,writable:true});
          });
          try { await Promise.resolve(window.save()); } catch (_) {}
          throw new Error('Could not save restored data; previous in-memory data was restored. ' + errorMessage(saveError));
        }
        notify('Backup imported and saved. Refreshing PMS view…');
        setTimeout(function () { window.location.reload(); }, 250);
      } catch (error) { notify('Import failed: ' + errorMessage(error)); }
    };
    reader.readAsText(file);
  };

  window.aureliaCheckDeviceAuthenticationSupport = function () {
    const note = document.getElementById('aureliaSecurityNote');
    const supported = !!(window.PublicKeyCredential && navigator.credentials && window.isSecureContext);
    if (!supported && note) note.textContent = 'Device authentication is unavailable in this preview. WebAuthn requires HTTPS or localhost; Android app biometric login must be connected through the native Android authentication bridge.';
    return supported;
  };
  document.addEventListener('DOMContentLoaded', window.aureliaCheckDeviceAuthenticationSupport);
})();
