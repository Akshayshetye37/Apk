/* Native file preview/export bridge for Aurelia PMS Android WebView. */
(function () {
  'use strict';
  const MAX_BYTES = 15 * 1024 * 1024;
  const mimeByExt = {pdf:'application/pdf',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',csv:'text/csv',xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'};
  function ext(file) { return String(file.name || '').split('.').pop().toLowerCase(); }
  function nativeShare(file, mime) {
    return new Promise(function (resolve, reject) {
      if (!window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') {
        reject(new Error('Native file sharing is available in the installed Android app only.'));
        return;
      }
      if (file.size > MAX_BYTES) { reject(new Error('Files larger than 15 MB are not supported.')); return; }
      const reader = new FileReader();
      reader.onerror = function () { reject(new Error('Could not read file.')); };
      reader.onload = function () {
        const dataUrl = String(reader.result || '');
        const base64 = dataUrl.substring(dataUrl.indexOf(',') + 1);
        const requestId = 'file_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
        const handler = function (event) {
          const d = event.detail || {};
          if (d.requestId !== requestId) return;
          window.removeEventListener('aurelia-native-file-result', handler);
          d.ok ? resolve() : reject(new Error(d.error || 'Could not export file.'));
        };
        window.addEventListener('aurelia-native-file-result', handler);
        window.AureliaNative.postMessage(JSON.stringify({type:'shareFile', requestId:requestId, name:file.name || 'aurelia-export.' + ext({name:'file.csv'}), mime:mime || file.type || 'application/octet-stream', data:base64}));
        setTimeout(function () {
          window.removeEventListener('aurelia-native-file-result', handler);
          reject(new Error('No response from Android file handler.'));
        }, 30000);
      };
      reader.readAsDataURL(file);
    });
  }
  function showPreview(file) {
    const e = ext(file);
    if (!['pdf','png','jpg','jpeg'].includes(e)) return false;
    const url = URL.createObjectURL(file);
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#101827f5;display:flex;flex-direction:column;padding:12px;box-sizing:border-box;';
    const bar = document.createElement('div');
    bar.style.cssText = 'display:flex;align-items:center;gap:12px;color:white;padding:8px;font:16px sans-serif;';
    const name = document.createElement('span'); name.textContent = file.name; name.style.cssText = 'flex:1;overflow-wrap:anywhere;';
    const close = document.createElement('button'); close.textContent = 'Close'; close.style.cssText = 'padding:10px 16px;';
    close.onclick = function () { URL.revokeObjectURL(url); overlay.remove(); };
    bar.append(name, close);
    let view;
    if (e === 'pdf') {
      view = document.createElement('iframe'); view.src = url; view.title = file.name;
      view.style.cssText = 'border:0;background:white;flex:1;width:100%;min-height:0;';
    } else {
      view = document.createElement('img'); view.src = url; view.alt = file.name;
      view.style.cssText = 'object-fit:contain;width:100%;height:100%;min-height:0;';
      const wrap = document.createElement('div'); wrap.style.cssText = 'flex:1;min-height:0;display:flex;align-items:center;justify-content:center;overflow:auto;background:white;'; wrap.appendChild(view); view = wrap;
    }
    overlay.append(bar, view); document.body.appendChild(overlay); return true;
  }
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files.length) return;
    const file = input.files[0], e = ext(file);
    if (['pdf','png','jpg','jpeg'].includes(e) && input.hasAttribute('data-preview-file')) showPreview(file);
  }, true);
  // Provide reusable functions for app screens and future controls.
  window.aureliaPreviewFile = showPreview;
  window.aureliaShareExportFile = function (blob, name, mime) {
    const file = new File([blob], name || 'aurelia-export.csv', {type:mime || blob.type || 'application/octet-stream'});
    nativeShare(file, mime).catch(function (e) { alert('Export failed: ' + e.message); });
  };
  // Intercept generated download links: WebView does not reliably download blob URLs.
  document.addEventListener('click', function (event) {
    const a = event.target && event.target.closest && event.target.closest('a[download]');
    if (!a || !a.href || !a.href.startsWith('blob:')) return;
    event.preventDefault();
    fetch(a.href).then(function (r) { return r.blob(); }).then(function (blob) {
      window.aureliaShareExportFile(blob, a.download || 'aurelia-export', blob.type);
    }).catch(function (e) { alert('Export failed: ' + e.message); });
  }, true);
})();