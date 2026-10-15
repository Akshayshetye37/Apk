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
        const current = String((typeof DB !== 'undefined' && DB.settings && DB.settings.googleDriveFolderId) || '');
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
    if (!input || typeof DB === 'undefined' || !DB.settings) return;
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
    if (typeof DB !== 'undefined' && DB.settings) { delete DB.settings.googleDriveFolderId; if (typeof window.save === 'function') save(); }
    const status = document.getElementById('aureliaDriveFolderIdStatus');
    if (status) status.textContent = 'Folder ID cleared. Cloud upload is not enabled.';
  };

  // Intercept the app's print-window pattern. On Android, render that printable
  // HTML into a real PDF and open it with the device's PDF handler instead of relying
  // on unsupported WebView pop-up windows.
  const originalWindowOpen = window.open.bind(window);
  window.open = function (url, target, features) {
    const blank = url == null || String(url) === '' || String(url) === 'about:blank';
    if (!blank || !window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') {
      return originalWindowOpen(url, target, features);
    }
    let source = '';
    let sent = false;
    const doc = {
      open: function () { source = ''; },
      write: function (chunk) { source += String(chunk || ''); },
      writeln: function (chunk) { source += String(chunk || '') + '\\n'; },
      close: function () {
        if (sent || !source) return;
        sent = true;
        if (source.length > 2 * 1024 * 1024) {
          if (typeof window.toast === 'function') toast('Document is too large to convert to PDF.');
          return;
        }
        let title = 'aurelia-document';
        try {
          const parsed = new DOMParser().parseFromString(source, 'text/html');
          title = (parsed.querySelector('title')?.textContent || parsed.querySelector('h1')?.textContent || title).trim();
        } catch (_) {}
        title = title.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80) || 'aurelia-document';
        const requestId = 'print_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
        let settled = false;
        const handler = function (event) {
          const detail = event.detail || {};
          if (detail.requestId !== requestId || settled) return;
          settled = true;
          window.removeEventListener('aurelia-native-file-result', handler);
          clearTimeout(timeout);
          if (!detail.ok && typeof window.toast === 'function') toast('PDF export failed: ' + String(detail.error || 'Unknown error'));
        };
        const timeout = setTimeout(function () {
          if (settled) return;
          settled = true;
          window.removeEventListener('aurelia-native-file-result', handler);
          if (typeof window.toast === 'function') toast('PDF export timed out. Try saving a smaller document.');
        }, 45000);
        window.addEventListener('aurelia-native-file-result', handler);
        try {
          window.AureliaNative.postMessage(JSON.stringify({
            type: 'exportHtmlPdf', requestId: requestId,
            name: title + '.pdf', html: source, action: 'open'
          }));
        } catch (error) {
          settled = true; clearTimeout(timeout);
          window.removeEventListener('aurelia-native-file-result', handler);
          if (typeof window.toast === 'function') toast('PDF export failed: ' + error.message);
        }
      }
    };
    return {document:doc, closed:false, focus:function(){}, print:function(){}, close:function(){}, stop:function(){}};
  };

  // Persist occupant ID images with the guest instead of running OCR without retaining
  // the source image. OCR is optional; upload/preview/save must work independently.
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || !input.matches || !input.matches('input[data-occ-camera],input[data-occ-photo]')) return;
    const file = input.files && input.files[0];
    const scope = input.closest('[data-occ]');
    if (!file || !scope) return;
    if (!/^image\\//i.test(file.type) || file.size > 8 * 1024 * 1024) {
      input.value = '';
      if (typeof window.toast === 'function') toast('Choose an image no larger than 8 MiB.');
      return;
    }
    const reader = new FileReader();
    reader.onerror = function () { if (typeof window.toast === 'function') toast('Could not read occupant ID image.'); };
    reader.onload = function () {
      scope.dataset.occupantIdPhoto = String(reader.result || '');
      let preview = scope.querySelector('[data-occ-photo-preview]');
      if (!preview) {
        preview = document.createElement('img');
        preview.setAttribute('data-occ-photo-preview', '');
        preview.alt = 'Occupant ID image preview';
        preview.style.cssText = 'display:block;max-width:180px;max-height:140px;object-fit:contain;margin-top:8px;border:1px solid var(--line);border-radius:8px;';
        const field = input.closest('.field');
        if (field) field.appendChild(preview);
      }
      preview.src = scope.dataset.occupantIdPhoto;
      const status = input.closest('.field')?.querySelector('.muted');
      if (status) status.textContent = 'ID image selected and ready to save with the guest record.';
    };
    reader.readAsDataURL(file);
  }, true);

  // The existing settings patch added a second input with id=upiQrFile. Remove that
  // duplicate markup so the visible QR picker maps to the correct handler and preview.
  try {
    if (typeof pages !== 'undefined' && pages && typeof pages.settings === 'function') {
      const previousSettings = pages.settings;
      pages.settings = function () {
        let html = previousSettings.apply(this, arguments);
        html = html.replace(/<div class="field full" style="margin-top:12px"><label for="upiQrFile">UPI payment QR image<\\/label><input id="upiQrFile" type="file" accept="image\\/\\*" onchange="saveUpiQrImage\\(event\\)">[\\s\\S]*?onclick="clearUpiQrImage\\(\\)">Remove QR<\\/button><\\/div><\\/div>/, '');
        return html;
      };
    }
  } catch (_) {}

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
