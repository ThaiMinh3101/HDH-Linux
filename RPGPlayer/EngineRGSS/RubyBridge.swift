// RPGPlayer/EngineRGSS/RubyBridge.swift
//
// Swift wrapper around the mruby VM.
// Manages VM lifecycle and routes RGSS Ruby API callbacks to the Metal renderer.

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Global renderer reference (C-callback boundary)
//
// @convention(c) closures cannot capture variables from their enclosing scope.
// We store the renderer in a module-level global so the C callback can reach it.
// Lifecycle: assigned in start(), cleared in deinit.
// ---------------------------------------------------------------------------
private var _rgssRenderer: SpriteRenderer?

// ---------------------------------------------------------------------------
// MARK: - RubyBridge
// ---------------------------------------------------------------------------

/// Initialises the mruby VM, registers RGSS classes, and executes Ruby scripts.
///
/// Thread safety: `start()` is designed to be called from a background thread.
/// The C callback dispatches renderer calls back to the main thread.
final class RubyBridge {

    // Pointer to mrb_state (mruby VM) — matches the type returned by mrb_open()
    private var mrb: UnsafeMutablePointer<mrb_state>?

    // MARK: - Lifecycle

    init() {}

    deinit {
        _rgssRenderer = nil
        if let mrb = mrb {
            mrb_close(mrb)
        }
    }

    // MARK: - Start

    /// Boot the mruby VM and run `script`, routing any `Sprite#bitmap=` calls
    /// to `renderer` via a Metal texture load.
    ///
    /// - Parameters:
    ///   - script: Ruby source code (RGSS-compatible).
    ///   - renderer: The Metal renderer that RGSS Sprite calls will drive.
    func start(script: String, renderer: SpriteRenderer) {
        start(renderer: renderer, scripts: [RGSSScript(id: 0, name: "main.rb", source: script)])
    }

