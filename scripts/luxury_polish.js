/* Aurelia luxury theme and settings cleanup. Does not pretend Drive is connected without OAuth. */
(function () {
  'use strict';
  const css = `
    :root{--brand:#3a2117!important;--brand2:#d9b45d!important;--ink:#2b1b14!important;--muted:#897665!important;--bg:#f3ece1!important;--card:#fffaf1!important;--line:#d9c39b!important;--soft:#ead9b5!important;--danger:#963d35!important;--warn:#9a6d24!important;--ok:#416b4b!important;--shadow:0 14px 36px rgba(49,28,16,.14)!important;--radius:20px!important}
    body{background:radial-gradient(ellipse at top right,rgba(217,180,93,.16),transparent 42%),var(--bg)!important;color:var(--ink)!important}
    .sidebar,.top{background:rgba(39,23,16,.97)!important;color:#f8e9c4!important;border-color:#77522d!important}
    .sidebar .brand,.sidebar .brand strong,.sidebar .nav button,.top button,.top input{color:#f8e9c4!important}
    .nav button.active,.nav button:hover{background:linear-gradient(135deg,#634125,#3a2117)!important;color:#f4d47c!important}
    .btn.primary{background:linear-gradient(135deg,#f5dc8d,#b98832 55%,#f5dc8d)!important;color:#28180f!important;border:1px solid #f4df9a!important;box-shadow:0 8px 22px rgba(163,112,35,.28)!important}
    .card,.modal,.settings-card,.content-card,.section-card{background:linear-gradient(145deg,#fffaf0,#f7eddb)!important;border-color:#d6b56f!important;box-shadow:0 12px 30px rgba(55,32,18,.10)!important}
    input,select,textarea,.search input{background:#fffdf7!important;color:#302016!important;border-color:#d8c49f!important}
    .table th{background:#ead8b2!important;color:#402818!important}
    .room,.item,.subcard,.occupant,.vehicle{background:#fff9ec!important;border-color:#d8bf8a!important}
    .toast{background:#2c1a11!important;border:1px solid #d9b45d!important;color:#ffe7a3!important}
    #aureliaDriveSetupCard .field{margin-bottom:10px}
    #aureliaDriveSetupCard .field input{width:100%}
    .aurelia-luxury-note{border:1px solid #d9b45d;border-radius:14px;padding:12px;background:#f5e7c7;color:#4b3019}
    @media(max-width:800px){.sidebar{background:#29180f!important}.content{padding:14px}}
  `;
  const style=document.createElement('style');style.id='aurelia-luxury-rich-theme';style.textContent=css;document.head.appendChild(style);

  function patchSettings() {
    if (typeof window.pagesSettingsNew !== 'function' && typeof pagesSettingsNew !== 'function') return;
    const original = typeof pagesSettingsNew === 'function' ? pagesSettingsNew : window.pagesSettingsNew;
    const wrapped = function () {
      let html = original.apply(this, arguments);
      // Remove the redundant browser PIN / biometric panel. The Android app already
      // has native app-lock and encrypted device storage; browser-only PIN controls mislead.
      html = html.replace(/<section class="card"[^>]*>\s*<div class="section-title"><h2>Backup & device security<\/h2>[\\s\\S]*?<\/section>/i, '');
      // Replace the non-functional placeholder with explicit configuration fields.
      html = html.replace(/<section class="card" id="aureliaDriveSettingsCard"[\\s\\S]*?<\/section>/i,
        '<section class="card" id="aureliaDriveSetupCard"><div class="section-title"><h2>Google Drive backup</h2><span class="muted">Authorization setup</span></div>' +
        '<p class="muted">Connect only after a Google OAuth client is configured for this Android application. A folder ID alone does not grant access.</p>' +
        '<div class="field"><label>Google OAuth client ID</label><input id="aureliaGoogleClientId" autocomplete="off" placeholder="Your Google OAuth client ID" value="' + ((window.DB&&DB.settings&&DB.settings.googleClientId)||'') + '"></div>' +
        '<div class="field"><label>Google Drive folder ID</label><input id="aureliaDriveFolderId" autocomplete="off" placeholder="Paste the target folder ID" value="' + ((window.DB&&DB.settings&&DB.settings.driveFolderId)||'') + '"></div>' +
        '<div class="actions"><button class="btn primary" type="button" id="aureliaDriveAuthorizeBtn">Authorize Google account</button><button class="btn" type="button" id="aureliaDriveBackupNowBtn">Backup now</button></div>' +
        '<div id="aureliaDriveNote" class="aurelia-luxury-note" role="status" style="margin-top:10px">Not connected. Google Drive OAuth must be configured in the Android build before uploads can be enabled.</div></section>');
      return html;
    };
    if (typeof window.pagesSettingsNew === 'function') window.pagesSettingsNew=wrapped;
    if (typeof pagesSettingsNew === 'function') pagesSettingsNew=wrapped;
    if (window.pages && window.pages.settings) window.pages.settings=wrapped;
  }
  patchSettings();
  // Bind handlers after settings HTML has been rendered. Do not claim authorization
  // or upload success without a native OAuth implementation and verified Drive response.
  document.addEventListener('click',function(e){
    const target=e.target&&e.target.closest('#aureliaDriveAuthorizeBtn,#aureliaDriveBackupNowBtn');
    if(!target)return;
    const client=document.getElementById('aureliaGoogleClientId');
    const folder=document.getElementById('aureliaDriveFolderId');
    const note=document.getElementById('aureliaDriveNote');
    if(client&&typeof DB!=='undefined'){DB.settings.googleClientId=client.value.trim();DB.settings.driveFolderId=folder?folder.value.trim():'';if(typeof save==='function')save();}
    if(note)note.textContent=target.id==='aureliaDriveAuthorizeBtn'
      ? 'Google account authorization is not available yet: the Android build needs a registered Google OAuth client and native Drive authorization flow. No account has been connected.'
      : 'Backup not uploaded. Google Drive authorization is not connected, so no cloud file has been created or overwritten.';
    if(typeof window.toast==='function')window.toast(target.id==='aureliaDriveAuthorizeBtn'?'Google Drive OAuth setup is required':'Drive backup unavailable until OAuth is configured');
  });
  // OCR must be checked by a human; never claim optical recognition guarantees exact spelling.
  document.addEventListener('change',function(e){
    if(e.target&&e.target.matches('input[type=file][accept*="image"]')){
      const status=document.getElementById('ocrStatus')||document.getElementById('idOcrStatus');
      if(status)status.textContent='For accurate guest records, verify the extracted name spelling and ID type against the original card before saving.';
    }
  });
})();