// RPGPlayer/Resources/LaunchTimingBridge.js
//
// Milestone 4 — Fast Launch: Performance Measurement
//
// Injected at document start to capture the earliest possible timestamp.
// Reports timing checkpoints to native Swift via rpgConsole message handler.
//
// Checkpoints reported:
//   t0        — script injection time (DOMContentLoaded not yet fired)
//   domReady  — DOMContentLoaded fired (ms from t0)
//   loaded    — window.load fired (ms from t0)  ← last major bottleneck
//   firstPaint — requestAnimationFrame first callback (ms from t0)
//
// The native side logs these so we can benchmark game startup.

(function() {
  'use strict';

  // Record the earliest possible timestamp
  var t0 = performance.now();
  window.__rpgLaunchT0 = t0;

  function sendTiming(label, ms) {
    var payload = {
      type:      'launchTiming',
      checkpoint: label,
      ms:         Math.round(ms)
    };
    try {
      if (window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.rpgConsole) {
        window.webkit.messageHandlers.rpgConsole.postMessage(payload);
      }
    } catch (e) { /* silent — don't block game if messaging fails */ }
    console.log('[LaunchTiming] ' + label + ': ' + Math.round(ms) + 'ms');
  }

  // ─── DOMContentLoaded ────────────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', function() {
    sendTiming('domReady', performance.now() - t0);
  });

  // ─── window.load (all resources) ─────────────────────────────────────────
  window.addEventListener('load', function() {
    var loadMs = performance.now() - t0;
    sendTiming('loaded', loadMs);

    // First paint = first rAF callback after load
    requestAnimationFrame(function() {
      sendTiming('firstPaint', performance.now() - t0);
    });
  });

  console.log('[LaunchTimingBridge] ✅ Timing bridge installed (t0=' + t0.toFixed(1) + 'ms)');
})();
