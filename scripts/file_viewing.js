/* Native document open/save bridge and backup target settings for Aurelia PMS. */
(function () {
  'use strict';
  const MAX_BYTES = 15 * 1024 * 1024;
  const mimeByExt = {
    pdf:'application/pdf',png:'image/png',jpg:'image/jpeg',jpeg:'image/jpeg',webp:'image/webp',
    gif:'image/gif',bmp:'image/bmp',csv:'text/csv',json:'application/json',txt:'text/plain',
    xml:'application/xml',html:'text/html',htm:'text/html',xls:'application/vnd.ms-excel',
    xlsx:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    doc:'application/msword',docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ppt:'application/vnd.ms-powerpoint',pptx:'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    zip:'application/zip',rtf:'application/rtf',odt:'application/vnd.oasis.opendocument.text',
    ods:'application/vnd.oasis.opendocument.spreadsheet',odp:'application/vnd.oasis.opendocument.presentation'
  };
  function extension(name) {
    const n = String(name || '').split(/[\\/]/).pop();
    return n.includes('.') ? n.split('.').pop().toLowerCase() : '';
  }
  function safeName(name) {
    const n = String(name || 'aurelia-export.bin').split(/[\\/]/).pop()
      .replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 120);
    if (!n || n === '.' || n === '..' || n.startsWith('.')) throw new Error('Invalid file name.');
    return n;
  }
  function nativeTransfer(file, action, explicitMime) {
    return new Promise(function (resolve, reject) {
      if (!window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') {
        reject(new Error('This operation requires the installed Android app.'));
        return;
      }
      if (!file || !Number.isFinite(file.size) || file.size < 1 || file.size > MAX_BYTES) {
        reject(new Error('Choose a non-empty file no larger than 15 MiB.'));
        return;
      }
      let name;
      try { name = safeName(file.name); } catch (error) { reject(error); return; }
      const reader = new FileReader();
      reader.onerror = function () { reject(new Error('Could not read the selected document.')); };
      reader.onload = function () {
        const dataUrl = String(reader.result || '');
        const comma = dataUrl.indexOf(',');
        if (comma < 0) { reject(new Error('Could not encode the document.')); return; }
        const data = dataUrl.slice(comma + 1);
        // Base64 is bounded before the native side decodes it.
        if (!data || data.length > Math.ceil(MAX_BYTES / 3) * 4) {
          reject(new Error('Encoded document exceeds the size limit.')); return;
        }
        const requestId = 'doc_' + Date.now() + '_' + Math.random().toString(36).slice(2, 9);
        let settled = false;
        const cleanup = function () {
          window.removeEventListener('aurelia-native-file-result', handler);
          clearTimeout(timeout);
        };
        const handler = function (event) {
          const d = event.detail || {};
          if (d.requestId !== requestId || settled) return;
          settled = true; cleanup();
          d.ok ? resolve() : reject(new Error(d.error || 'Android could not complete the file operation.'));
        };
        const timeout = setTimeout(function () {
          if (settled) return;
          settled = true; cleanup();
          reject(new Error('Android did not respond to the file request.'));
        }, 45000);
        window.addEventListener('aurelia-native-file-result', handler);
        try {
          window.AureliaNative.postMessage(JSON.stringify({
            type: action, requestId: requestId, name: name,
            mime: explicitMime || mimeByExt[extension(name)] || file.type || 'application/octet-stream',
            data: data
          }));
        } catch (error) { settled = true; cleanup(); reject(error); }
      };
      reader.readAsDataURL(file);
    });
  }
  function showPreview(file) {
    const ext = extension(file.name);
    if (!['pdf','png','jpg','jpeg','webp','gif','bmp'].includes(ext)) return false;
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
    if (ext === 'pdf') {
      view = document.createElement('iframe'); view.src = url; view.title = file.name;
      view.style.cssText = 'border:0;background:white;flex:1;width:100%;min-height:0;';
    } else {
      view = document.createElement('img'); view.src = url; view.alt = file.name;
      view.style.cssText = 'object-fit:contain;max-width:100%;max-height:100%;';
      const wrap = document.createElement('div');
      wrap.style.cssText = 'flex:1;min-height:0;display:flex;align-items:center;justify-content:center;overflow:auto;background:white;';
      wrap.appendChild(view); view = wrap;
    }
    overlay.append(bar, view); document.body.appendChild(overlay); return true;
  }
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files.length) return;
    const file = input.files[0];
    if (file.size > MAX_BYTES) {
      input.value = '';
      if (typeof window.toast === 'function') window.toast('File exceeds the 15 MiB limit.');
    }
    if (input.hasAttribute('data-preview-file') && ['pdf','png','jpg','jpeg','webp','gif','bmp'].includes(extension(file.name))) showPreview(file);
  }, true);

  // Route the PMS's existing Blob downloads through Android's Storage Access Framework.
  // This avoids WebView blob-download behavior that silently does nothing on Android.
  const originalDownloadBlob = typeof window.downloadBlob === 'function' ? window.downloadBlob : null;
  window.aureliaSaveBlob = function (blob, name, mime) {
    const file = new File([blob], safeName(name || 'aurelia-export.bin'), {type:mime || blob.type || 'application/octet-stream'});
    return nativeTransfer(file, 'saveFile', mime);
  };
  window.aureliaOpenExternalFile = function (blob, name, mime) {
    const file = new File([blob], safeName(name || 'aurelia-document.bin'), {type:mime || blob.type || 'application/octet-stream'});
    return nativeTransfer(file, 'openFile', mime);
  };
  window.downloadBlob = function (blob, name) {
    if (window.AureliaNative && typeof window.AureliaNative.postMessage === 'function') {
      window.aureliaSaveBlob(blob, name || 'aurelia-export.bin', blob && blob.type)
        .then(function () { if (typeof window.toast === 'function') window.toast('Choose a location to save the export.'); })
        .catch(function (error) { if (typeof window.toast === 'function') window.toast('Export failed: ' + error.message); else alert('Export failed: ' + error.message); });
      return;
    }
    if (originalDownloadBlob) return originalDownloadBlob(blob, name);
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name || 'aurelia-export.bin';
    document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 800);
  };

  // Keep the Google Drive folder ID in the PMS backup/export area, but do not claim
  // cloud backup works until OAuth and encrypted upload/restore are implemented.
  try {
    if (typeof pages !== 'undefined' && pages && typeof pages.importExport === 'function') {
      const originalImportExport = pages.importExport;
      pages.importExport = function () {
        let html = originalImportExport.apply(this, arguments);
        if (html.includes('aureliaDriveFolderIdCard')) return html;
        const current = String((window.DB && DB.settings && DB.settings.googleDriveFolderId) || '');
        const escaped = typeof window.esc === 'function' ? esc(current) : current.replace(/[&<>"]/g, '');
        html += '<section class="card" id="aureliaDriveFolderIdCard" style="margin-top:16px">' +
          '<div class="section-title"><h2>Google Drive backup target</h2><span class="status reserved">Not connected</span></div>' +
          '<p class="muted">Enter the destination folder ID from Google Drive. This ID is saved locally; uploads and restores remain disabled until secure Google authorization and encrypted backup sync are implemented.</p>' +
          '<div class="field"><label for="aureliaDriveFolderId">Google Drive folder ID</label>' +
          '<input id="aureliaDriveFolderId" type="text" maxlength="200" autocomplete="off" value="' + escaped + '" placeholder="Paste Drive folder ID">' +
          '</div><div class="actions" style="margin-top:10px"><button class="btn" type="button" onclick="aureliaSaveDriveFolderId()">Save folder ID</button>' +
          '<button class="btn" type="button" onclick="aureliaClearDriveFolderId()">Clear</button></div>' +
          '<div id="aureliaDriveFolderIdStatus" class="muted" role="status" style="margin-top:8px">Folder ID is a destination setting, not proof of a backup.</div></section>';
        return html;
      };
    }
  } catch (error) { console.warn('Could not add Drive target field:', error); }
  window.aureliaSaveDriveFolderId = function () {
    const input = document.getElementById('aureliaDriveFolderId');
    if (!input || !window.DB || !DB.settings) return;
    const id = input.value.trim();
    if (id.length > 200 || /[\\/\s]/.test(id)) {
      const status = document.getElementById('aureliaDriveFolderIdStatus');
      if (status) status.textContent = 'Enter only the folder ID from the Drive URL, without spaces or slashes.';
      return;
    }
    DB.settings.googleDriveFolderId = id;
    if (typeof window.save === 'function') save();
    const status = document.getElementById('aureliaDriveFolderIdStatus');
    if (status) status.textContent = id ? 'Folder ID saved on this device. Cloud upload is not enabled.' : 'Folder ID cleared.';
    if (typeof window.toast === 'function') toast('Drive folder ID saved locally. Cloud backup is not connected.');
  };
  window.aureliaClearDriveFolderId = function () {
    const input = document.getElementById('aureliaDriveFolderId');
    if (input) input.value = '';
    if (window.DB && DB.settings) { delete DB.settings.googleDriveFolderId; if (typeof window.save === 'function') save(); }
    const status = document.getElementById('aureliaDriveFolderIdStatus');
    if (status) status.textContent = 'Folder ID cleared. Cloud upload is not enabled.';
  };

  window.aureliaNativeFileResult = function (requestId, ok, error) {
    window.dispatchEvent(new CustomEvent('aurelia-native-file-result', {detail:{requestId:requestId, ok:!!ok, error:error || null}}));
  };
  // A selected local document can be explicitly opened by screens that opt into this hook.
  window.aureliaOpenFileInExternalApp = function (file) {
    const ext = extension(file && file.name);
    if (!mimeByExt[ext]) return Promise.reject(new Error('This file extension is not supported for external opening.'));
    return nativeTransfer(file, 'openFile', mimeByExt[ext]);
  };
})();
