# RPGPlayer/Resources/GameClasses.rb
# M6.2 — Game_* runtime classes cho RPG Maker VX Ace (RGSS3).
#
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
# RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
# mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).
#
# Khác với RPGClasses.rb (M6.1 — data classes load từ file .rvdata2), các
# class Game_* ở đây là RUNTIME objects: được khởi tạo khi bắt đầu game hoặc
# load save, dùng dữ liệu RPG::* làm nguồn tham chiếu tĩnh.
#
# PHẠM VI M6.2 (bản tối thiểu):
#   - Game_Map: setup từ RPG::Map, quản lý Game_Event, passable?/collision
#     cơ bản dựa trên RPG::Tileset.flags.
#   - Game_Player: move_by_input dùng Input.dir4/dir8 (đã có từ M2), va chạm
#     với event qua Game_Map.passable?.
#   - Game_CharacterBase/Game_Character: di chuyển, quay hướng, move_route.
#   - Game_Event: dùng RPG::Event::Page, move_route, trigger (tối thiểu).
#   - Game_Follower/Game_Vehicle: đi theo player / phương tiện.
#   - Game_Actor/Game_Party: wrap RPG::Actor, quản lý party.
#   - State containers: Game_Temp, Game_System, Game_Switches, Game_Variables,
#     Game_SelfSwitches, Game_Screen.
#
# Load qua mrb_load_nstring() sau RPGClasses.rb, trước Scripts.rvdata2.

# ─────────────────────────────────────────────────────────────────────────────
# State containers
# ─────────────────────────────────────────────────────────────────────────────

# Game_Temp — biến tạm thời, reset mỗi lần vào game mới.
class Game_Temp
  attr_accessor :map_id
  attr_accessor :common_event_id
  attr_accessor :in_battle
  attr_accessor :next_scene
  attr_accessor :menu_calling
  attr_accessor :menu_beep
  attr_accessor :save_calling
  attr_accessor :debug_calling
  attr_accessor :transition_processing
  attr_accessor :transition_name

  def initialize
    @map_id = 0
    @common_event_id = 0
    @in_battle = false
    @next_scene = nil
    @menu_calling = false
    @menu_beep = false
    @save_calling = false
    @debug_calling = false
    @transition_processing = false
    @transition_name = ""
  end
end

# Game_System — trạng thái hệ thống (save/menu/encounter disabled, ...).
class Game_System
  attr_accessor :save_disabled
  attr_accessor :menu_disabled
  attr_accessor :encounter_disabled
  attr_accessor :save_count
  attr_accessor :version_id
  attr_accessor :battle_count
  attr_accessor :playtime
  attr_accessor :playtime_s
  attr_accessor :savefile_index

  def initialize
    @save_disabled = false
    @menu_disabled = false
    @encounter_disabled = false
    @save_count = 0
    @version_id = 0
    @battle_count = 0
    @playtime = 0
    @playtime_s = 0
    @savefile_index = 0
  end
end

# Game_Switches — mảng switch (index 1-based, giống RGSS).
class Game_Switches
  def initialize
    @data = []
  end

  def [](switch_id)
    @data[switch_id] || false
  end

  def []=(switch_id, value)
    @data[switch_id] = value ? true : false
  end
end

# Game_Variables — mảng variable (index 1-based).
class Game_Variables
  def initialize
    @data = []
  end

  def [](variable_id)
    @data[variable_id] || 0
  end

  def []=(variable_id, value)
    @data[variable_id] = value.to_i
  end
end

# Game_SelfSwitches — hash self switch, key "map_id,event_id,switch_char".
class Game_SelfSwitches
  def initialize
    @data = {}
  end

  def [](key)
    @data[key] || false
  end

  def []=(key, value)
    @data[key] = value ? true : false
  end
end

