import XCTest
@testable import RPGPlayer

/// Unit test cho M7 — Battle runtime classes (BattleClasses.rb).
///
/// Xác minh skeleton battle classes load được trên VM mruby:
///   Color, Game_BattlerBase/Battler, Game_ActionResult, Game_Enemy,
///   Game_Troop, Game_Action, BattleManager, SceneManager, Scene_Battle,
///   Window_BattleLog, Window_BattleItem + $game_troop/$data_* globals.
///
/// CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
/// RPG Maker VX Ace). KHÔNG tham chiếu engine mã nguồn mở GPL/LGPL nào.
final class BattleClassesTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    // MARK: - Color (RGSS built-in, M7)

    /// Color.new + accessors + set + ==.
    func testColorClass() {
        let bridge = makeBridge()
        let script = #"""
        c = Color.new(132, 170, 255)
        raise "red sai: #{c.red}" unless c.red == 132
        raise "green sai: #{c.green}" unless c.green == 170
        raise "blue sai: #{c.blue}" unless c.blue == 255
        raise "alpha mặc định sai: #{c.alpha}" unless c.alpha == 255
        c.set(10, 20, 30, 40)
        raise "set red sai: #{c.red}" unless c.red == 10
        raise "set alpha sai: #{c.alpha}" unless c.alpha == 40
        d = Color.new(10, 20, 30, 40)
        raise "== sai" unless c == d
        d.blue = 31
        raise "== sai (khác blue)" if c == d
        puts "COLOR_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Color class sai: \(err)")
    }

    // MARK: - Runtime setup ($game_troop + $data_*)

    /// rpg_player_setup_runtime tạo $game_troop + $data_* globals.
    func testRuntimeSetupCreatesTroopAndDataGlobals() {
        let bridge = makeBridge()
        let script = #"""
        rpg_player_setup_runtime
        raise "game_troop nil" unless $game_troop
        raise "data_states nil" if $data_states.nil?
        raise "data_skills nil" if $data_skills.nil?
        raise "data_states[1] phải nil (chưa load)" unless $data_states[1].nil?
        puts "RUNTIME_SETUP_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Runtime setup battle globals sai: \(err)")
    }

    // MARK: - Game_Battler skeleton

    /// Game_Battler.new + ATB skeleton (ap, make_start_ap, frame_update, ap_rate).
    func testGameBattlerSkeleton() {
        let bridge = makeBridge()
        let script = #"""
        rpg_player_setup_runtime
        # ATB::MAX_AP chưa có (script 147 định nghĩa) — dùng constant test
        module ATB
          MAX_AP = 4000
          FRAME_AP_GAIN = 10
          GAUGE_GAIN_MIN = 5
          REFRESH_FRAME = 3
          START_AP_RATE_NORMAL = [30, 40]
          START_AP_RATE_PREEMPTIVE = [40, 30]
          START_AP_RATE_SURPRISE = [0, 10]
          ESCAPE_FAILED_AP_RATE = [0, 10]
        end
        b = Game_Battler.new
        raise "ap phải 0" unless b.ap == 0
        b.make_start_ap(0)
        raise "ap sau make_start_ap phải > 0: #{b.ap}" unless b.ap > 0
        b.ap_rate
        b.frame_update
        raise "ap phải tăng sau frame_update" unless b.ap > 0
        b.ap_reduce
        b.ap_cancel_reduce
        puts "BATTLER_SKELETON_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Game_Battler skeleton sai: \(err)")
    }

    // MARK: - BattleManager skeleton

    /// BattleManager.make_action_orders không crash khi chưa có battler.
    func testBattleManagerSkeleton() {
        let bridge = makeBridge()
        let script = #"""
        rpg_player_setup_runtime
        module ATB
          MAX_AP = 4000
        end
        orders = BattleManager.make_action_orders
        raise "orders phải empty array" unless orders == []
        raise "action_battler phải nil" unless BattleManager.action_battler.nil?
        puts "BATTLE_MANAGER_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "BattleManager skeleton sai: \(err)")
    }

    // MARK: - Marshal.dump clone array (ATB pattern)

    /// Script ATB dùng Marshal.load(Marshal.dump(array)) để clone — verify
    /// Marshal.dump hỗ trợ Array round-trip.
    func testMarshalDumpCloneArray() {
        let bridge = makeBridge()
        let script = #"""
        src = [30, 40]
        cloned = Marshal.load(Marshal.dump(src))
        raise "clone sai: #{cloned.inspect}" unless cloned == [30, 40]
        src[0] = 99
        raise "clone phải độc lập" unless cloned[0] == 30
        puts "MARSHAL_CLONE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Marshal.dump clone array sai: \(err)")
    }

    // MARK: - Scene/Window battle classes load

    /// Scene_Battle + Window_BattleLog + Window_BattleItem tồn tại (load không crash).
    func testBattleSceneClassesLoad() {
        let bridge = makeBridge()
        let script = #"""
        rpg_player_setup_runtime
        s = Scene_Battle.new
        raise "Scene_Battle không tạo được" unless s.is_a?(Scene_Battle)
        w = Window_BattleLog.new
        w.add_text("Test")
        raise "line_number sai: #{w.line_number}" unless w.line_number == 1
        w.wait_and_clear
        raise "clear sai" unless w.line_number == 0
        puts "BATTLE_SCENE_OK"
        """#
        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Battle scene classes sai: \(err)")
    }
}