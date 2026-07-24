// RPGPlayer/Resources/ImageErrorGuard.js
//
// Milestone 4 — Crash Guard: Image Error Detection
//
// Injected atDocumentStart so it is active before any game scripts run.
// When any <img> element fails to load, this shim:
//   1. Logs to the browser console (visible in Safari DevTools)
//   2. Posts a message to native Swift via webkit.messageHandlers.rpgConsole
//      with type "imageError" so we can track broken assets without crashing.
//
// This does NOT try to replace broken images with placeholders on the JS side —
// that would interfere with how RPG Maker manages its own bitmap cache.
// Instead, the RGSS Metal side uses a checkerboard placeholder texture.

(function() {
  'use strict';

  // ─── Patch HTMLImageElement to intercept all image load errors ───────────

  /**
   * Posts an imageError message to the native Swift host.
   * Safe to call even if webkit.messageHandlers is unavailable.
   */
  function notifyNative(src) {
    var cleanSrc = src || '(unknown)';
    // Trim the scheme prefix so log is readable
    cleanSrc = cleanSrc.replace(/^rpggame:\/\/[^\/]+/, '');

    console.warn('[ImageErrorGuard] Failed to load image: ' + cleanSrc);

    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rpgConsole) {
        window.webkit.messageHandlers.rpgConsole.postMessage({
          type: 'imageError',
          src: cleanSrc
        });
      }
    } catch (e) {
      // Silently ignore — don't let our error handler crash the game
    }
  }

  // ─── Option A: Patch Image constructor prototype ─────────────────────────
  // Intercepts all `new Image()` calls (used by RPG Maker's ImageManager).
  //
  // We wrap the setter for `src` to attach an onerror handler each time
  // a new source is assigned. This avoids clobbering any existing onerror
  // the game may set on a specific image.

  var OriginalImage = window.Image;
  if (OriginalImage && OriginalImage.prototype) {
    var originalSrcDescriptor = Object.getOwnPropertyDescriptor(
      HTMLImageElement.prototype, 'src'
    );

    if (originalSrcDescriptor && originalSrcDescriptor.set) {
      Object.defineProperty(HTMLImageElement.prototype, 'src', {
        get: originalSrcDescriptor.get,
        set: function(val) {
          // Attach our error listener before setting src so it fires
          // even if the load fails synchronously (cached 404 etc.)
          var img = this;
          img.addEventListener('error', function onImgError(e) {
            notifyNative(img.src || val);
            // Remove after first fire to avoid duplicate reports
            img.removeEventListener('error', onImgError);
          }, { once: true });
          originalSrcDescriptor.set.call(this, val);
        },
        configurable: true,
        enumerable:   true
      });
    }
  }

  // ─── Option B: document-level 'error' event (capture phase) ─────────────
  // Catches image errors that slip through Option A (e.g. <img> in HTML,
  // or images created via innerHTML).
  document.addEventListener('error', function(e) {
    var target = e.target;
    if (target && target.tagName === 'IMG') {
      notifyNative(target.src);
    }
  }, true /* capture phase, not bubble */);

  // ─── Global JS error catch (bonus: catches any unhandled JS exception) ───
  // Already partially handled by NWJSPolyfill but guard here too.
  var _prevOnError = window.onerror;
  window.onerror = function(message, source, lineno, colno, error) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rpgConsole) {
        window.webkit.messageHandlers.rpgConsole.postMessage({
          type:     'error',
          message:  String(message || ''),
          filename: String(source   || ''),
          lineno:   lineno || 0
        });
      }
    } catch (e) { /* silent */ }

    if (typeof _prevOnError === 'function') {
      return _prevOnError.apply(this, arguments);
    }
    return false; // do not suppress default behaviour
  };

  console.log('[ImageErrorGuard] ✅ Image error guard installed');
})();