    /// Boot the mruby VM and run a list of RGSS scripts IN ORDER.
    ///
    /// M6.0: scripts đến từ ScriptLoader (đã decode + zlib decompress từ
    /// Data/Scripts.rvdata2). Thứ tự load cực kỳ quan trọng — script sau phụ
    /// thuộc class định nghĩa ở script trước.
    ///
    /// M6.1: trước khi load scripts, load RPGClasses.rb (định nghĩa các class
    /// RPG::* data classes) từ bundle — cần thiết để Marshal.load các file
    /// .rvdata2 thật (object class RPG::Actor, RPG::Map, ...).
    ///
    /// Error handling M6.0:
    ///   - SyntaxError   → log ❌ và dừng load (script hỏng = lỗi nghiêm trọng)
    ///   - runtime error → log ⚠️ và TIẾP TỤC (binding RGSS chưa implement hết,
    ///                     script sau vẫn có thể load được — đúng mục tiêu M6.0)
    ///
    /// - Parameters:
    ///   - renderer: The Metal renderer that RGSS Sprite calls will drive.
    ///   - scripts:  Các script RGSS đã giải nén, theo đúng thứ tự trong rvdata2.
    func start(renderer: SpriteRenderer, scripts: [RGSSScript]) {
        guard mrb == nil else {
            print("[RubyBridge] ⚠️  VM already running — ignoring duplicate start()")
            return
        }

        // Store globally for C callback (no captures allowed in @convention(c))
        _rgssRenderer = renderer

        // Open mruby VM
        guard let mrbPtr = mrb_open() else {
            print("[RubyBridge] ❌ mrb_open() failed — cannot allocate mruby VM")
            return
        }
        mrb = mrbPtr
        print("[RubyBridge] ✅ mruby VM opened")

        // ---------------------------------------------------------------------------
        // Register RGSS Sprite class.
        // The callback is a @convention(c) closure: no local variable captures.
        // It accesses _rgssRenderer via the module global defined above.
        // ---------------------------------------------------------------------------
        let bitmapCallback: SpriteSetBitmapCallback = { pathPtr in
            guard let pathPtr = pathPtr else { return }
            // Copy path before any GC could move mruby heap objects
            let path = String(cString: pathPtr)
            DispatchQueue.main.async {
                _rgssRenderer?.loadTexture(named: path)
            }
        }
        mrb_define_sprite_class(mrbPtr, bitmapCallback)
        print("[RubyBridge] ✅ RGSS classes registered: Sprite")

        // Register Input module (M2: trigger?/press?/repeat?, dir4/dir8)
        mrb_define_input_module(mrbPtr)
        print("[RubyBridge] ✅ RGSS modules registered: Input")

        // Register Marshal module (M3: save/load via Marshal.load / Marshal.dump)
        mrb_define_marshal_module(mrbPtr)
        print("[RubyBridge] ✅ RGSS modules registered: Marshal")

        // ---------------------------------------------------------------------------
        // M6.1: Load RPG::* data classes (RPGClasses.rb) from bundle.
        // Cần thiết để Marshal.load các file .rvdata2 thật.
        // ---------------------------------------------------------------------------
        loadRPGClasses(into: mrbPtr)

        // ---------------------------------------------------------------------------
        // Execute scripts in order
        // ---------------------------------------------------------------------------
        guard !scripts.isEmpty else {
            print("[RubyBridge] ⚠️  Không có script nào để load")
            return
        }

        var syntaxErrorCount = 0
        var loadedCount      = 0
        var runtimeErrorCount = 0

        for script in scripts {
            // Binary-safe load — dùng utf8CString (null-terminated [CChar])
            // thay vì withCString + utf8.count (có thể overrun nếu chứa NUL).
            // Ruby source RGSS không chứa NUL; nếu có, utf8CString truncate
            // tại NUL → parse sai → SyntaxError — đúng hành vi fail mong đợi.
            var cBytes = script.source.utf8CString
            let rc = cBytes.withUnsafeBufferPointer { buf in
                var isSyntax = 0
                // buf.count bao gồm null terminator — trừ 1 để không load NUL cuối
                let rc = mrb_bridge_load_nstring(mrbPtr, buf.baseAddress, buf.count - 1, &isSyntax)
                // Lưu isSyntax để dùng sau (không thể capture biến var trong C closure)
                lastSyntaxFlag = isSyntax != 0
                return rc
            }

            if rc == 0 {
                loadedCount += 1
                print("[RubyBridge]   ✅ #\(script.id) \"\(script.name)\"")
            } else {
                let errMsg = String(cString: mrb_bridge_last_error(mrbPtr))
                if lastSyntaxFlag {
                    syntaxErrorCount += 1
                    print("[RubyBridge]   ❌ #\(script.id) \"\(script.name)\" SYNTAX ERROR: \(errMsg)")
                } else {
                    runtimeErrorCount += 1
                    print("[RubyBridge]   ⚠️  #\(script.id) \"\(script.name)\" runtime: \(errMsg)")
                }
            }
        }

        print("[RubyBridge] ✅ Load xong \(loadedCount)/\(scripts.count) scripts "
              + "(\(syntaxErrorCount) syntax, \(runtimeErrorCount) runtime error)")

        if syntaxErrorCount > 0 {
            print("[RubyBridge] ⚠️  Có \(syntaxErrorCount) script bị lỗi cú pháp — "
                  + "script hỏng có thể khiến game chạy sai. Xem log ở trên.")
        }
    }

    /// Ngăn việc capture biến var trong closure @convention(c).
    /// Set ngay trong C callback, đọc ngay sau khi gọi.
    private var lastSyntaxFlag = false

    // MARK: - M6.1: RPG::* data classes

