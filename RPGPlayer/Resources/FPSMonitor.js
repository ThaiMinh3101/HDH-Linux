/**
 * FPSMonitor.js — M5 RPG Player
 *
 * Đo FPS thực của WKWebView game loop và báo về native mỗi 2 giây.
 * Không phụ thuộc vào RPG Maker internals — dùng requestAnimationFrame.
 *
 * Native nhận message qua rpgConsole { type: "fps", value: <number> }
 * Cũng expose window.__rpgGetFPS() để kiểm tra real-time từ Xcode console.
 */

(function () {
  "use strict";

  var REPORT_INTERVAL_MS = 2000;  // Báo về native mỗi 2 giây
  var _frameCount = 0;
  var _lastReportTime = performance.now();
  var _lastFPS = 0;
  var _rafHandle = null;
  var _running = false;

  function tick(now) {
    _frameCount++;
    var elapsed = now - _lastReportTime;

    if (elapsed >= REPORT_INTERVAL_MS) {
      _lastFPS = Math.round((_frameCount / elapsed) * 1000);
      _frameCount = 0;
      _lastReportTime = now;

      try {
        webkit.messageHandlers.rpgConsole.postMessage({
          type: "fps",
          value: _lastFPS,
          // Thêm budget info để dễ diagnose drop
          budgetMs: elapsed / Math.max(1, _lastFPS)
        });
      } catch (e) {
        // handler không available
      }
    }

    if (_running) {
      _rafHandle = requestAnimationFrame(tick);
    }
  }

  function start() {
    if (_running) return;
    _running = true;
    _frameCount = 0;
    _lastReportTime = performance.now();
    _rafHandle = requestAnimationFrame(tick);
  }

  function stop() {
    _running = false;
    if (_rafHandle) {
      cancelAnimationFrame(_rafHandle);
      _rafHandle = null;
    }
  }

  // Expose để Swift có thể gọi từ evaluateJavaScript nếu cần
  window.__rpgGetFPS = function () { return _lastFPS; };
  window.__rpgFPSStart = start;
  window.__rpgFPSStop = stop;

  // Auto-start sau khi page load xong
  document.addEventListener("DOMContentLoaded", function () {
    start();
  });

  // Fallback nếu DOMContentLoaded đã bắn trước khi script inject
  if (document.readyState === "complete" || document.readyState === "interactive") {
    start();
  }
})();
