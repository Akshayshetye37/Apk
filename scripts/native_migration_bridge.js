(function () {
  'use strict';
  const MAX_PAYLOAD_CHARS = 20 * 1024 * 1024;
  function getModel() {
    try {
      if (typeof DB !== 'undefined' && DB && typeof DB === 'object') {
        if (!window.DB) window.DB = DB;
        return DB;
      }
    } catch (_) {}
    if (window.DB && typeof window.DB === 'object') return window.DB;
    throw new Error('PMS data model is not available');
  }
  window.aureliaBuildMigrationPayload = function () {
    const model = getModel();
    const payload = {
      app: 'Aurelia PMS',
      migrationProtocol: 1,
      exportedAt: new Date().toISOString(),
      storageKeys: Object.keys(localStorage),
      counts: {},
      data: model
    };
    Object.keys(model).forEach(function (key) {
      if (Array.isArray(model[key])) payload.counts[key] = model[key].length;
    });
    const serialized = JSON.stringify(payload);
    if (serialized.length > MAX_PAYLOAD_CHARS) {
      throw new Error('PMS migration payload exceeds the 20 MiB safety limit');
    }
    return payload;
  };
  window.aureliaSendMigrationPayload = function () {
    try {
      if (!window.MigrationChannel || typeof window.MigrationChannel.postMessage !== 'function') {
        return { sent: false, reason: 'Native migration channel is unavailable' };
      }
      const payload = window.aureliaBuildMigrationPayload();
      window.MigrationChannel.postMessage(JSON.stringify(payload));
      return { sent: true };
    } catch (error) {
      console.error('Aurelia native migration payload was not sent:', error);
      return { sent: false, reason: String(error && error.message || error) };
    }
  };
  window.aureliaMigrationResult = function (result) {
    if (result && result.verified === true) {
      window.dispatchEvent(new CustomEvent('aurelia:migration-verified', { detail: result }));
      console.info('Aurelia encrypted native snapshot verified. Browser data retained.');
      return true;
    }
    console.error('Aurelia native migration failed. Browser data retained.', result || {});
    window.dispatchEvent(new CustomEvent('aurelia:migration-failed', { detail: result || {} }));
    return false;
  };
})();