    /// Load RPGClasses.rb (định nghĩa RPG::* data classes) từ bundle vào VM.
    /// File nằm trong Resources/ → được copy vào bundle root.
    /// Dùng Bundle(for:) thay vì Bundle.main — trong unit test Bundle.main
    /// trỏ tới test bundle (không có RPGClasses.rb), còn Bundle(for:) trỏ
    /// tới app bundle chứa file.
    /// Nếu không tìm thấy hoặc lỗi cú pháp → log ⚠️ (không dừng VM — game
    /// script vẫn có thể chạy, chỉ là Marshal.load object RPG::* sẽ trả nil).
    private func loadRPGClasses(into mrbPtr: UnsafeMutablePointer<mrb_state>) {
        guard let url = Bundle(for: RubyBridge.self).url(forResource: "RPGClasses", withExtension: "rb"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[RubyBridge] ⚠️  Không tìm thấy RPGClasses.rb trong bundle")
            return
        }

        var cBytes = source.utf8CString
        let rc = cBytes.withUnsafeBufferPointer { buf in
            var isSyntax = 0
            let rc = mrb_bridge_load_nstring(mrbPtr, buf.baseAddress, buf.count - 1, &isSyntax)
            lastSyntaxFlag = isSyntax != 0
            return rc
        }

        if rc == 0 {
            print("[RubyBridge] ✅ RPG::* data classes loaded (RPGClasses.rb)")
        } else {
            let err = String(cString: mrb_bridge_last_error(mrbPtr))
            print("[RubyBridge] ⚠️  RPGClasses.rb load \(lastSyntaxFlag ? "SYNTAX" : "runtime") error: \(err)")
        }
    }

    // MARK: - M6.1: Test helper (không cần SpriteRenderer)

    /// Mở VM + đăng ký Marshal module + load RPGClasses.rb.
    /// Dùng cho unit test — tách riêng để test có thể setTestData() giữa
    /// các lần chạy script (setTestData cần VM đã mở).
    /// - Returns: true nếu mở thành công, false nếu VM đã chạy hoặc lỗi.
    @discardableResult
    func openTestVM() -> Bool {
        guard mrb == nil else {
            return false
        }
        guard let mrbPtr = mrb_open() else {
            return false
        }
        mrb = mrbPtr

        // Register Marshal module (cần cho test Marshal.load)
        mrb_define_marshal_module(mrbPtr)
        // Load RPG::* data classes
        loadRPGClasses(into: mrbPtr)
        return true
    }

    /// Chạy test script trên VM hiện có (nếu đã mở qua openTestVM) hoặc mở
    /// VM mới nếu chưa. Dùng cho unit test (RPGClassesTests).
    /// - Returns: (exitCode, errorMessage). exitCode 0 = thành công.
    @discardableResult
    func runTestScript(_ script: String) -> (Int, String) {
        // Nếu VM chưa mở → mở mới (kèm Marshal module + RPGClasses.rb).
        if mrb == nil {
            guard openTestVM() else {
                return (-1, "Không mở được test VM")
            }
        }
        guard let mrbPtr = mrb else {
            return (-1, "mrb nil sau openTestVM")
        }

        var cBytes = script.utf8CString
        let rc = cBytes.withUnsafeBufferPointer { buf in
            var isSyntax = 0
            let rc = mrb_bridge_load_nstring(mrbPtr, buf.baseAddress, buf.count - 1, &isSyntax)
            lastSyntaxFlag = isSyntax != 0
            return rc
        }

        if rc == 0 {
            return (0, "")
        }
        let err = String(cString: mrb_bridge_last_error(mrbPtr))
        return (-1, err)
    }

    /// Truyền binary data (synthetic Marshal bytes) vào Ruby global $__test_data.
    /// Dùng cho unit test — script Ruby đọc qua `$__test_data`.
    func setTestData(_ data: Data) {
        guard let mrbPtr = mrb else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            mrb_bridge_set_global_string(
                mrbPtr,
                "__test_data",
                base.assumingMemoryBound(to: CChar.self),
                data.count
            )
        }
    }
}
