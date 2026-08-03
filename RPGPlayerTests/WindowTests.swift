import XCTest
@testable import RPGPlayer

/// Unit test cho M6.4 — Window_Base / Window_Message / Window_Selectable.
///
/// Xác minh:
///   1. Window_Message#convert_escape_characters xử lý đúng control codes
///      \C[n], \N[n], \V[n], \\ — theo thứ tự chuẩn RGSS3 (control code
///      TRƯỚC, literal backslash sau; \\ hiển thị 1 dấu \).
///   2. Window_Message#start_message thay \N[n] bằng tên actor và \V[n]
///      bằng giá trị biến (fallback "Actor n" / 0 khi không có).
///   3. Window_Selectable#draw_items đánh dấu cursor "> " / "  " và
///      move_cursor/cursor_up/cursor_down cập nhật index đúng (wrap-around).
///   4. WindowRenderer static helpers: nineSliceLayout đúng 9 vùng
///      (y-flip vì CGContext Y-up — RGSS y=0 trên cùng), isValidWindowSize.
///   5. Window built-in geometry (C bridge) hoạt động.
///
/// CLEAN-ROOM: test viết từ RGSS3 Reference Manual (help file công khai đi
/// kèm RPG Maker VX Ace) — không tham chiếu engine mã nguồn mở GPL/LGPL nào.
///
/// LƯU Ý ESCAPING: script Ruby chứa `\\C`, `\\N`, `\e`... sẽ là invalid escape
/// trong Swift string thường → dùng RAW string `#""" ... """#` (backslash là
/// literal, không bị Swift parse).
final class WindowTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng — runTestScript guard mrb == nil).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    // MARK: - 1. Window_Message control codes

    /// convert_escape_characters: \C/\N/\V → byte control code nội bộ,
    /// `\\` (double backslash) → 1 literal backslash.
    func testConvertEscapeCharactersOrder() {
        let bridge = makeBridge()
        let script = #"""
        wm = Window_Message.new(0, 0, 300, 100)
        # \C[2], \N[1], \V[3] → \x01[2], \x02[1], \x03[3]
        converted = wm.convert_escape_characters("\\C[2]hello\\N[1]\\V[3]")
        raise "C code sai: #{converted.inspect}" unless converted.include?("\x01[2]")
        raise "N code sai: #{converted.inspect}" unless converted.include?("\x02[1]")
        raise "V code sai: #{converted.inspect}" unless converted.include?("\x03[3]")
        # Không còn control code cũ dạng literal \C
        raise "Còn sót \\C" if converted.include?("\\C")
        raise "Còn sót \\N" if converted.include?("\\N")
        # `\\` → 1 literal backslash
        converted2 = wm.convert_escape_characters("a\\\\b")
        raise "double backslash sai: #{converted2.inspect}" unless converted2 == "a\\b"
        puts "CONVERT_ORDER_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "convert_escape_characters sai: \(err)")
    }

    /// start_message thay \N[n] bằng tên actor và \V[n] bằng giá trị biến
    /// (truyền qua param actor_names/variables).
    func testStartMessageSubstitutesActorsAndVariables() {
        let bridge = makeBridge()
        let script = #"""
        wm = Window_Message.new(0, 0, 400, 100)
        wm.start_message("Hello \\N[1]! HP \\V[2]", {1 => "Harold"}, {2 => 42})
        text = wm.contents_text
        raise "actor substitution sai: #{text.inspect}" unless text.include?("Hello Harold!")
        raise "variable substitution sai: #{text.inspect}" unless text.include?("HP 42")
        # Fallback khi không có tên actor → "Actor n"
        wm.start_message("Hi \\N[9]")
        raise "actor fallback sai: #{wm.contents_text.inspect}" unless wm.contents_text.include?("Actor 9")
        # Fallback biến → "0"
        wm.start_message("Var \\V[99]")
        raise "variable fallback sai: #{wm.contents_text.inspect}" unless wm.contents_text.include?("Var 0")
        puts "START_MESSAGE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "start_message substitution sai: \(err)")
    }

    /// start_message strip \C[n] khỏi text hiển thị (màu chưa render).
    func testStartMessageStripsColorCode() {
        let bridge = makeBridge()
        let script = #"""
        wm = Window_Message.new(0, 0, 400, 100)
        wm.start_message("\\C[3]Red text later")
        text = wm.contents_text
        raise "C code còn sót: #{text.inspect}" if text.include?("\x01")
        raise "text sai: #{text.inspect}" unless text.include?("Red text later")
        puts "STRIP_COLOR_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "start_message strip \\C[3] sai: \(err)")
    }

    // MARK: - 2. Window_Selectable

    /// draw_items đánh dấu item được chọn bằng "> ".
    func testSelectableDrawItemsMarksCursor() {
        let bridge = makeBridge()
        let script = #"""
        ws = Window_Selectable.new(0, 0, 300, 200)
        ws.index = 1
        ws.draw_items(["Save", "Load", "Options"])
        text = ws.contents_text
        raise "item 0 sai: #{text.inspect}" unless text.include?("  Save")
        raise "item 1 (cursor) sai: #{text.inspect}" unless text.include?("> Load")
        raise "item 2 sai: #{text.inspect}" unless text.include?("  Options")
        raise "item_max sai" unless ws.item_max == 3
        puts "DRAW_ITEMS_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "draw_items cursor sai: \(err)")
    }

    /// cursor_down / cursor_up wrap-around đúng.
    func testSelectableCursorMovement() {
        let bridge = makeBridge()
        let script = #"""
        ws = Window_Selectable.new(0, 0, 300, 200)
        ws.draw_items(["A", "B", "C"])
        raise "index khởi tạo sai" unless ws.index == 0
        ws.cursor_down
        raise "cursor_down sai" unless ws.index == 1
        ws.cursor_down
        raise "cursor_down lần 2 sai" unless ws.index == 2
        ws.cursor_down
        raise "wrap-around xuống sai" unless ws.index == 0
        ws.cursor_up
        raise "wrap-around lên sai" unless ws.index == 2
        ws.cursor_up
        raise "cursor_up sai" unless ws.index == 1
        puts "CURSOR_MOVE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "cursor movement sai: \(err)")
    }

    // MARK: - 3. WindowRenderer static layout math

    /// nineSliceLayout trả về 9 vùng đúng (CGContext Y-up — y=0 dưới cùng).
    func testNineSliceLayout() {
        let l = WindowRenderer.nineSliceLayout(width: 128, height: 96)
        let c = CGFloat(WindowRenderer.cornerSize)

        // Bottom row (y = h - c vì CGContext Y-up) = khung dưới window RGSS
        XCTAssertEqual(l.topLeft, CGRect(x: 0, y: 96 - c, width: c, height: c))
        XCTAssertEqual(l.topEdge, CGRect(x: c, y: 96 - c, width: 128 - c * 2, height: c))
        XCTAssertEqual(l.topRight, CGRect(x: 128 - c, y: 96 - c, width: c, height: c))
        // Middle row (cạnh trái/phải + center)
        XCTAssertEqual(l.leftEdge, CGRect(x: 0, y: c, width: c, height: 96 - c * 2))
        XCTAssertEqual(l.rightEdge, CGRect(x: 128 - c, y: c, width: c, height: 96 - c * 2))
        XCTAssertEqual(l.center, CGRect(x: c, y: c, width: 128 - c * 2, height: 96 - c * 2))
        // Top row (y = 0) = khung trên window RGSS
        XCTAssertEqual(l.bottomLeft, CGRect(x: 0, y: 0, width: c, height: c))
        XCTAssertEqual(l.bottomEdge, CGRect(x: c, y: 0, width: 128 - c * 2, height: c))
        XCTAssertEqual(l.bottomRight, CGRect(x: 128 - c, y: 0, width: c, height: c))
    }

    /// isValidWindowSize — kích thước phải đủ lớn cho 4 góc (16px mỗi bên).
    func testIsValidWindowSize() {
        XCTAssertTrue(WindowRenderer.isValidWindowSize(width: 128, height: 128))
        XCTAssertTrue(WindowRenderer.isValidWindowSize(width: 32, height: 32))
        XCTAssertFalse(WindowRenderer.isValidWindowSize(width: 10, height: 128))
        XCTAssertFalse(WindowRenderer.isValidWindowSize(width: 128, height: 10))
        XCTAssertFalse(WindowRenderer.isValidWindowSize(width: 0, height: 0))
    }

    // MARK: - 4. Window base x/y/opacity là built-in (C bridge)

    /// Window.new + set geometry/opacity/visible qua C bridge, getter đọc lại.
    func testWindowBuiltInGeometry() {
        let bridge = makeBridge()
        let script = #"""
        w = Window.new(10, 20, 300, 150)
        w.x = 30
        w.y = 40
        w.width = 320
        w.height = 180
        w.opacity = 128
        w.visible = false
        raise "x sai" unless w.x == 30
        raise "y sai" unless w.y == 40
        raise "width sai" unless w.width == 320
        raise "height sai" unless w.height == 180
        raise "opacity sai" unless w.opacity == 128
        raise "visible sai" unless w.visible == false
        w.visible = true
        raise "visible set lại sai" unless w.visible == true
        puts "WINDOW_GEOMETRY_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Window built-in geometry sai: \(err)")
    }
}