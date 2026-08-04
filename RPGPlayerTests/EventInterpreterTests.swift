import XCTest
@testable import RPGPlayer

/// Unit test cho M6.5 — Game_Interpreter (EventInterpreter).
///
/// Xác minh các opcode Batch 1 đã duyệt chạy đúng trên VM mruby:
///   101 Show Text, 102 Show Choices, 111 Conditional Branch (+411/412),
///   121 Control Switches, 122 Control Variables, 123 Control Self Switch,
///   125 Change Gold, 201 Transfer Player, 230 Wait, 113/115/413 Loop/Break,
///   118/119 Label & Jump.
///
/// CLEAN-ROOM: test viết từ RGSS3 Reference Manual (help file công khai đi
/// kèm RPG Maker VX Ace), phần "Event Commands" mô tả opcode + tham số.
/// KHÔNG tham chiếu engine mã nguồn mở GPL/LGPL nào.
///
/// LƯU Ý ESCAPING: script Ruby dùng RAW string `#""" ... """#` trong Swift
/// (backslash là literal, không bị Swift parse). `runtimePrefix` được nối
/// bằng Swift string concatenation (không dùng interpolation — raw string
/// Swift vẫn parse `\(` nếu có, script hiện tại không chứa `\(`).
final class EventInterpreterTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng — runTestScript guard mrb == nil).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    /// Prefix dùng chung: helper tạo RPG::EventCommand + runtime init.
    private let runtimePrefix = #"""
    def cmd(code, indent, *params)
      c = RPG::EventCommand.new
      c.code = code
      c.indent = indent
      c.parameters = params
      c
    end
    rpg_player_setup_runtime
    gi = Game_Interpreter.new
    """#

    // MARK: - 101 Show Text

    /// 101 Gom text vào Game_Message + đẩy vào Window_Message (start_message).
    /// LƯU Ý M6.5: chưa có cơ chế chờ xác nhận → text hiển thị ngay, interpreter
    /// chạy tiếp. Không assert message_waiting (phụ thuộc implementation tương lai).
    func testShowTextPushesAllLinesToMessageAndWindow() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([cmd(101, 0), cmd(401, 1, "Hello world")], 1)
        gi.update
        raise "texts sai: #{$game_message.texts.inspect}" unless $game_message.texts.include?("Hello world")
        win = $game_message_window
        raise "contents_text không chứa text: #{win.contents_text.inspect}" unless win.contents_text.include?("Hello world")
        puts "SHOW_TEXT_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Show Text (101) sai: \(err)")
    }

    // MARK: - 102 Show Choices

    /// 102 Show Choices: chọn index 0 → nhảy đúng block 402.
    /// M6.5: confirm_choice cần Input.trigger?(C) — trong test không có input
    /// thật, ta gọi jump_to_choice trực tiếp để verify nhảy đúng block.
    func testChoicesJumpToSelectedBlock() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(102, 0, ["Attack", "Run"], 0),
          cmd(402, 1, 0),          # choice 0
          cmd(121, 1, 10, 10, 0),  #   switch 10 = ON
          cmd(404, 1),             # end choices
          cmd(402, 1, 1),          # choice 1
          cmd(121, 1, 11, 11, 0),  #   switch 11 = ON
          cmd(404, 1),             # end choices
        ], 1)
        gi.update
        raise "choice_available phải true" unless gi.choice_available
        gi.jump_to_choice(0)
        gi.update
        raise "choice 0: s10 phải ON" unless $game_switches[10] == true
        raise "choice 0: s11 phải OFF" unless $game_switches[11] == false
        puts "CHOICES_JUMP_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Choices jump (102) sai: \(err)")
    }

    /// 102 Show Choices: cancel (B) → nhảy tới 403.
    func testChoicesCancelJumpsToCancelBlock() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(102, 0, ["Attack", "Run"], 1),  # cancel_type = 1 (cho phép cancel)
          cmd(402, 1, 0),
          cmd(121, 1, 10, 10, 0),
          cmd(404, 1),
          cmd(403, 1),              # cancel block
          cmd(121, 1, 12, 12, 0),   #   switch 12 = ON
          cmd(404, 1),
        ], 1)
        gi.update
        gi.jump_to_choice_cancel
        gi.update
        raise "cancel: s12 phải ON" unless $game_switches[12] == true
        raise "cancel: s10 phải OFF" unless $game_switches[10] == false
        puts "CHOICES_CANCEL_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Choices cancel (102) sai: \(err)")
    }

    // MARK: - 111 Conditional Branch

    /// 111 true → chạy nhánh if, bỏ qua else (411).
    func testConditionalBranchTrueRunsThenBlock() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        # Switch 1 ON trước → điều kiện "switch 1 == ON" đúng
        $game_switches[1] = true
        gi.setup([
          cmd(111, 0, 0, 1, 1),     # if switch 1 == ON (value2=1)
          cmd(121, 1, 10, 10, 0),   #   switch 10 = ON
          cmd(411, 1),              # else
          cmd(121, 1, 11, 11, 0),   #   switch 11 = ON
          cmd(412, 0),              # end
        ], 1)
        gi.update
        raise "branch true: s10 phải ON" unless $game_switches[10] == true
        raise "branch true: s11 phải OFF" unless $game_switches[11] == false
        puts "CONDITIONAL_TRUE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Conditional Branch true (111) sai: \(err)")
    }

    /// 111 false → nhảy tới else (411)+1, chạy nhánh else.
    func testConditionalBranchFalseRunsElse() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        $game_switches[1] = false
        gi.setup([
          cmd(111, 0, 0, 1, 1),     # if switch 1 == ON (false)
          cmd(121, 1, 10, 10, 0),   #   switch 10 = ON (bỏ qua)
          cmd(411, 1),              # else
          cmd(121, 1, 11, 11, 0),   #   switch 11 = ON
          cmd(412, 0),              # end
        ], 1)
        gi.update
        raise "branch false: s10 phải OFF" unless $game_switches[10] == false
        raise "branch false: s11 phải ON" unless $game_switches[11] == true
        puts "CONDITIONAL_FALSE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Conditional Branch false (111) sai: \(err)")
    }

    /// 111 variable comparison: var >= n.
    func testConditionalBranchVariableCompare() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        $game_variables[1] = 15
        gi.setup([
          cmd(111, 0, 1, 1, 1, 10),  # if var1 >= 10 (op=1)
          cmd(121, 1, 10, 10, 0),    #   switch 10 = ON
          cmd(412, 0),               # end
        ], 1)
        gi.update
        raise "var cmp: s10 phải ON" unless $game_switches[10] == true
        puts "CONDITIONAL_VAR_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Conditional Branch variable (111) sai: \(err)")
    }

    // MARK: - 121 Control Switches

    /// 121 Control Switches: đặt range switch đúng true/false.
    func testControlSwitchesRange() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([cmd(121, 0, 1, 3, 0)], 1)   # switch 1..3 ON
        gi.update
        raise "s[1] sai: #{$game_switches[1]}" unless $game_switches[1] == true
        raise "s[2] sai: #{$game_switches[2]}" unless $game_switches[2] == true
        raise "s[3] sai: #{$game_switches[3]}" unless $game_switches[3] == true
        raise "s[4] sai: #{$game_switches[4]}" unless $game_switches[4] == false
        gi.setup([cmd(121, 0, 1, 3, 1)], 1)   # switch 1..3 OFF
        gi.update
        raise "s[1] off sai" unless $game_switches[1] == false
        puts "CONTROL_SWITCHES_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Control Switches (121) sai: \(err)")
    }

    // MARK: - 122 Control Variables

    /// 122 Control Variables: operation set/add/sub/mul/div/mod + operand const/var/gold.
    /// params = [start, end, op(0 set,1 add,2 sub,3 mul,4 div,5 mod),
    ///           operand_type(0 const,1 var,2 random,3 game data), operand, operand2]
    func testControlVariablesOperations() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(122, 0, 1, 1, 0, 0, 10),       # var1 = 10 (set const)
          cmd(122, 0, 2, 2, 1, 1, 1, 0),     # var2 = var2 + var1 → 0 + 10 = 10 (add var)
          cmd(122, 0, 3, 3, 3, 0, 2),        # var3 = 0 * 2 → 0 (mul const)
          cmd(122, 0, 4, 4, 4, 0, 25),       # var4 = 0 / 25 → 0 (div const)
          cmd(122, 0, 5, 5, 5, 0, 3),        # var5 = 0 % 3 → 0 (mod const)
        ], 1)
        3.times { gi.update }
        raise "var1 sai: #{$game_variables[1]}" unless $game_variables[1] == 10
        raise "var2 sai: #{$game_variables[2]}" unless $game_variables[2] == 10
        raise "var3 sai: #{$game_variables[3]}" unless $game_variables[3] == 0
        raise "var4 sai: #{$game_variables[4]}" unless $game_variables[4] == 0
        raise "var5 sai: #{$game_variables[5]}" unless $game_variables[5] == 0
        puts "CONTROL_VARIABLES_CONST_OK"

        # Game data gold (type 11)
        $game_party.gold = 100
        gi.setup([cmd(122, 0, 7, 7, 0, 3, 11, 0)], 1)
        gi.update
        raise "var7 (gold) sai: #{$game_variables[7]}" unless $game_variables[7] == 100
        puts "CONTROL_VARIABLES_GOLD_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Control Variables (122) sai: \(err)")
    }

    // MARK: - 123 Control Self Switch

    /// 123 Control Self Switch: bật/tắt key "map_id,event_id,ch".
    /// params = [switch_id("A".."D"), value(0/1)] — dùng 0/1, không dùng "ON"/"OFF".
    func testControlSelfSwitch() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.map_id = 1
        gi.event_id = 5
        gi.setup([cmd(123, 0, "A", 1)], 5)
        gi.update
        raise "self switch A sai" unless $game_self_switches["1,5,A"] == true
        gi.setup([cmd(123, 0, "A", 0)], 5)
        gi.update
        raise "self switch A off sai" unless $game_self_switches["1,5,A"] == false
        puts "CONTROL_SELF_SWITCH_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Control Self Switch (123) sai: \(err)")
    }

    // MARK: - 125 Change Gold

    /// 125 Change Gold: increase/decrease đúng.
    func testChangeGold() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        $game_party.gold = 50
        gi.setup([cmd(125, 0, 0, 100)], 1)   # +100
        gi.update
        raise "gold tăng sai: #{$game_party.gold}" unless $game_party.gold == 150
        gi.setup([cmd(125, 0, 1, 50)], 1)    # -50
        gi.update
        raise "gold giảm sai: #{$game_party.gold}" unless $game_party.gold == 100
        puts "CHANGE_GOLD_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Change Gold (125) sai: \(err)")
    }

    // MARK: - 230 Wait

    /// 230 Wait: wait_count giảm mỗi frame; sau khi wait_count về 0, lệnh kế
    /// tiếp mới chạy ở update sau (đúng hành vi RGSS3 chuẩn).
    func testWaitCountDecrementsAndContinues() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(230, 0, 2),           # Wait 2 frames
          cmd(121, 0, 10, 10, 0),   # switch 10 = ON
        ], 1)
        gi.update
        raise "wait_count chưa giảm: #{gi.wait_count}" unless gi.wait_count == 1
        raise "sw chạy sớm trong wait" unless $game_switches[10] == false
        gi.update
        raise "wait_count phải về 0" unless gi.wait_count == 0
        raise "sw chạy sớm khi wait vừa hết" unless $game_switches[10] == false
        gi.update
        raise "sau wait: switch vẫn OFF" unless $game_switches[10] == true
        raise "interpreter còn chạy (đã hết list)" if gi.running?
        puts "WAIT_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Wait (230) sai: \(err)")
    }

    // MARK: - 201 Transfer Player

    /// 201 Transfer Player (cùng map): cập nhật x/y + hướng; dir=0 giữ hướng.
    func testTransferPlayerSameMap() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        $game_map.map_id = 1
        $game_player.x = 5
        $game_player.y = 6
        $game_player.direction = 2
        gi.setup([cmd(201, 0, 0, 1, 10, 12, 8)], 1)   # dir=8 (lên)
        gi.update
        raise "x sai: #{$game_player.x}" unless $game_player.x == 10
        raise "y sai: #{$game_player.y}" unless $game_player.y == 12
        raise "dir sai: #{$game_player.direction}" unless $game_player.direction == 8

        gi.setup([cmd(201, 0, 0, 1, 3, 4, 0)], 1)     # dir=0 (giữ hướng)
        gi.update
        raise "x2 sai: #{$game_player.x}" unless $game_player.x == 3
        raise "dir2 phải giữ 8: #{$game_player.direction}" unless $game_player.direction == 8
        puts "TRANSFER_PLAYER_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Transfer Player (201) sai: \(err)")
    }

    // MARK: - 113/115/413 Loop & Break

    /// 113 Loop + 115 Break: loop chạy 1 lần, break nhảy ra khỏi loop.
    func testLoopBreak() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(113, 0),              # loop
          cmd(121, 1, 10, 10, 0),   #   switch 10 = ON
          cmd(115, 1),              #   break loop
          cmd(121, 1, 11, 11, 0),   #   switch 11 = ON (bỏ qua — sau break)
          cmd(412, 0),              # end loop
          cmd(121, 0, 12, 12, 0),   # switch 12 = ON (sau loop)
        ], 1)
        gi.update
        raise "loop: s10 phải ON" unless $game_switches[10] == true
        raise "loop: s11 phải OFF (sau break)" unless $game_switches[11] == false
        raise "loop: s12 phải ON (sau loop)" unless $game_switches[12] == true
        puts "LOOP_BREAK_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Loop/Break (113/115) sai: \(err)")
    }

    /// 413 Repeat Loop: quay lại 113 cùng indent — chạy lại body.
    func testLoopRepeat() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(113, 0),              # loop
          cmd(121, 1, 10, 10, 0),   #   switch 10 = ON
          cmd(121, 1, 11, 11, 0),   #   switch 11 = ON
          cmd(413, 1),              #   repeat loop → quay lại 113
          cmd(412, 0),              # end loop (không tới được — repeat vô hạn)
        ], 1)
        # Chỉ chạy 1 frame — repeat sẽ quay lại 113, không crash
        gi.update
        raise "loop repeat: s10 phải ON" unless $game_switches[10] == true
        raise "loop repeat: s11 phải ON" unless $game_switches[11] == true
        puts "LOOP_REPEAT_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Loop Repeat (413) sai: \(err)")
    }

    // MARK: - 119 Jump to Label

    /// 119 Jump to Label: nhảy đúng tới lệnh sau label, bỏ qua block giữa.
    func testJumpToLabelSkipsBlock() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([
          cmd(119, 0, "SKIP"),      # jump SKIP
          cmd(121, 0, 10, 10, 0),   #   switch 10 = ON (bỏ qua)
          cmd(118, 0, "SKIP"),      # label SKIP
          cmd(121, 0, 11, 11, 0),   # switch 11 = ON
        ], 1)
        gi.update
        raise "jump: s10 phải OFF" unless $game_switches[10] == false
        raise "jump: s11 phải ON" unless $game_switches[11] == true
        puts "JUMP_LABEL_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Jump Label (119) sai: \(err)")
    }

    /// 118 Label / 119 Jump: label không có trong list → cảnh báo, không crash.
    /// Interpreter vẫn còn running (list không empty) nhưng index đã hết list.
    func testJumpToMissingLabelDoesNotCrash() {
        let bridge = makeBridge()
        let script = runtimePrefix + #"""
        gi.setup([cmd(119, 0, "NOT_EXIST")], 1)
        gi.update
        raise "index phải hết list: #{gi.index}" unless gi.index >= gi.list.size
        puts "JUMP_MISSING_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Jump Label missing sai: \(err)")
    }
}