# Game_Screen — hiệu ứng màn hình (flash/tone) — bản tối thiểu M6.2.
class Game_Screen
  attr_accessor :brightness
  attr_accessor :tone
  attr_accessor :flash_color
  attr_accessor :flash_duration

  def initialize
    @brightness = 255
    @tone = [0, 0, 0, 0]
    @flash_color = [255, 255, 255, 0]
    @flash_duration = 0
  end

  def start_flash(color, duration)
    @flash_color = color.dup
    @flash_duration = duration
  end

  def update
    @flash_duration -= 1 if @flash_duration > 0
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_CharacterBase — nền tảng di chuyển chung (player, event, follower, vehicle)
# ─────────────────────────────────────────────────────────────────────────────

class Game_CharacterBase
  attr_accessor :x
  attr_accessor :y
  attr_accessor :real_x
  attr_accessor :real_y
  attr_accessor :direction
  attr_accessor :pattern
  attr_accessor :move_speed
  attr_accessor :move_frequency
  attr_accessor :through
  attr_accessor :priority_type
  attr_accessor :walk_anime
  attr_accessor :step_anime
  attr_accessor :direction_fix
  attr_accessor :opacity
  attr_accessor :blend_type
  attr_accessor :bush_depth

  # Hằng số hướng (RGSS3: 2=down, 4=left, 6=right, 8=up)
  DOWN  = 2
  LEFT  = 4
  RIGHT = 6
  UP    = 8

  def initialize
    @x = 0
    @y = 0
    @real_x = 0
    @real_y = 0
    @direction = DOWN
    @pattern = 0
    @move_speed = 4
    @move_frequency = 6
    @through = false
    @priority_type = 1
    @walk_anime = true
    @step_anime = false
    @direction_fix = false
    @opacity = 255
    @blend_type = 0
    @bush_depth = 0
  end

  # Toạ độ pixel (RGSS: tile 32px, real = x * 32)
  def screen_x
    @real_x * 32
  end

  def screen_y
    @real_y * 32
  end

  # Quay hướng (không di chuyển)
  def turn_down
    @direction = DOWN unless @direction_fix
  end

  def turn_left
    @direction = LEFT unless @direction_fix
  end

  def turn_right
    @direction = RIGHT unless @direction_fix
  end

  def turn_up
    @direction = UP unless @direction_fix
  end

  # Di chuyển 1 tile theo hướng hiện tại (nếu passable)
  def move_straight(dir, turn_ok = true)
    @direction = dir if turn_ok && !@direction_fix
    new_x = @x + (dir == RIGHT ? 1 : (dir == LEFT ? -1 : 0))
    new_y = @y + (dir == DOWN  ? 1 : (dir == UP   ? -1 : 0))
    if passable?(new_x, new_y)
      @x = new_x
      @y = new_y
      @real_x = @x
      @real_y = @y
      @pattern = (@pattern + 1) % 4 if @walk_anime
      true
    else
      false
    end
  end

  # Kiểm tra có thể đi qua tile (x, y) — override ở Game_Player/Game_Event
  def passable?(x, y)
    true
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Character — thêm move_route, jump (dùng cho event, follower, vehicle)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Character < Game_CharacterBase
  attr_accessor :move_route
  attr_accessor :move_route_index
  attr_accessor :move_route_forcing
  attr_accessor :wait_count

  def initialize
    super
    @move_route = nil
    @move_route_index = 0
    @move_route_forcing = false
    @wait_count = 0
  end

  # Nhảy tới (x, y) — bỏ qua va chạm
  def jump(x_plus, y_plus)
    @x += x_plus
    @y += y_plus
    @real_x = @x
    @real_y = @y
  end

  # Thực thi move_route hiện tại (bản tối thiểu: chỉ xử lý lệnh di chuyển
  # thẳng + quay hướng + wait; các lệnh khác bỏ qua an toàn).
  def update_move_route
    return unless @move_route
    return if @move_route_index >= @move_route.list.size

    cmd = @move_route.list[@move_route_index]
    case cmd.code
    when 1   # Move Down
      move_straight(DOWN)
    when 2   # Move Left
      move_straight(LEFT)
    when 3   # Move Right
      move_straight(RIGHT)
    when 4   # Move Up
      move_straight(UP)
    when 5   # Move Lower Left
      move_straight(LEFT); move_straight(DOWN)
    when 6   # Move Lower Right
      move_straight(RIGHT); move_straight(DOWN)
    when 7   # Move Upper Left
      move_straight(LEFT); move_straight(UP)
    when 8   # Move Upper Right
      move_straight(RIGHT); move_straight(UP)
    when 9   # Move Random
      move_straight([DOWN, LEFT, RIGHT, UP].sample)
    when 10  # Move Toward Player
      # Bản tối thiểu: không có tham chiếu player — bỏ qua
    when 11  # Move Away from Player
      # Bản tối thiểu: bỏ qua
    when 12  # Move Forward
      move_straight(@direction)
    when 13  # Move Backward
      move_straight(opposite_direction(@direction))
    when 14  # Jump
      move_straight(@direction)
    when 15  # Wait
      @wait_count = (cmd.parameters[0] || 0)
    when 16  # Turn Down
      turn_down
    when 17  # Turn Left
      turn_left
    when 18  # Turn Right
      turn_right
    when 19  # Turn Up
      turn_up
    when 20  # Turn 90° Right
      turn_right
    when 21  # Turn 90° Left
      turn_left
    when 22  # Turn 180°
      turn_down
    when 23  # Turn 90° Right/Left Random
      rand(2) == 0 ? turn_right : turn_left
    when 24  # Turn Random
      [DOWN, LEFT, RIGHT, UP].sample.tap { |d| @direction = d unless @direction_fix }
    when 25  # Turn Toward Player
      # Bản tối thiểu: bỏ qua
    when 26  # Turn Away from Player
      # Bản tối thiểu: bỏ qua
    when 27  # Switch ON
      # Bản tối thiểu: bỏ qua (cần Game_Switches)
    when 28  # Switch OFF
      # Bản tối thiểu: bỏ qua
    when 29  # Change Speed
      @move_speed = cmd.parameters[0] if cmd.parameters[0]
    when 30  # Change Frequency
      @move_frequency = cmd.parameters[0] if cmd.parameters[0]
    when 31  # Walk Animation ON
      @walk_anime = true
    when 32  # Walk Animation OFF
      @walk_anime = false
    when 33  # Step Animation ON
      @step_anime = true
    when 34  # Step Animation OFF
      @step_anime = false
    when 35  # Direction Fix ON
      @direction_fix = true
    when 36  # Direction Fix OFF
      @direction_fix = false
    when 37  # Through ON
      @through = true
    when 38  # Through OFF
      @through = false
    when 39  # Always on Top ON
      @priority_type = 2
    when 40  # Always on Top OFF
      @priority_type = 1
    when 41  # Change Graphic
      # Bản tối thiểu: bỏ qua (cần Bitmap/character graphic)
    when 42  # Change Opacity
      @opacity = cmd.parameters[0] if cmd.parameters[0]
    when 43  # Change Blending
      @blend_type = cmd.parameters[0] if cmd.parameters[0]
    when 44  # Play SE
      # Bản tối thiểu: bỏ qua (chưa có audio)
    when 45  # Script
      # Bản tối thiểu: bỏ qua (chưa có eval an toàn)
    end

    @move_route_index += 1
  end

  def opposite_direction(dir)
    case dir
    when DOWN  then UP
    when LEFT  then RIGHT
    when RIGHT then LEFT
    when UP    then DOWN
    else dir
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Map — quản lý map hiện tại, event, collision
# ─────────────────────────────────────────────────────────────────────────────

 class Game_Map
   attr_accessor :map_id
   attr_accessor :width
   attr_accessor :height
   attr_accessor :events
   attr_accessor :tileset
   attr_accessor :map_data
   attr_accessor :display_x
   attr_accessor :display_y
   # M6.5: tham chiếu player + interpreter event (RGSS3: Game_Map quản lý
   # 1 interpreter cho event actions).
   attr_accessor :player
   attr_accessor :interpreter
   attr_accessor :starting_pos
   attr_accessor :common_events

   # Hằng số flag tileset (RGSS3: bit 0 = impassable, bit 1 = bush, ...)
   FLAG_IMPASSABLE = 0x01

   def initialize
     @map_id = 0
     @width = 0
     @height = 0
     @events = {}
     @tileset = nil
     @map_data = nil
     @display_x = 0
     @display_y = 0
     @player = nil
     @interpreter = nil
     @starting_pos = nil
     @common_events = {}
   end

   # Setup map từ RPG::Map + RPG::Tileset (bản tối thiểu M6.2).
   # - map: RPG::Map (đã load từ MapXXX.rvdata2)
   # - tileset: RPG::Tileset (đã load từ Tilesets.rvdata2)
   # - map_id: ID map (từ tên file MapXXX.rvdata2 — RGSS3: RPG::Map không
   #   chứa field id, map_id được truyền từ ngoài runtime)
   def setup(map, tileset, map_id = 0)
     @map_id = map_id
     @width = map.width
     @height = map.height
     @tileset = tileset
     # M6.3: Lưu RPG::Map.data (Table 3D [width][height][4]) — dùng cho
     # passable? và tilemap rendering. Guard: map.data có thể nil nếu map
     # chưa được load đầy đủ (test dùng RPG::Map.new trần).
     @map_data = map.respond_to?(:data) ? map.data : nil
     @events = {}
     # Guard: RPG::Map.events có thể nil nếu map chưa được load đầy đủ
     # (test dùng RPG::Map.new trần). Bản tối thiểu M6.2 — bỏ qua an toàn.
     events = map.respond_to?(:events) ? map.events : nil
     if events
       events.each do |id, event_data|
         @events[id] = Game_Event.new(event_data)
       end
     end
   end

   # Kiểm tra tile (x, y) có nằm trong map không
   def valid?(x, y)
     x >= 0 && x < @width && y >= 0 && y < @height
   end

   # Kiểm tra có thể đi qua tile (x, y) — dựa trên tileset flags.
   # M6.3: đọc RPG::Map.data (Table 3D) qua class Table — duyệt 4 layer
   # từ dưới lên, tile đầu tiên khác 0 quyết định passable.
   #   - Tile ID 0 (trống) → tiếp tục layer trên
   #   - Tile ID != 0 → check tileset.flags[tile_id] & FLAG_IMPASSABLE
   # Nếu không có tileset hoặc map_data → cho đi qua (map trống test).
   def passable?(x, y)
     return false unless valid?(x, y)
     return true unless @tileset && @map_data

     (0..3).each do |layer|
       tile_id = @map_data[x, y, layer]
       next if tile_id == 0
       flag = @tileset.flags[tile_id]
       return false if flag & FLAG_IMPASSABLE != 0
     end
     true
   end

  # Có event tại (x, y) không (dùng cho va chạm player)
  def event_at?(x, y)
    @events.any? { |_id, ev| ev.x == x && ev.y == y && !ev.through }
  end

  def update
    @events.each_value(&:update)
    setup_starting_event
  end

  # ── M6.5: vị trí bắt đầu player trong map (từ RPG::System hoặc test) ──
  def setup_player_start
    return unless @player
    return unless @starting_pos
    @player.x = @starting_pos[0]
    @player.y = @starting_pos[1]
    @player.real_x = @starting_pos[0]
    @player.real_y = @starting_pos[1]
    if @starting_pos.size > 2 && @starting_pos[2].to_i != 0
      @player.direction = @starting_pos[2].to_i
    end
    @starting_pos = nil
  end

  # ── M6.5: event at same tile as player (touch trigger) ──
  def check_event_trigger_here(triggers)
    return unless @player
    return [] unless triggers
    @events.each_value.map do |event|
      next unless active_event?(event, triggers)
      next unless event.x == @player.x && event.y == @player.y
      event.starting = true
      event
    end.compact
  end

  # ── M6.5: event tại ô player đang đối diện (action button trigger) ──
  def check_event_trigger_there(triggers)
    return unless @player
    return [] unless triggers
    dx = 0
    dy = 0
    case @player.direction
    when 2 then dy = 1   # DOWN
    when 4 then dx = -1  # LEFT
    when 6 then dx = 1   # RIGHT
    when 8 then dy = -1  # UP
    end
    @events.each_value.map do |event|
      next unless active_event?(event, triggers)
      next unless event.x == @player.x + dx && event.y == @player.y + dy
      event.starting = true
      event
    end.compact
  end

  def active_event?(event, triggers)
    return false if event.erased
    return false if event.through
    # Chỉ kích hoạt event có page đang active (page_index != -1)
    return false if event.page_index < 0
    triggers.include?(event.trigger)
  end

  # ── M6.5: chạy interpreter cho event starting đầu tiên ──
  def setup_starting_event
    return unless @interpreter
    return if @interpreter.running?
    @events.each_value do |event|
      next unless event.starting
      @interpreter.setup(event.list, event.event_id)
      @interpreter.map_id = @map_id
      event.starting = false
      return
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Player — nhân vật người chơi, di chuyển theo input
# ─────────────────────────────────────────────────────────────────────────────

