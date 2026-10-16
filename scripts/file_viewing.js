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

  // Remove only the legacy fixed-position bottom-right action cluster.
  function removeLegacyFloatingActions() {
    const labels = ['export', 'import', 'open file'];
    document.querySelectorAll('button, a, [role="button"]').forEach(function (el) {
      const label = String(el.innerText || el.getAttribute('aria-label') || el.title || '')
        .replace(/\\s+/g, ' ').trim().toLowerCase();
      if (labels.indexOf(label) < 0) return;
      let node = el, floating = false;
      for (let depth = 0; node && depth < 4; depth++, node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.position === 'fixed' && style.bottom !== 'auto' && style.right !== 'auto') {
          floating = true; break;
        }
      }
      if (floating) {
        const parent = el.parentElement;
        el.remove();
        if (parent && parent.children.length === 0) parent.remove();
      }
    });
  }
  removeLegacyFloatingActions();
  if (document.documentElement) {
    new MutationObserver(removeLegacyFloatingActions).observe(document.documentElement, {childList:true, subtree:true});
  }

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
          '<div class="section-title"><h2>Backup and Google Drive</h2><span class="status reserved">Drive not connected</span></div>' +
          '<p class="muted">Save a Drive folder ID below. Real cloud uploads require Google OAuth setup. Until connected, automatic backups are encrypted on this device.</p>' +
          '<div class="field"><label for="aureliaDriveFolderId">Google Drive folder ID</label>' +
          '<input id="aureliaDriveFolderId" type="text" maxlength="200" autocomplete="off" value="' + escaped + '" placeholder="Paste Drive folder ID"></div>' +
          '<div class="actions" style="margin-top:10px"><button class="btn" type="button" onclick="aureliaSaveDriveFolderId()">Save folder ID</button>' +
          '<button class="btn" type="button" onclick="aureliaClearDriveFolderId()">Clear</button></div>' +
          '<hr style="margin:14px 0;border-color:var(--line)"><h3>Backup</h3>' +
          '<p class="muted">Backup now creates a portable encrypted backup. Backup Auto keeps up to 15 encrypted snapshots in app-private storage after saved changes.</p>' +
          '<label style="display:flex;gap:10px;align-items:center;margin:10px 0"><input id="aureliaAutoBackupToggle" type="checkbox" ' +
          ((typeof DB !== 'undefined' && DB.settings && DB.settings.autoBackupEnabled === true) ? 'checked' : '') +
          ' onchange="aureliaSetAutoBackup(this.checked)"> Backup Auto</label>' +
          '<div class="actions"><button class="btn primary" type="button" onclick="aureliaBackupNow()">Backup now</button>' +
          '<button class="btn" type="button" onclick="aureliaCreateLocalSnapshot()">Save device snapshot</button></div>' +
          '<div id="aureliaBackupStatus" class="muted" role="status" style="margin-top:8px"></div>' +
          '<div id="aureliaDriveFolderIdStatus" class="muted" role="status" style="margin-top:8px">Folder ID is a destination setting, not proof of a backup.</div></section>';
        return html;
      };
    }
  } catch (error) { console.warn('Could not add Drive target field:', error); }
  window.aureliaSetAppProtection = function (enabled) {
    if (typeof DB !== 'undefined' && DB.settings) {
      DB.settings.appProtectionEnabled = !!enabled;
      if (typeof window.save === 'function') window.save();
    }
    const status = document.getElementById('aureliaProtectionStatus');
    if (!window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') {
      if (status) status.textContent = 'This setting is applied only in the installed Android app.';
      return;
    }
    window.AureliaNative.postMessage(JSON.stringify({
      type:'setAppProtection', requestId:'protection_' + Date.now(), enabled:!!enabled
    }));
    if (status) status.textContent = enabled ? 'Protection enabled. PIN setup may be required on next unlock.' : 'Protection disabled. The app will open without an unlock prompt.';
  };
  window.aureliaNativeProtectionResult = function (requestId, ok, error) {
    const status = document.getElementById('aureliaProtectionStatus');
    if (status) status.textContent = ok ? 'Security preference saved.' : 'Could not save security preference: ' + String(error || 'Unknown error');
  };
  window.aureliaSetAutoBackup = function (enabled) {
    if (typeof DB === 'undefined' || !DB.settings) return;
    DB.settings.autoBackupEnabled = !!enabled;
    if (typeof window.save === 'function') window.save();
    const status = document.getElementById('aureliaBackupStatus');
    if (status) status.textContent = enabled ? 'Encrypted device snapshots enabled after saved changes.' : 'Automatic snapshots disabled; existing backups are retained.';
  };
  window.aureliaNativeLocalBackupResult = function (requestId, ok, error) {
    const status = document.getElementById('aureliaBackupStatus');
    if (status) status.textContent = ok ? 'Encrypted device snapshot saved.' : 'Backup failed: ' + String(error || 'Unknown error');
  };
  window.aureliaCreateLocalSnapshot = function () {
    if (!window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') { notifyBackup('Install the Android app to create device snapshots.'); return; }
    window.AureliaNative.postMessage(JSON.stringify({type:'createLocalBackup',requestId:'local_backup_' + Date.now()}));
    notifyBackup('Saving encrypted device snapshot…');
  };
  function notifyBackup(message) { if (typeof window.toast === 'function') window.toast(message); }
  window.aureliaBackupNow = function () {
    if (typeof window.aureliaDownloadBackup === 'function') window.aureliaDownloadBackup();
    else notifyBackup('Backup service is not ready.');
  };
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

  // The PMS model previously discarded occupant ID images when saving a guest or booking.
  // Carry the selected data URL into the saved occupant record, preserving prior images.
  try {
    if (typeof window.saveGuest === 'function') {
      const originalSaveGuest = window.saveGuest;
      window.saveGuest = function (id) {
        const container = document.getElementById('guestOccList');
        const rows = container ? Array.from(container.querySelectorAll('[data-occ]')) : [];
        const photos = rows.map(row => row.dataset.occupantIdPhoto || '');
        const primaryInput = Array.from(document.querySelectorAll('input[type="file"]')).find(input =>
          /(id|identity|passport|license|licence|aadhaar|aadhar)/i.test(input.id + ' ' + input.name + ' ' +
            (input.closest('.field')?.innerText || '')));
        const primaryPhoto = primaryInput?.dataset.aureliaImageData || '';
        const name = document.getElementById('gName')?.value?.trim() || '';
        const phone = document.getElementById('gPhone')?.value?.trim() || '';
        const existing = id && typeof DB !== 'undefined' ? DB.guests.find(g => g.id === id) : null;
        const prior = (existing && existing.occupants || []).map(o => o.idPhoto || '');
        const wasOpen = !!container;
        const result = originalSaveGuest.apply(this, arguments);
        if (wasOpen && !document.getElementById('guestOccList') && typeof DB !== 'undefined') {
          const guest = id ? DB.guests.find(g => g.id === id) : [...DB.guests].reverse().find(g => g.name === name && g.phone === phone);
          if (guest) {
            if (primaryPhoto) guest.idPhoto = primaryPhoto;
            if (Array.isArray(guest.occupants)) {
              guest.occupants = guest.occupants.map((o, i) => ({...o, idPhoto: photos[i] || prior[i] || o.idPhoto || ''}));
            }
            if (typeof window.save === 'function') save();
          }
        }
        return result;
      };
    }
    if (typeof window.saveBookingForm === 'function') {
      const originalSaveBookingForm = window.saveBookingForm;
      window.saveBookingForm = function (id) {
        const container = document.getElementById('occList');
        const rows = container ? Array.from(container.querySelectorAll('[data-occ]')) : [];
        const photos = rows.map(row => row.dataset.occupantIdPhoto || '');
        const primaryInput = Array.from(document.querySelectorAll('input[type="file"]')).find(input =>
          /(id|identity|passport|license|licence|aadhaar|aadhar)/i.test(input.id + ' ' + input.name + ' ' +
            (input.closest('.field')?.innerText || '')));
        const primaryPhoto = primaryInput?.dataset.aureliaImageData || '';
        const name = document.getElementById('bkGuest')?.value?.trim() || 'Guest';
        const phone = document.getElementById('bkPhone')?.value?.trim() || '';
        const existing = typeof DB !== 'undefined' ? DB.guests.find(g => g.name.toLowerCase() === name.toLowerCase() && g.phone === phone) : null;
        const prior = (existing && existing.occupants || []).map(o => o.idPhoto || '');
        const wasOpen = !!container;
        const result = originalSaveBookingForm.apply(this, arguments);
        if (wasOpen && !document.getElementById('occList') && typeof DB !== 'undefined') {
          const guest = [...DB.guests].reverse().find(g => g.name.toLowerCase() === name.toLowerCase() && g.phone === phone);
          if (guest) {
            if (primaryPhoto) guest.idPhoto = primaryPhoto;
            if (Array.isArray(guest.occupants)) {
              guest.occupants = guest.occupants.map((o, i) => ({...o, idPhoto: photos[i] || prior[i] || o.idPhoto || ''}));
            }
            if (typeof window.save === 'function') save();
          }
        }
        return result;
      };
    }
  } catch (error) { console.warn('Could not install occupant image persistence:', error); }

  // The existing settings patch added a second input with id=upiQrFile. Remove that
  // duplicate markup so the visible QR picker maps to the correct handler and preview.
  try {
    if (typeof pages !== 'undefined' && pages && typeof pages.settings === 'function') {
      const previousSettings = pages.settings;
      pages.settings = function () {
        let html = previousSettings.apply(this, arguments);
        html = html.replace(/<div class="field full" style="margin-top:12px"><label for="upiQrFile">UPI payment QR image[\s\S]*?Remove QR<\/button><\/div><\/div>/, '');
        if (!html.includes('aureliaProtectionCard')) {
          const enabled = !(typeof DB !== 'undefined' && DB.settings && DB.settings.appProtectionEnabled === false);
          html += '<section class="card" id="aureliaProtectionCard" style="margin-top:16px"><div class="section-title"><h2>App security</h2></div>' +
            '<p class="muted">When enabled, Aurelia asks for your PIN or supported device authentication when opening or resuming the app. Disabling this removes the unlock gate; your database remains encrypted on this device.</p>' +
            '<label style="display:flex;align-items:center;gap:10px;margin:12px 0"><input type="checkbox" id="aureliaProtectionToggle" ' +
            (enabled ? 'checked' : '') + ' onchange="aureliaSetAppProtection(this.checked)"> Require PIN / device authentication</label>' +
            '<div id="aureliaProtectionStatus" class="muted" role="status"></div></section>';
        }
        return html;
      };
    }
  } catch (_) {}

  // Normalize image uploads across settings (hotel logo/payment QR) and guest
  // forms. Keep the selected image preview visible and retain a data URL for save
  // handlers; never rely on a transient WebView file:// URL as the stored image.
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files[0]) return;
    const file = input.files[0];
    if (!/^image\\//i.test(file.type)) return;
    if (file.size > 8 * 1024 * 1024) {
      input.value = '';
      if (typeof window.toast === 'function') toast('Choose an image no larger than 8 MiB.');
      return;
    }
    const field = input.closest('.field') || input.parentElement;
    if (!field) return;
    const reader = new FileReader();
    reader.onerror = function () { if (typeof window.toast === 'function') toast('Could not read selected image. Please try again.'); };
    reader.onload = function () {
      const data = String(reader.result || '');
      input.dataset.aureliaImageData = data;
      let preview = field.querySelector('img[data-aurelia-upload-preview]');
      if (!preview) {
        preview = document.createElement('img');
        preview.setAttribute('data-aurelia-upload-preview', '');
        preview.alt = 'Selected image preview';
        preview.style.cssText = 'display:block;max-width:220px;max-height:160px;object-fit:contain;margin-top:8px;border:1px solid var(--line);border-radius:8px;';
        field.appendChild(preview);
      }
      preview.src = data;
      preview.hidden = false;
    };
    reader.readAsDataURL(file);
  }, true);

  // On-device OCR for primary guest/occupant ID image fields. Text is offered for
  // review/editing; OCR is never silently written into identity fields as ground truth.
  const pendingOcrTargets = Object.create(null);
  window.aureliaNativeOcrResult = function (requestId, text, error) {
    const target = pendingOcrTargets[requestId];
    delete pendingOcrTargets[requestId];
    if (!target || !target.isConnected) return;
    let output = target.parentElement.querySelector('textarea[data-aurelia-ocr-result]');
    if (!output) {
      output = document.createElement('textarea');
      output.setAttribute('data-aurelia-ocr-result', '');
      output.rows = 4;
      output.style.cssText = 'display:block;width:100%;margin-top:8px;box-sizing:border-box;';
      output.placeholder = 'Review extracted ID text and correct any mistakes';
      target.parentElement.appendChild(output);
    }
    if (error) output.value = 'OCR failed: ' + String(error);
    else output.value = String(text || '');
    output.setAttribute('aria-label', 'Extracted ID text — review before use');
    if (typeof window.toast === 'function') toast(error ? 'ID text extraction failed.' : 'ID text extracted. Review it carefully before using.');
  };
  document.addEventListener('change', function (event) {
    const input = event.target;
    if (!input || input.type !== 'file' || !input.files || !input.files[0]) return;
    if (!/^image\\//i.test(input.files[0].type)) return;
    const context = (input.id + ' ' + input.name + ' ' + (input.closest('.field')?.innerText || '') +
      ' ' + (input.labels ? Array.from(input.labels).map(label => label.innerText).join(' ') : '')).toLowerCase();
    if (!/(id|identity|guest|occupant|passport|license|licence|aadhaar|aadhar|document)/i.test(context)) return;
    const field = input.closest('.field') || input.parentElement;
    if (!field || field.querySelector('[data-aurelia-ocr-button]')) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn';
    button.setAttribute('data-aurelia-ocr-button', '');
    button.textContent = 'Extract ID text (OCR)';
    button.style.marginTop = '8px';
    button.onclick = function () {
      if (!window.AureliaNative || typeof window.AureliaNative.postMessage !== 'function') {
        if (typeof window.toast === 'function') toast('On-device OCR is available in the installed Android app.');
        return;
      }
      const file = input.files && input.files[0];
      if (!file || file.size > 8 * 1024 * 1024) {
        if (typeof window.toast === 'function') toast('Choose an ID image no larger than 8 MiB.');
        return;
      }
      const reader = new FileReader();
      reader.onerror = function () { if (typeof window.toast === 'function') toast('Could not read ID image.'); };
      reader.onload = function () {
        const dataUrl = String(reader.result || '');
        const comma = dataUrl.indexOf(',');
        if (comma < 0) return;
        const requestId = 'ocr_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
        pendingOcrTargets[requestId] = field;
        button.disabled = true; button.textContent = 'Extracting…';
        const original = window.aureliaNativeOcrResult;
        window.aureliaNativeOcrResult = function (id, text, error) {
          if (id === requestId) { button.disabled = false; button.textContent = 'Extract ID text (OCR)'; }
          original(id, text, error);
        };
        window.AureliaNative.postMessage(JSON.stringify({
          type:'recognizeIdImage', requestId:requestId, imageBase64:dataUrl.slice(comma + 1)
        }));
      };
      reader.readAsDataURL(file);
    };
    field.appendChild(button);
  }, true);

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
