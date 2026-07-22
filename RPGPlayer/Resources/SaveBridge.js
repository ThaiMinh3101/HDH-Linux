/**
 * SaveBridge.js
 * Injected via WKUserScript at document start.
 *
 * Bridges RPG Maker MV/MZ save game calls to Swift so that save data is
 * written to the app sandbox (Application Support/RPGPlayer/Games/<uuid>/Saves/)
 * instead of the browser's localStorage — which can be purged by iOS.
 *
 * Architecture:
 *   JS calls → webkit.messageHandlers.rpgSave / rpgLoad
 *   Swift reads/writes JSON files in the Saves/ directory
 *   Swift replies via webView.evaluateJavaScript("window.__rpgLoadCallback(...)")
 *
 * Compatibility:
 *   RPG Maker MZ: Patches StorageManager.saveObject / loadObject if present.
 *   RPG Maker MV: Patches DataManager._saveGameWithoutRescue / _loadGame if present.
 *   Fallback:     Patches localStorage (for plugins that use it directly).
 */

(function (global) {
  "use strict";

  // ── Pending load callbacks ────────────────────────────────────────────────
  // Swift calls window.__rpgLoadCallback(key, jsonString) when data is ready.
  var _pendingLoads = {};   // key → { resolve, reject }
  var _callbackId   = 0;

  /**
   * Public callback invoked by Swift after a load completes.
   * @param {string} key       - The save key requested.
   * @param {string|null} json - JSON string of save data, or null if not found.
   */
  global.__rpgLoadCallback = function (key, json) {
    var pending = _pendingLoads[key];
    if (!pending) return;
    delete _pendingLoads[key];
    if (json === null || json === undefined) {
      pending.resolve(null);
    } else {
      try {
        pending.resolve(JSON.parse(json));
      } catch (e) {
        pending.reject(e);
      }
    }
  };

  // ── Core bridge functions ─────────────────────────────────────────────────

  /** Save an object to the native Saves/ directory. */
  function bridgeSave(key, object) {
    try {
      var json = JSON.stringify(object);
      webkit.messageHandlers.rpgSave.postMessage({ key: key, value: json });
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }

  /** Load an object from the native Saves/ directory (returns a Promise). */
  function bridgeLoad(key) {
    return new Promise(function (resolve, reject) {
      // If a load for this key is already in flight, queue behind it.
      _pendingLoads[key] = { resolve: resolve, reject: reject };
      webkit.messageHandlers.rpgLoad.postMessage({ key: key });
    });
  }

  /** Check whether a save slot exists. */
  function bridgeExists(key) {
    // Synchronous is not possible here — we return false as a safe default.
    // MZ uses exists() only for UI (greying out load slots); it is non-critical.
    return false;
  }

  /** Remove a save slot. */
  function bridgeRemove(key) {
    webkit.messageHandlers.rpgSaveRemove.postMessage({ key: key });
    return Promise.resolve();
  }

  // ── Expose bridge globally ────────────────────────────────────────────────
  global.RPGPlayerBridge = {
    save:   bridgeSave,
    load:   bridgeLoad,
    exists: bridgeExists,
    remove: bridgeRemove
  };

  // ── RPG Maker MZ — patch StorageManager ──────────────────────────────────
  // MZ defines StorageManager in rmmz_core.js.  We wait for DOMContentLoaded
  // so the class is guaranteed to exist before patching.
  function patchMZ() {
    if (typeof StorageManager === "undefined") return false;

    // MZ: StorageManager.saveObject(saveName, object) → Promise
    var _origSaveObject = StorageManager.saveObject;
    StorageManager.saveObject = function (saveName, object) {
      console.log("[RPGPlayer][Save] MZ saveObject: " + saveName);
      return bridgeSave(saveName, object);
    };

    // MZ: StorageManager.loadObject(saveName) → Promise<object|null>
    var _origLoadObject = StorageManager.loadObject;
    StorageManager.loadObject = function (saveName) {
      console.log("[RPGPlayer][Save] MZ loadObject: " + saveName);
      return bridgeLoad(saveName);
    };

    // MZ: StorageManager.exists(saveName) → bool
    StorageManager.exists = function (saveName) {
      return bridgeExists(saveName);
    };

    // MZ: StorageManager.remove(saveName) → Promise
    StorageManager.remove = function (saveName) {
      return bridgeRemove(saveName);
    };

    // MZ: StorageManager.backup / cleanBackup / restoreBackup (no-op stubs)
    StorageManager.backup        = function () { return Promise.resolve(); };
    StorageManager.cleanBackup   = function () { return Promise.resolve(); };
    StorageManager.restoreBackup = function () { return Promise.resolve(false); };

    console.log("[RPGPlayer] MZ StorageManager patched ✓");
    return true;
  }

  // ── RPG Maker MV — patch DataManager ─────────────────────────────────────
  // MV defines DataManager as a static object in rpg_managers.js.
  function patchMV() {
    if (typeof DataManager === "undefined") return false;

    // MV uses localStorage keys like "RPG File1", "RPG Config", etc.
    // We patch _saveGame / _loadGame to use our bridge instead.

    var _origSaveGame = DataManager._saveGameWithoutRescue;
    DataManager._saveGameWithoutRescue = function (savefileId) {
      var json         = JsonEx.stringify(DataManager.makeSaveContents());
      var compressed   = LZString.compressToBase64(json);
      var key          = DataManager.makeSavename(savefileId);
      console.log("[RPGPlayer][Save] MV saveGame: " + key);
      bridgeSave(key, { compressed: compressed });
      return true;
    };

    var _origLoadGame = DataManager.loadGameWithoutRescue;
    DataManager.loadGameWithoutRescue = function (savefileId) {
      // MV expects synchronous load — bridge is async, so we defer and reload.
      // Pattern: trigger load → store in window.__rpgPendingLoad → re-enter.
      var key = DataManager.makeSavename(savefileId);
      if (global.__rpgPendingLoad && global.__rpgPendingLoad.key === key) {
        // Second pass: data is ready
        var data = global.__rpgPendingLoad.data;
        delete global.__rpgPendingLoad;
        if (!data) return false;
        try {
          var json    = LZString.decompressFromBase64(data.compressed);
          var contents = JsonEx.parse(json);
          DataManager.extractSaveContents(contents);
          return true;
        } catch (e) {
          console.error("[RPGPlayer][Save] MV load parse error: " + e);
          return false;
        }
      }
      // First pass: kick off async load then scene-reload when ready.
      bridgeLoad(key).then(function (data) {
        global.__rpgPendingLoad = { key: key, data: data };
        // Re-trigger the load flow via scene transition (safe re-entry)
        if (typeof SceneManager !== "undefined") {
          SceneManager.goto(Scene_Load);
        }
      });
      return false;
    };

    console.log("[RPGPlayer] MV DataManager patched ✓");
    return true;
  }

  // ── localStorage shim (fallback for plugins using it directly) ───────────
  //   We wrap localStorage so that reads/writes also go through the bridge.
  //   This is secondary — primary save path is StorageManager/DataManager patch.
  (function () {
    var _native = global.localStorage;
    var _mem    = {};   // in-memory cache for get-after-set within same session

    var _proxyHandler = {
      get: function (target, prop) {
        if (prop === "getItem") {
          return function (key) {
            if (Object.prototype.hasOwnProperty.call(_mem, key)) return _mem[key];
            // For synchronous compatibility, return null (async load not possible here)
            return null;
          };
        }
        if (prop === "setItem") {
          return function (key, value) {
            _mem[key] = value;
            // Also persist via bridge (fire-and-forget)
            bridgeSave("__ls__" + key, { raw: value });
          };
        }
        if (prop === "removeItem") {
          return function (key) {
            delete _mem[key];
            bridgeRemove("__ls__" + key);
          };
        }
        if (prop === "clear") {
          return function () { _mem = {}; };
        }
        if (prop === "key")    { return function (i) { return Object.keys(_mem)[i] || null; }; }
        if (prop === "length") { return Object.keys(_mem).length; }
        return _native[prop];
      },
      set: function (target, prop, value) {
        _mem[prop] = value;
        bridgeSave("__ls__" + prop, { raw: value });
        return true;
      }
    };

    try {
      Object.defineProperty(global, "localStorage", {
        get: function () { return new Proxy(_native, _proxyHandler); },
        configurable: true
      });
    } catch (e) {
      // Proxy not available or defineProperty failed — fall through to native
      console.warn("[RPGPlayer] localStorage proxy failed: " + e);
    }
  })();

  // ── Deferred patch after scripts load ────────────────────────────────────
  var _patchAttempts = 0;
  function tryPatch() {
    var mzOK = patchMZ();
    var mvOK = patchMV();
    if (mzOK || mvOK) return;

    _patchAttempts++;
    if (_patchAttempts < 20) {
      // Retry up to ~2 seconds after DOMContentLoaded
      setTimeout(tryPatch, 100);
    } else {
      console.warn("[RPGPlayer] SaveBridge: StorageManager/DataManager not found after 2s — relying on localStorage shim only.");
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", tryPatch);
  } else {
    tryPatch();
  }

}(typeof globalThis !== "undefined" ? globalThis : window));