class Game_Player < Game_Character
  attr_accessor :map
  attr_accessor :vehicle

  def initialize(map)
    super()
    @map = map
    @vehicle = nil
    @move_speed = 4
  end

  # Di chuyển theo input (gọi mỗi frame từ advanceFrame).
  # Dùng Input.dir4 (đã có từ M2) — ưu tiên hướng chính, không diagonal.
  def move_by_input
    dir = Input.dir4
    case dir
    when DOWN  then move_straight(DOWN)
    when LEFT  then move_straight(LEFT)
    when RIGHT then move_straight(RIGHT)
    when UP    then move_straight(UP)
    end
  end

  # Override passable? — player không đi qua event (trừ through)
  def passable?(x, y)
    return true if @through
    return false unless @map
    return false if @map.event_at?(x, y)
    @map.passable?(x, y)
  end

  def update
    move_by_input
    check_event_trigger_touch([1, 2])
    check_action_event
  end

  # ── M6.5: touch trigger (event cùng ô khi player bước vào) ──
  def check_event_trigger_touch(triggers)
    return if $game_map.nil?
    $game_map.check_event_trigger_here(triggers)
  end

  # ── M6.5: action button (nhấn C — RGSS Input::C = confirm) ──
  def check_action_event
    return if $game_map.nil?
    return unless Input.trigger?(Input::C)
    $game_map.check_event_trigger_here([2])
    $game_map.check_event_trigger_there([0, 1, 2])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Event — sự kiện trên map (bản tối thiểu M6.2)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Event < Game_Character
  attr_accessor :event_id
  attr_accessor :trigger
  attr_accessor :list
  attr_accessor :starting
  attr_accessor :page_index
  attr_accessor :erased
  attr_accessor :event_data

  def initialize(event_data)
    super()
    @event_data = event_data
    @event_id = event_data.id
    @x = event_data.x
    @y = event_data.y
    @starting = false
    @erased = false
    @page_index = -1
    @trigger = 0
    @list = []
    refresh
  end

  # ── M6.5: chọn page hoạt động (page cuối có điều kiện thoả — RGSS3) ──
  def refresh
    pages = @event_data.respond_to?(:pages) ? @event_data.pages : nil
    new_index = -1
    if pages && !@erased
      pages.each_with_index do |page, i|
        new_index = i if page_condition_met?(page)
      end
    end
    @page_index = new_index
    if @page_index >= 0
      page = pages[@page_index]
      @trigger = page.trigger
      @list = page.list
      @move_speed = page.move_speed
      @move_frequency = page.move_frequency
      @through = page.through
      @priority_type = page.priority_type
      @walk_anime = page.walk_anime
      @step_anime = page.step_anime
      @direction_fix = page.direction_fix
      @move_route = page.move_route
      if @move_route
        @move_route_index = 0
      end
    else
      @trigger = 0
      @list = []
    end
  end

  # ── M6.5: điều kiện page (2 switch + 1 variable + self switch — RGSS3) ──
  def page_condition_met?(page)
    cond = page.condition
    return true unless cond
    if cond.switch1_valid
      return false unless $game_switches && $game_switches[cond.switch1_id]
    end
    if cond.switch2_valid
      return false unless $game_switches && $game_switches[cond.switch2_id]
    end
    if cond.variable_valid
      return false unless $game_variables
      actual = $game_variables[cond.variable_id]
      want = cond.variable_value
      comparison = cond.respond_to?(:variable_compare) ? cond.variable_compare : nil
      if comparison
        case comparison
        when 1 then return false unless actual != want
        when 2 then return false unless actual >= want
        when 3 then return false unless actual <= want
        when 4 then return false unless actual > want
        when 5 then return false unless actual < want
        else return false unless actual == want
        end
      else
        return false unless actual == want
      end
    end
    if cond.self_switch_valid
      return false unless $game_self_switches
      key = "#{$game_map ? $game_map.map_id : 0},#{@event_id},#{cond.self_switch_ch}"
      return false unless $game_self_switches[key]
    end
    true
  end

  # Override passable? — event không chặn event khác (chỉ chặn player)
  def passable?(x, y)
    true
  end

  def update
    refresh if @page_index < 0 || @starting
    update_move_route if @move_route
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Follower — thành viên party đi theo player (bản tối thiểu)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Follower < Game_Character
  attr_accessor :index
  attr_accessor :preceding_character

  def initialize(index, preceding_character)
    super()
    @index = index
    @preceding_character = preceding_character
  end

  # Đi theo character phía trước (bản tối thiểu: giữ nguyên vị trí nếu
  # character phía trước chưa di chuyển; nếu đã di chuyển thì bám theo).
  def update
    return unless @preceding_character
    if @preceding_character.x != @x || @preceding_character.y != @y
      @x = @preceding_character.x
      @y = @preceding_character.y
      @real_x = @x
      @real_y = @y
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Vehicle — phương tiện (boat, ship, airship) — bản tối thiểu
# ─────────────────────────────────────────────────────────────────────────────

