/**
 * NWJSPolyfill.js
 * Injected via WKUserScript at document start (before any game JS runs).
 *
 * Goal: Stub out the NW.js / Node.js APIs that RPG Maker MV/MZ expects
 *       when running inside NW.js on desktop.  We only provide the minimum
 *       surface area needed so that rmmz_core.js / rpg_core.js initialise
 *       without crashing.  Unrecognised `require()` calls are warned in
 *       the console and return an empty object — they do NOT throw.
 *
 * What we deliberately DO NOT emulate:
 *   - Real file-system access (require('fs'))    → returns safe mock
 *   - Native Node modules (crypto, zlib, etc.)  → returns safe mock
 *   - nw.Window resize / fullscreen              → no-op
 */

(function (global) {
  "use strict";

  // ── 1. process (Node.js global) ──────────────────────────────────────────
  if (typeof global.process === "undefined") {
    global.process = {
      platform: "darwin",   // closest to iOS; avoids "win32" code paths
      version:  "v18.0.0",  // semver expected by some plugins
      env:      {},
      argv:     [],
      execPath: "",
      mainModule: {
        filename: "",
        id:       ".",
        loaded:   true,
        children: []
      },
      nextTick: function (fn) { Promise.resolve().then(fn); },
      cwd:  function () { return ""; },
      exit: function () { webkit.messageHandlers.rpgQuit.postMessage({}); }
    };
  }

  // ── 2. require() stub ────────────────────────────────────────────────────
  //   RPG Maker MV uses: require('nw.gui')
  //   RPG Maker MZ uses: nothing (pure ESM/browser), but plugins may use it.
  if (typeof global.require === "undefined") {
    global.require = function rpgRequireStub(moduleName) {
      switch (moduleName) {
        case "nw.gui":
          return global.nw;

        case "path":
          return {
            join:    function () { return Array.from(arguments).join("/").replace(/\/+/g, "/"); },
            dirname: function (p) { return p.replace(/\/[^/]*$/, "") || "."; },
            basename:function (p, ext) {
              var base = p.split("/").pop();
              return ext && base.endsWith(ext) ? base.slice(0, -ext.length) : base;
            },
            extname: function (p) { var m = p.match(/(\.[^./]+)$/); return m ? m[1] : ""; },
            resolve: function () { return Array.from(arguments).join("/"); },
            sep:     "/"
          };

        case "fs":
          // Safe mock — plugins that call fs methods get stubs, not crashes.
          var fsMock = {
            existsSync:    function () { return false; },
            readFileSync:  function () { throw new Error("[RPGPlayer] fs.readFileSync not supported"); },
            writeFileSync: function () { console.warn("[RPGPlayer] fs.writeFileSync ignored"); },
            mkdirSync:     function () {},
            readdirSync:   function () { return []; },
            statSync:      function () { return { isDirectory: function(){ return false; }, size: 0 }; },
            readFile:      function (p, opts, cb) {
              if (typeof opts === "function") { cb = opts; }
              cb(new Error("[RPGPlayer] fs.readFile not supported"));
            },
            writeFile:     function (p, data, opts, cb) {
              if (typeof opts === "function") { cb = opts; }
              console.warn("[RPGPlayer] fs.writeFile ignored: " + p);
              if (cb) cb(null);
            }
          };
          return fsMock;

        case "os":
          return {
            platform:  function () { return "darwin"; },
            homedir:   function () { return ""; },
            tmpdir:    function () { return ""; }
          };

        case "child_process":
          return {
            exec:  function (cmd, opts, cb) {
              if (typeof opts === "function") { cb = opts; }
              if (cb) cb(new Error("[RPGPlayer] child_process not supported"), "", "");
            },
            spawn: function () { return { on: function(){}, stdout: { on: function(){} }, stderr: { on: function(){} } }; }
          };

        case "events":
          // Minimal EventEmitter for plugins that require('events').EventEmitter
          function EventEmitter() { this._events = {}; }
          EventEmitter.prototype.on = function(ev, fn) {
            (this._events[ev] = this._events[ev] || []).push(fn); return this;
          };
          EventEmitter.prototype.emit = function(ev) {
            var args = Array.prototype.slice.call(arguments, 1);
            (this._events[ev] || []).forEach(function(fn){ fn.apply(null, args); });
            return this;
          };
          EventEmitter.prototype.removeListener = function(ev, fn) {
            if (this._events[ev]) {
              this._events[ev] = this._events[ev].filter(function(f){ return f !== fn; });
            }
            return this;
          };
          EventEmitter.prototype.removeAllListeners = function(ev) {
            if (ev) { delete this._events[ev]; } else { this._events = {}; }
            return this;
          };
          return { EventEmitter: EventEmitter };

        default:
          console.warn("[RPGPlayer] require('" + moduleName + "') not implemented — returning {}");
          return {};
      }
    };

    // CommonJS module.exports compatibility
    if (typeof global.module === "undefined") {
      global.module = { exports: {} };
    }
    if (typeof global.exports === "undefined") {
      global.exports = global.module.exports;
    }
  }

  // ── 3. window.nw (NW.js API) ─────────────────────────────────────────────
  //   RPG Maker MV checks for `window.nw` to detect NW.js environment.
  //   We provide enough of the API to pass those checks without crashing.
  if (typeof global.nw === "undefined") {
    global.nw = {
      App: {
        argv:      [],
        dataPath:  "",
        manifest:  {},
        clearCache:        function () {},
        closeAllWindows:   function () {},
        quit:              function () { webkit.messageHandlers.rpgQuit.postMessage({}); },
        getProxyForURL:    function (url, cb) { if (cb) cb("DIRECT"); },
        setCrashDumpDir:   function () {},
        addOriginAccessWhitelistEntry: function () {},
        removeOriginAccessWhitelistEntry: function () {}
      },
      Clipboard: {
        get: function () {
          return {
            set: function () {},
            get: function () { return ""; },
            clear: function () {}
          };
        }
      },
      Screen: {
        screens: [{
          id:            0,
          bounds:        { x: 0, y: 0, width: screen.width,  height: screen.height  },
          work_area:     { x: 0, y: 0, width: screen.width,  height: screen.height  },
          scaleFactor:   window.devicePixelRatio || 1,
          rotation:      0,
          touchSupport:  true
        }],
        Init:                  function () {},
        chooseDesktopMedia:    function () {}
      },
      Shell: {
        openExternal:  function (url) { console.warn("[RPGPlayer] nw.Shell.openExternal: " + url); },
        openItem:      function ()    {},
        showItemInFolder: function () {}
      },
      Window: {
        get: function () {
          return {
            title:   document.title || "",
            x: 0, y: 0,
            width:   screen.width,
            height:  screen.height,
            zoomLevel: 0,
            isFullscreen: true,
            enterFullscreen: function () {},
            leaveFullscreen: function () {},
            toggleFullscreen: function () {},
            maximize:   function () {},
            unmaximize: function () {},
            minimize:   function () {},
            restore:    function () {},
            close:      function () { webkit.messageHandlers.rpgQuit.postMessage({}); },
            show:       function () {},
            hide:       function () {},
            focus:      function () {},
            blur:       function () {},
            reload:     function () { location.reload(); },
            reloadDev:  function () {},
            setMaximumSize: function () {},
            setMinimumSize: function () {},
            setResizable:   function () {},
            setAlwaysOnTop: function () {},
            setPosition:    function () {},
            setSize:        function () {},
            on:             function () {},
            once:           function () {},
            removeListener: function () {},
            removeAllListeners: function () {}
          };
        },
        open: function (url, opts, cb) {
          console.warn("[RPGPlayer] nw.Window.open ignored: " + url);
          if (cb) cb(null);
        }
      }
    };
  }

  // ── 4. Performance / timing ───────────────────────────────────────────────
  //   Some older MV plugins use `setImmediate` (Node.js).
  if (typeof global.setImmediate === "undefined") {
    global.setImmediate = function (fn) {
      return setTimeout(fn, 0);
    };
    global.clearImmediate = clearTimeout;
  }

  // ── 5. FPS Monitor (debug) ────────────────────────────────────────────────
  //   Reports average FPS every 5 seconds to the native console bridge.
  //   Can be disabled by setting window.__RPG_FPS_MONITOR = false before load.
  (function () {
    if (global.__RPG_FPS_MONITOR === false) return;

    var frames = 0;
    var lastTime = performance.now();

    function tick(now) {
      frames++;
      if (now - lastTime >= 5000) {
        var fps = (frames / ((now - lastTime) / 1000)).toFixed(1);
        console.log("[RPGPlayer][FPS] " + fps + " fps (avg over 5s)");
        if (typeof webkit !== "undefined" && webkit.messageHandlers.rpgConsole) {
          webkit.messageHandlers.rpgConsole.postMessage({ type: "fps", value: parseFloat(fps) });
        }
        frames   = 0;
        lastTime = now;
      }
      requestAnimationFrame(tick);
    }

    requestAnimationFrame(tick);
  })();

  // ── 6. Uncaught error bridge ──────────────────────────────────────────────
  global.addEventListener("error", function (event) {
    var msg = "[RPGPlayer][ERROR] " + event.message + " @ " + event.filename + ":" + event.lineno;
    console.error(msg);
    if (typeof webkit !== "undefined" && webkit.messageHandlers.rpgConsole) {
      webkit.messageHandlers.rpgConsole.postMessage({
        type: "error", message: event.message,
        filename: event.filename, lineno: event.lineno
      });
    }
  });

  global.addEventListener("unhandledrejection", function (event) {
    var msg = "[RPGPlayer][UNHANDLED] " + String(event.reason);
    console.error(msg);
    if (typeof webkit !== "undefined" && webkit.messageHandlers.rpgConsole) {
      webkit.messageHandlers.rpgConsole.postMessage({ type: "rejection", message: msg });
    }
  });

}(typeof globalThis !== "undefined" ? globalThis : window));
