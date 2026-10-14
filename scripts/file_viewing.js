/* Native file preview/export bridge for Aurelia PMS Android WebView. */
(function () {
  'use strict';
  const MAX_BYTES = 15 * 1024 * 1024;
  const mimeByExt = {pdf:'application/pdf',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',csv:'text/csv',xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'};
  function ext(file) { return String(file.name || '').split('.').pop().toLowerCase(); }
  function nativeShare(file, mime, action) {
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
        window.AureliaNative.postMessage(JSON.stringify({type:action === 'saveFile' ? 'saveFile' : 'shareFile', requestId:requestId, name:file.name || 'aurelia-export.csv', mime:mime || file.type || 'application/octet-stream', data:base64}));
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
    const save = document.createElement('button');
    save.textContent = 'Save / share';
    save.style.cssText = 'padding:10px 12px;';
    save.onclick = function () {
      nativeShare(file, mimeByExt[e] || file.type || 'application/octet-stream', 'saveFile')
        .catch(function (error) { alert('Could not save file: ' + error.message); });
    };
    bar.append(name, save);
    if (e === 'pdf') {
      const open = document.createElement('button');
      open.textContent = 'Open PDF';
      open.style.cssText = 'padding:10px 12px;';
      open.onclick = function () {
        nativeShare(file, 'application/pdf', 'shareFile')
          .catch(function (error) { alert('Could not open PDF: ' + error.message); });
      };
      bar.appendChild(open);
    }
    const close = document.createElement('button'); close.textContent = 'Close'; close.style.cssText = 'padding:10px 16px;';
    close.onclick = function () { URL.revokeObjectURL(url); overlay.remove(); };
    bar.append(close);
    let view;
    if (e === 'pdf') {
      view = document.createElement('div');
      view.style.cssText = 'background:white;flex:1;width:100%;min-height:0;display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;box-sizing:border-box;color:#172f27;font:16px sans-serif;';
      view.textContent = 'PDF preview depends on Android WebView support. Tap Open PDF to use a PDF app, or Save / share to export it.';
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
  // Add an always-available file viewer in the Android wrapper. CSV/XLSX are handed to
  // Android's chooser so the user can select a compatible spreadsheet app.
  function installOpenFileControl() {
    if (document.getElementById('aurelia-open-file-control')) return;
    const button = document.createElement('button');
    button.id = 'aurelia-open-file-control';
    button.type = 'button';
    button.textContent = 'Open file';
    button.setAttribute('aria-label', 'Open PDF, image, CSV, or Excel file');
    button.style.cssText = 'position:fixed;right:12px;bottom:16px;z-index:2147483000;border:0;border-radius:24px;padding:12px 18px;background:#17365d;color:white;font:600 14px sans-serif;box-shadow:0 2px 10px #0004;';
    const picker = document.createElement('input');
    picker.type = 'file';
    picker.accept = '.pdf,.png,.jpg,.jpeg,.csv,.xlsx,application/pdf,image/png,image/jpeg,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    picker.style.display = 'none';
    picker.addEventListener('change', function () {
      const file = picker.files && picker.files[0];
      if (!file) return;
      const e = ext(file);
      if (['pdf','png','jpg','jpeg'].includes(e)) {
        if (!showPreview(file)) alert('This file type cannot be previewed.');
      } else if (['csv','xlsx'].includes(e)) {
        nativeShare(file, mimeByExt[e]).then(function () {
          // Android share chooser was opened; user selects a compatible external app.
        }).catch(function (error) { alert('Could not open file: ' + error.message); });
      } else alert('Choose a PDF, PNG, JPG, CSV, or XLSX file.');
      picker.value = '';
    });
    button.addEventListener('click', function () { picker.click(); });
    const backupInput = document.createElement('input');
    backupInput.type = 'file'; backupInput.accept = '.json,application/json'; backupInput.style.display = 'none';
    backupInput.addEventListener('change', function () {
      const file = backupInput.files && backupInput.files[0];
      if (file && typeof window.aureliaImportBackupFile === 'function') window.aureliaImportBackupFile(file);
      backupInput.value = '';
    });
    const importButton = document.createElement('button');
    importButton.type = 'button'; importButton.textContent = 'Import backup';
    importButton.style.cssText = button.style.cssText + 'bottom:68px;background:#345b45;';
    importButton.onclick = function () { backupInput.click(); };
    const exportButton = document.createElement('button');
    exportButton.type = 'button'; exportButton.textContent = 'Export backup';
    exportButton.style.cssText = button.style.cssText + 'bottom:120px;background:#6b4b21;';
    exportButton.onclick = function () {
      if (typeof window.aureliaDownloadBackup === 'function') window.aureliaDownloadBackup();
      else alert('Backup export is not available on this screen.');
    };
    document.body.append(button, picker, importButton, exportButton, backupInput);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', installOpenFileControl);
  else installOpenFileControl();
  window.addEventListener('aurelia-native-file-result', function () {});
  window.aureliaNativeFileResult = function (requestId, ok, error) {
    window.dispatchEvent(new CustomEvent('aurelia-native-file-result', {detail:{requestId:requestId, ok:!!ok, error:error || null}}));
  };

  // Provide reusable functions for app screens and future controls.
  window.aureliaPreviewFile = showPreview;
  window.aureliaShareExportFile = function (blob, name, mime) {
    const file = new File([blob], name || 'aurelia-export.csv', {type:mime || blob.type || 'application/octet-stream'});
    nativeShare(file, mime, 'shareFile').catch(function (e) { alert('Export failed: ' + e.message); });
  };
  window.aureliaSaveExportFile = function (blob, name, mime) {
    const file = new File([blob], name || 'aurelia-export.csv', {type:mime || blob.type || 'application/octet-stream'});
    nativeShare(file, mime, 'saveFile').catch(function (e) {
      if (e.message !== 'Save cancelled') alert('Save failed: ' + e.message);
    });
  };
  // Intercept generated download links: WebView does not reliably download blob URLs.
  document.addEventListener('click', function (event) {
    const a = event.target && event.target.closest && event.target.closest('a[download]');
    if (!a || !a.href || !a.href.startsWith('blob:')) return;
    event.preventDefault();
    fetch(a.href).then(function (r) { return r.blob(); }).then(function (blob) {
      window.aureliaSaveExportFile(blob, a.download || 'aurelia-export.csv', blob.type);
    }).catch(function (e) { alert('Export failed: ' + e.message); });
  }, true);
})();