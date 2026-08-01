/**
 * TranslationBridge.js — M5 RPG Player
 *
 * Hook vào RPG Maker MV/MZ Window_Message để capture text đang hiển thị
 * và gửi về native Swift để dịch bằng Apple Translation framework.
 *
 * Nguyên tắc:
 *  - KHÔNG sửa text gốc trong game, chỉ gửi bản copy về native.
 *  - Native sẽ hiển thị bản dịch dưới dạng subtitle overlay.
 *  - Chỉ gửi khi translationEnabled = true (được set bởi Swift qua
 *    window.__rpgTranslationEnabled trước khi game script chạy).
 *
 * Tương thích:
 *  - RPG Maker MZ: hook Window_Message.prototype.processCharacter
 *  - RPG Maker MV: hook Window_Message.prototype.updateShowText
 */

(function () {
  "use strict";

  // Swift set giá trị này trước khi game script chạy.
  // false = không hook, tránh overhead khi tính năng tắt.
  if (!window.__rpgTranslationEnabled) {
    // Vẫn expose hàm toggle để Swift có thể bật về sau mà không reload page.
    window.__rpgSetTranslationEnabled = function (enabled) {
      window.__rpgTranslationEnabled = enabled;
      if (enabled) installHooks();
      else removeHooks();
    };
    return;
  }

  // ─── State ────────────────────────────────────────────────────────────────

  // Buffer gom text của 1 message window đầy đủ trước khi gửi
  var _buffer = "";
  // Debounce timer — gom ký tự trong 80ms rồi flush 1 lần
  var _flushTimer = null;
  // Lần cuối flush (tránh gửi trùng text giống nhau)
  var _lastSent = "";
  // Flag để biết hook đã install chưa
  var _installed = false;
  // Tham chiếu đến original methods để restore khi tắt
  var _origProcessChar = null;
  var _origUpdateShowText = null;

  var FLUSH_DELAY_MS = 80;

  // ─── Flush ────────────────────────────────────────────────────────────────

  function flushBuffer() {
    _flushTimer = null;
    var text = _buffer.replace(/\x1b[A-Za-z<>!.|\[\]{}()*\\\/,;:@#^~`'"0-9]*/g, "").trim();
    _buffer = "";
    if (!text || text === _lastSent) return;
    _lastSent = text;
    sendToNative(text);
  }

  function scheduleFlush() {
    if (_flushTimer) clearTimeout(_flushTimer);
    _flushTimer = setTimeout(flushBuffer, FLUSH_DELAY_MS);
  }

  function sendToNative(text) {
    try {
      webkit.messageHandlers.rpgTranslate.postMessage({ text: text });
    } catch (e) {
      // rpgTranslate handler không registered (e.g. translationEnabled=false ở native)
    }
  }

  // ─── Hook installers ──────────────────────────────────────────────────────

  function installHooks() {
    if (_installed) return;

    // ── RPG Maker MZ ──────────────────────────────────────────────────────
    // Window_Message.prototype.processCharacter được gọi 1 lần/ký tự
    if (
      typeof Window_Message !== "undefined" &&
      typeof Window_Message.prototype.processCharacter === "function" &&
      !_origProcessChar
    ) {
      _origProcessChar = Window_Message.prototype.processCharacter;
      Window_Message.prototype.processCharacter = function (textState) {
        if (window.__rpgTranslationEnabled && textState && textState.text) {
          _buffer += textState.text[textState.index] || "";
          scheduleFlush();
        }
        return _origProcessChar.apply(this, arguments);
      };
    }

    // ── RPG Maker MV ──────────────────────────────────────────────────────
    // Window_Message.prototype.updateShowText được gọi mỗi khi chuẩn bị hiện 1 dòng
    if (
      typeof Window_Message !== "undefined" &&
      typeof Window_Message.prototype.updateShowText === "function" &&
      !_origUpdateShowText
    ) {
      _origUpdateShowText = Window_Message.prototype.updateShowText;
      Window_Message.prototype.updateShowText = function (textState) {
        // Capture toàn bộ text còn lại trong buffer trước khi hiện
        if (window.__rpgTranslationEnabled && textState && textState.text) {
          var remaining = textState.text.substring(textState.index);
          if (remaining.trim()) {
            _buffer = remaining;
            scheduleFlush();
          }
        }
        return _origUpdateShowText.apply(this, arguments);
      };
    }

    // ── Fallback: lắng nghe event từ native (khi RPG Maker dùng plugin hook khác)
    window.__rpgCaptureText = function (text) {
      if (!window.__rpgTranslationEnabled || !text) return;
      _buffer = text;
      scheduleFlush();
    };

    _installed = true;
  }

  function removeHooks() {
    if (!_installed) return;
    if (
      typeof Window_Message !== "undefined" &&
      _origProcessChar
    ) {
      Window_Message.prototype.processCharacter = _origProcessChar;
      _origProcessChar = null;
    }
    if (
      typeof Window_Message !== "undefined" &&
      _origUpdateShowText
    ) {
      Window_Message.prototype.updateShowText = _origUpdateShowText;
      _origUpdateShowText = null;
    }
    if (_flushTimer) { clearTimeout(_flushTimer); _flushTimer = null; }
    _buffer = "";
    _lastSent = "";
    _installed = false;
  }

  // ─── Init ─────────────────────────────────────────────────────────────────

  window.__rpgSetTranslationEnabled = function (enabled) {
    window.__rpgTranslationEnabled = enabled;
    if (enabled) installHooks();
    else removeHooks();
  };

  // Thử install ngay (game có thể đã load rồi nếu inject vào after-load)
  // Nhưng vì inject atDocumentStart, game scripts chưa chạy → dùng DOMContentLoaded
  document.addEventListener("DOMContentLoaded", function () {
    // Thử install ngay khi DOM ready; game script thường chạy sau DOMContentLoaded
    setTimeout(installHooks, 0);
  });

  // Cũng thử sau 1s cho các game MV load chậm
  setTimeout(installHooks, 1000);

})();