class Game_Vehicle < Game_Character
  attr_accessor :vehicle_type
  attr_accessor :map_id
  attr_accessor :location

  def initialize(vehicle_type)
    super()
    @vehicle_type = vehicle_type
    @map_id = 0
    @location = [0, 0]
  end

  def update
    # Bản tối thiểu: không di chuyển tự động
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Actor — wrap RPG::Actor (bản tối thiểu M6.2)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Actor
  attr_accessor :actor_id
  attr_accessor :name
  attr_accessor :level
  attr_accessor :hp
  attr_accessor :mp
  attr_accessor :max_hp
  attr_accessor :max_mp
  attr_accessor :x
  attr_accessor :y

  def initialize(actor_data)
    @actor_id = actor_data.id
    @name = actor_data.name
    @level = actor_data.initial_level
    @max_hp = 100
    @max_mp = 50
    @hp = @max_hp
    @mp = @max_mp
    @x = 0
    @y = 0
  end

  def dead?
    @hp <= 0
  end

  def alive?
    @hp > 0
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Party — quản lý party (bản tối thiểu M6.2)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Party
  attr_accessor :actors
  attr_accessor :gold
  attr_accessor :steps

  def initialize
    @actors = []
    @gold = 0
    @steps = 0
  end

  def add_actor(actor)
    @actors << actor unless @actors.include?(actor)
  end

  def remove_actor(actor_id)
    @actors.delete_if { |a| a.actor_id == actor_id }
  end

  def leader
    @actors[0]
  end

  def all_dead?
    @actors.all?(&:dead?)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Per-frame hook — gọi từ Swift (RubyBridge.advanceFrame → mrb_bridge_call_global)
# ─────────────────────────────────────────────────────────────────────────────

def rpg_player_advance_frame
  map = $game_map
  if map
    map.update
    player = map.player
    player.update if player
  end
  interp = $game_interpreter
  interp.update if interp && interp.running?
  true
end
