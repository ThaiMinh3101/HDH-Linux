import XCTest
@testable import RPGPlayer

/// Unit test cho M6.2 — Game_* runtime classes (GameClasses.rb).
///
/// Xác minh logic thuần Ruby (không cần game thật / không cần .rvdata2):
///   1. Tất cả 15 class Game_* được định nghĩa trong mruby VM sau khi load
///      GameClasses.rb (bao gồm class kế thừa Game_Character < Game_CharacterBase).
///   2. Game_Player di chuyển đúng hướng theo Input.dir4 (down/left/right/up).
///   3. Game_Player va chạm với Game_Event (không đi qua event trừ through).
///   4. Game_Map setup từ RPG::Map synthetic + đếm Game_Event.
///   5. Game_Character quay hướng (turn_down/left/right/up) + direction_fix.
///   6. Game_Party add/remove actor + leader + all_dead?.
///   7. Game_Switches/Game_Variables/Game_SelfSwitches get/set.
///
/// CLEAN-ROOM: test dùng chính cơ chế của dự án (RubyBridge + GameClasses.rb)
/// — không tham chiếu engine mã nguồn mở nào.
///
/// LƯU Ý: Chưa test với file .rvdata2 thật (cần game VX Ace trống import qua
/// app). Phần đối chiếu hành vi với game thật là nợ kỹ thuật — sẽ làm khi có
/// game thật (xem Context bổ sung).
final class GameClassesTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng — runTestScript guard mrb == nil).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    // MARK: - 1. Tất cả class Game_* được định nghĩa

    /// Kiểm tra 15 class Game_* (kể cả kế thừa) tồn tại trong VM.
    func testAllGameClassesDefined() {
        let bridge = makeBridge()

        let classChecks: [(path: String, rubyExpr: String)] = [
            // State containers
            ("Game_Temp", "Game_Temp"),
            ("Game_System", "Game_System"),
            ("Game_Switches", "Game_Switches"),
            ("Game_Variables", "Game_Variables"),
            ("Game_SelfSwitches", "Game_SelfSwitches"),
            ("Game_Screen", "Game_Screen"),
            // Character hierarchy
            ("Game_CharacterBase", "Game_CharacterBase"),
            ("Game_Character", "Game_Character"),
            ("Game_Player", "Game_Player"),
            ("Game_Event", "Game_Event"),
            ("Game_Follower", "Game_Follower"),
            ("Game_Vehicle", "Game_Vehicle"),
            // Actor / Party
            ("Game_Actor", "Game_Actor"),
            ("Game_Party", "Game_Party"),
            // Map
            ("Game_Map", "Game_Map"),
        ]

        var script = ""
        for check in classChecks {
            script += "raise \"missing \(check.path)\" unless defined?(\(check.rubyExpr))\n"
        }
        script += "raise \"Game_Character không kế thừa Game_CharacterBase\" unless Game_Character < Game_CharacterBase\n"
        script += "raise \"Game_Player không kế thừa Game_Character\" unless Game_Player < Game_Character\n"
        script += "puts \"ALL_GAME_CLASSES_OK\"\n"

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "GameClasses.rb phải định nghĩa đủ class. Lỗi: \(err)")
    }

    // MARK: - 2. Game_Player di chuyển theo input

    /// Player di chuyển đúng hướng theo Input.dir4 (down/left/right/up).
    /// Dùng map trống (không tileset → passable? trả true).
    func testPlayerMovesByInput() {
        let bridge = makeBridge()
        let script = """
        # Map trống 10x10, không tileset → passable? luôn true
        map = Game_Map.new
        map.width = 10
        map.height = 10
        map.events = {}

        player = Game_Player.new(map)
        player.x = 5
        player.y = 5

        # Mô phỏng Input.dir4 bằng cách set biến global (test không có gamepad)
        # Game_Player.move_by_input đọc Input.dir4 — ta override Input.dir4 tạm thời
        # bằng cách định nghĩa lại module function (mruby cho phép redefine).
        module Input
          def self.dir4
            $__test_dir4
          end
        end

        # Di chuyển xuống (dir4 = 2)
        $__test_dir4 = 2
        player.move_by_input
        raise "down sai" unless player.x == 5 && player.y == 6

        # Di chuyển trái (dir4 = 4)
        $__test_dir4 = 4
        player.move_by_input
        raise "left sai" unless player.x == 4 && player.y == 6

        # Di chuyển phải (dir4 = 6)
        $__test_dir4 = 6
        player.move_by_input
        raise "right sai" unless player.x == 5 && player.y == 6

        # Di chuyển lên (dir4 = 8)
        $__test_dir4 = 8
        player.move_by_input
        raise "up sai" unless player.x == 5 && player.y == 5

        # Không input (dir4 = 0) → không di chuyển
        $__test_dir4 = 0
        player.move_by_input
        raise "no-input sai" unless player.x == 5 && player.y == 5

        puts "PLAYER_MOVE_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Player di chuyển theo input thất bại: \(err)")
    }

    // MARK: - 3. Player va chạm với event

    /// Player không đi qua event (trừ through = true).
    func testPlayerCollidesWithEvent() {
        let bridge = makeBridge()
        let script = """
        # Map trống 10x10
        map = Game_Map.new
        map.width = 10
        map.height = 10

        # Tạo event tại (5, 6) — chặn player đi xuống
        ev = Game_Event.new(RPG::Event.new)
        ev.x = 5
        ev.y = 6
        ev.through = false
        map.events = { 1 => ev }

        player = Game_Player.new(map)
        player.x = 5
        player.y = 5

        # Di chuyển xuống → bị chặn bởi event
        module Input
          def self.dir4
            $__test_dir4
          end
        end
        $__test_dir4 = 2
        player.move_by_input
        raise "phải bị chặn bởi event" unless player.x == 5 && player.y == 5

        # Bật through → đi xuyên qua
        player.through = true
        player.move_by_input
        raise "through phải đi xuyên qua" unless player.x == 5 && player.y == 6

        puts "PLAYER_COLLISION_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Player va chạm event thất bại: \(err)")
    }

    // MARK: - 4. Game_Map setup từ RPG::Map + đếm event

    /// Game_Map.setup tạo Game_Event từ RPG::Map.events (Hash id → RPG::Event).
    func testMapSetupCreatesEvents() {
        let bridge = makeBridge()
        let script = """
        # Tạo RPG::Map synthetic
        m = RPG::Map.new
        m.id = 1
        m.width = 20
        m.height = 15

        # Tạo 2 RPG::Event
        e1 = RPG::Event.new
        e1.id = 1
        e1.x = 3
        e1.y = 4
        e1.pages = []

        e2 = RPG::Event.new
        e2.id = 2
        e2.x = 7
        e2.y = 8
        e2.pages = []

        m.events = { 1 => e1, 2 => e2 }

        # Setup Game_Map
        gm = Game_Map.new
        gm.setup(m, nil)   # không tileset → passable? trả true

        raise "map_id sai" unless gm.map_id == 1
        raise "width sai" unless gm.width == 20
        raise "height sai" unless gm.height == 15
        raise "phải có 2 event" unless gm.events.size == 2
        raise "event 1 sai vị trí" unless gm.events[1].x == 3 && gm.events[1].y == 4
        raise "event 2 sai vị trí" unless gm.events[2].x == 7 && gm.events[2].y == 8
        raise "event phải là Game_Event" unless gm.events[1].is_a?(Game_Event)

        # valid? / passable?
        raise "valid? sai" unless gm.valid?(0, 0)
        raise "valid? ngoài map sai" unless !gm.valid?(20, 15)
        raise "passable? trong map sai" unless gm.passable?(5, 5)

        puts "MAP_SETUP_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Game_Map setup thất bại: \(err)")
    }

    // MARK: - 5. Game_Character quay hướng + direction_fix

    /// Game_Character quay hướng đúng, direction_fix chặn quay.
    func testCharacterTurnAndDirectionFix() {
        let bridge = makeBridge()
        let script = """
        c = Game_Character.new

        # Mặc định hướng xuống (DOWN = 2)
        raise "hướng mặc định sai" unless c.direction == 2

        c.turn_left
        raise "turn_left sai" unless c.direction == 4

        c.turn_right
        raise "turn_right sai" unless c.direction == 6

        c.turn_up
        raise "turn_up sai" unless c.direction == 8

        c.turn_down
        raise "turn_down sai" unless c.direction == 2

        # direction_fix = true → không quay được
        c.direction_fix = true
        c.turn_left
        raise "direction_fix phải chặn quay" unless c.direction == 2

        # move_straight với turn_ok=false không đổi hướng
        c.direction_fix = false
        c.move_straight(4, false)   # di chuyển trái nhưng không quay
        raise "move_straight turn_ok=false phải giữ hướng" unless c.direction == 2
        raise "move_straight trái sai" unless c.x == -1 && c.y == 0

        puts "CHARACTER_TURN_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Game_Character quay hướng thất bại: \(err)")
    }

    // MARK: - 6. Game_Party add/remove actor

    /// Game_Party add/remove actor + leader + all_dead?.
    func testPartyAddRemoveActor() {
        let bridge = makeBridge()
        let script = """
        # Tạo RPG::Actor synthetic
        a1 = RPG::Actor.new
        a1.id = 1
        a1.name = "Harold"
        a1.initial_level = 1

        a2 = RPG::Actor.new
        a2.id = 2
        a2.name = "Therese"
        a2.initial_level = 1

        # Game_Actor wrap
        ga1 = Game_Actor.new(a1)
        ga2 = Game_Actor.new(a2)

        party = Game_Party.new
        raise "party rỗng sai" unless party.actors.empty?

        party.add_actor(ga1)
        party.add_actor(ga2)
        raise "phải có 2 actor" unless party.actors.size == 2
        raise "leader sai" unless party.leader.actor_id == 1

        # add trùng → không thêm lần 2
        party.add_actor(ga1)
        raise "add trùng phải bỏ qua" unless party.actors.size == 2

        # remove
        party.remove_actor(2)
        raise "remove sai" unless party.actors.size == 1
        raise "leader sau remove sai" unless party.leader.actor_id == 1

        # all_dead?
        raise "all_dead? sai (chưa chết)" unless !party.all_dead?
        ga1.hp = 0
        raise "all_dead? sai (đã chết)" unless party.all_dead?

        puts "PARTY_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Game_Party thất bại: \(err)")
    }

    // MARK: - 7. State containers get/set

    /// Game_Switches/Game_Variables/Game_SelfSwitches get/set đúng.
    func testStateContainers() {
        let bridge = makeBridge()
        let script = """
        # Game_Switches — index 1-based, mặc định false
        sw = Game_Switches.new
        raise "switch mặc định sai" unless sw[1] == false
        sw[1] = true
        raise "switch set sai" unless sw[1] == true
        sw[1] = false
        raise "switch reset sai" unless sw[1] == false

        # Game_Variables — index 1-based, mặc định 0
        var = Game_Variables.new
        raise "variable mặc định sai" unless var[1] == 0
        var[1] = 42
        raise "variable set sai" unless var[1] == 42
        var[1] = "99"
        raise "variable to_i sai" unless var[1] == 99

        # Game_SelfSwitches — key "map,event,char"
        ss = Game_SelfSwitches.new
        key = "1,2,A"
        raise "self switch mặc định sai" unless ss[key] == false
        ss[key] = true
        raise "self switch set sai" unless ss[key] == true

        # Game_Temp / Game_System / Game_Screen khởi tạo không lỗi
        temp = Game_Temp.new
        raise "temp map_id sai" unless temp.map_id == 0
        sys = Game_System.new
        raise "system save_count sai" unless sys.save_count == 0
        screen = Game_Screen.new
        raise "screen brightness sai" unless screen.brightness == 255

        puts "STATE_CONTAINERS_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "State containers thất bại: \(err)")
    }
}