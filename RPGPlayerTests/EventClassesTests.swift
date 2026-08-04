import XCTest
@testable import RPGPlayer

/// Unit test cho M6.5 — Event command system (EventClasses.rb).
///
/// Xác minh logic thuần Ruby (không cần game thật / không cần .rvdata2):
///   1. rpg_player_bootstrap parse boot JSON (Ruby Hash literal — mruby build
///      không có mruby-json mgem nên dùng eval) → globals + event lists.
///   2. Game_Interpreter chạy 101 Show Text + 401 text lines → Game_Message,
///      chặn tiến interpreter cho tới khi message được clear.
///   3. 111 Conditional Branch (switch) — nhánh true chạy body.
///   4. 111 Conditional Branch (switch) — nhánh false nhảy tới Else/End.
///   5. 122 Control Variables — set/add/mul + operand const/var/random.
///   6. 201 Transfer Player — moveto + $rpg_player_transfer + direction.
///   7. 230 Wait — chặn advance đúng số frame.
///   8. Opcode chưa hỗ trợ (355 Script) → record vào $rpg_player_unsupported.
///
/// CLEAN-ROOM: test dùng chính cơ chế của dự án (RubyBridge + EventClasses.rb)
/// — không tham chiếu engine mã nguồn mở nào.
///
/// LƯU Ý: Chưa test với file .rvdata2 thật (cần game VX Ace trống import qua
/// app). Phần đối chiếu hành vi với game thật là nợ kỹ thuật — sẽ làm khi có
/// game thật (xem Context bổ sung).
final class EventClassesTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng — runTestScript guard mrb == nil).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    /// Chạy `rpg_player_bootstrap` với boot JSON payload.
    /// Boot JSON là Ruby Hash literal (KHÔNG phải JSON — mruby không có json).
    private func bootstrapScript(bootJSON: String, extra: String = "") -> String {
        """
        $rpg_player_boot_json = #{bootJSON}
        rpg_player_bootstrap
        raise "bootstrap lỗi: #{$rpg_player_event_setup_error}" unless $rpg_player_event_setup_error.nil?
        \(extra)
        """
    }

    // MARK: - 1. Bootstrap parse boot JSON

    /// rpg_player_bootstrap tạo globals + đọc map_id/x/y/events từ boot string.
    func testBootstrapParsesBootJSON() {
        let bridge = makeBridge()
        let script = bootstrapScript(
            bootJSON: #""{ \"map_id\" => 5, \"x\" => 3, \"y\" => 4, \"events\" => { \"1\" => { \"events\" => [ [101, 0, []], [401, 0, [\"Hi\"]] ] } } }""#,
            extra: """
            raise "map_id sai" unless $rpg_player_map_id == 5
            raise "player pos sai" unless $game_player.x == 3 && $game_player.y == 4
            raise "event lists thiếu map 1" unless $rpg_player_event_lists.is_a?(Hash) && $rpg_player_event_lists["1"].is_a?(Array)
            raise "event list size sai" unless $rpg_player_event_lists["1"].size == 2
            raise "phải có interpreter" unless $game_interpreter.is_a?(Game_Interpreter)
            raise "phải có message" unless $game_message.is_a?(Game_Message)
            raise "phải có switches" unless $game_switches.is_a?(Game_Switches)
            puts "BOOTSTRAP_OK"
            """
        )
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Bootstrap thất bại: \(err)")
    }

    // MARK: - 2. 101 Show Text

    /// 101 + 401 feed Game_Message + chặn tiến interpreter tới khi clear.
    func testShowTextFeedsMessageAndWaits() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap
        # Cần Window_Message cho feed (M6.4 — test path: 4 args bắt buộc)
        $game_win_message = Window_Message.new(40, 200, 400, 100)

        interp = $game_interpreter
        list = [
          [101, 0, []],
          [401, 0, ["Hello"]],
          [401, 0, ["World"]],
          [121, 0, [1, 1, 1]]
        ]
        interp.setup(list, 1)
        interp.update

        raise "texts sai" unless $game_message.texts == ["Hello", "World"]
        raise "message_waiting phải true" unless interp.message_waiting
        raise "visible_message? phải true" unless $game_message.visible_message?

        # Chưa clear message → update tiếp theo không advance tới 121
        interp.update
        raise "switch phải chưa ON (message đang chặn)" unless $game_switches[1] == false

        # Clear message → interpreter tiếp tục tới 121
        $game_message.texts = []
        interp.update
        raise "switch phải ON sau clear message" unless $game_switches[1] == true

        puts "SHOW_TEXT_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Show Text thất bại: \(err)")
    }

    // MARK: - 3. 111 Conditional Branch — nhánh true

    /// Switch 1 ON → chạy body (set switch 2), bỏ qua else (switch 3 không set).
    func testConditionalBranchTrueExecutesBody() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap
        $game_switches[1] = true

        interp = $game_interpreter
        list = [
          [111, 0, [0, 1, 1]],   # Switch 1 == ON?
          [121, 0, [2, 2, 1]],   #   → set switch 2 ON
          [411, 0, []],          # Else
          [121, 0, [3, 3, 1]],   #   → set switch 3 ON
          [412, 0, []]
        ]
        interp.setup(list, 1)
        interp.update

        raise "body phải chạy" unless $game_switches[2] == true
        raise "else phải bỏ qua" unless $game_switches[3] == false

        puts "BRANCH_TRUE_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Conditional Branch true thất bại: \(err)")
    }

    // MARK: - 4. 111 Conditional Branch — nhánh false

    /// Switch 1 OFF (mặc định) + hỏi "ON?" → false → nhảy tới Else.
    func testConditionalBranchFalseSkipsToElse() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap

        interp = $game_interpreter
        list = [
          [111, 0, [0, 1, 1]],   # Switch 1 == ON? (sai — switch 1 đang OFF)
          [121, 0, [2, 2, 1]],   #   body if (không chạy)
          [411, 0, []],          # Else
          [121, 0, [3, 3, 1]],   #   body else (chạy)
          [412, 0, []]
        ]
        interp.setup(list, 1)
        interp.update

        raise "body if phải bỏ qua" unless $game_switches[2] == false
        raise "body else phải chạy" unless $game_switches[3] == true

        puts "BRANCH_FALSE_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Conditional Branch false thất bại: \(err)")
    }

    // MARK: - 5. 122 Control Variables

    /// Control Variables: set/add/mul, operand const + variable.
    func testControlVariablesOperators() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap

        interp = $game_interpreter

        # 122: [start, end, op, operand_type, operand, operand2]
        # op 0 = set, 1 = add, 3 = mul; operand_type 0 = const, 1 = variable
        list_set = [[122, 0, [1, 1, 0, 0, 100, 0]]]
        interp.setup(list_set, 1)
        interp.update
        raise "set sai" unless $game_variables[1] == 100

        list_add = [[122, 0, [1, 1, 1, 0, 5, 0]]]
        interp.setup(list_add, 1)
        interp.update
        raise "add sai" unless $game_variables[1] == 105

        # operand type 1 = lấy giá trị variable 2 (đang 0)
        $game_variables[2] = 3
        list_mul = [[122, 0, [1, 1, 3, 1, 2, 0]]]
        interp.setup(list_mul, 1)
        interp.update
        raise "mul variable operand sai" unless $game_variables[1] == 105 * 3

        # random operand (type 2): lo=10, hi=10 → luôn 10
        list_rand = [[122, 0, [7, 7, 0, 2, 10, 10]]]
        interp.setup(list_rand, 1)
        interp.update
        raise "random operand sai" unless $game_variables[7] == 10

        puts "VARIABLES_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Control Variables thất bại: \(err)")
    }

    // MARK: - 6. 201 Transfer Player

    /// Transfer Player: moveto + $rpg_player_transfer + direction.
    func testTransferPlayerSetsPosition() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap

        interp = $game_interpreter
        list = [[201, 0, [1, 3, 4, 5, 2, 0]]]
        interp.setup(list, 1)
        interp.update

        raise "transfer map_id sai" unless $rpg_player_transfer[:map_id] == 3
        raise "player x sai" unless $game_player.x == 4
        raise "player y sai" unless $game_player.y == 5
        raise "direction sai" unless $game_player.direction == 2

        puts "TRANSFER_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Transfer Player thất bại: \(err)")
    }

    // MARK: - 7. 230 Wait

    /// Wait chặn advance đúng số frame rồi tiếp tục.
    func testWaitBlocksAdvance() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap

        interp = $game_interpreter
        list = [[230, 0, [3]], [121, 0, [1, 1, 1]]]
        interp.setup(list, 1)

        interp.update   # set wait_count = 3
        raise "wait_count sai" unless interp.wait_count == 3
        raise "switch chưa được set" unless $game_switches[1] == false

        interp.update   # 3 → 2
        interp.update   # 2 → 1
        raise "wait giảm sai" unless interp.wait_count == 1

        interp.update   # 1 → 0 → chạy tiếp 121
        raise "switch phải ON sau wait" unless $game_switches[1] == true

        puts "WAIT_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Wait thất bại: \(err)")
    }

    // MARK: - 8. Unsupported opcodes

    /// Opcode chưa hỗ trợ (355 Script) được record — không crash.
    func testUnsupportedOpcodeRecorded() {
        let bridge = makeBridge()
        let script = """
        $rpg_player_boot_json = "{ \\"events\\" => {} }"
        rpg_player_bootstrap

        interp = $game_interpreter
        list = [[355, 0, ["puts 1"]]]
        interp.setup(list, 1)
        interp.update

        raise "355 phải được record unsupported" unless $rpg_player_unsupported.include?(355)

        puts "UNSUPPORTED_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Unsupported opcode thất bại: \(err)")
    }
}
</｜｜DSML｜｜>
</｜｜DSML｜｜>