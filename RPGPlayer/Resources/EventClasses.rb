# RPGPlayer/Resources/EventClasses.rb
# M6.5 — Game_Interpreter / Game_Message / Event Runtime cho RPG Maker VX Ace (RGSS3).
#
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
# RPG Maker VX Ace), đặc biệt phần "Event Commands" mô tả opcode + tham số.
# KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine mã nguồn mở
# GPL/LGPL nào (mkxp-z, v.v.).
#
# PHẠM VI M6.5 — Batch 1 (đã được user review + duyệt):
#   ✅ 101 Show Text (+401 line)         ✅ 102 Show Choices (+402/403/404)
#   ✅ 108/408 Comment                   ✅ 111 Conditional Branch (+411/412)
#   ✅ 113 Loop / 115 Break / 413 Repeat ✅ 117 Common Event (child interpreter)
#   ✅ 118 Label / 119 Jump              ✅ 121 Control Switches
#   ✅ 122 Control Variables             ✅ 123 Control Self Switch
#   ✅ 125 Change Gold                   ✅ 129 Change Party Member (subset)
#   ✅ 201 Transfer Player (cùng map)    ✅ 202 Set Event Location
#   ✅ 217 Set Move Route                ✅ 230 Wait
#   ✅ 250 Play SE (log, chưa audio)     ✅ 355/655 Script (eval hạn chế)
#
# CHƯA HỖ TRỢ (ghi log + bỏ qua an toàn):
#   106/406 Input Number, 104/105 Scroll Map, 132-145 actor stat, 203-236
#   effect/weather/battle, 241-249 audio khác, 261 movie, 320-326 battle.
#
# KIẾN TRÚC:
#   - Game_Interpreter chạy RPG::EventCommand list theo index + indent.
#   - Mỗi frame gọi #update: thực thi lệnh tuần tự tới khi gặp wait /
#     message_waiting / hết list. Đúng hành vi RGSS3 (interpreter chạy vài
#     lệnh mỗi frame, không block main loop).
#   - Block (if/loop/choices) dùng indent để skip — clean-room theo mô tả
#     hành vi công khai: 111 false → nhảy tới else+1 (chạy nhánh else, bỏ
#     qua chính 411), 411 → nhảy tới 412 (end), 412 → marker.
#   - Self switch key: "map_id,event_id,ch" (đúng RGSS3 Game_SelfSwitches).

# ─────────────────────────────────────────────────────────────────────────────
# Game_Message — hàng đợi hội thoại (window đọc từ đây)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Message
  attr_accessor :texts
  attr_accessor :face_name
  attr_accessor :face_index
  attr_accessor :background
  attr_accessor :position
  attr_accessor :speaker_name

  def initialize
    clear
  end

  def clear
    @texts = []
    @face_name = ""
    @face_index = 0
    @background = 0
    @position = 2
    @speaker_name = ""
  end

  def add(text)
    @texts.push(text.to_s)
  end

  def all_text
    @texts.join("\n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Interpreter — thực thi event command list
# ─────────────────────────────────────────────────────────────────────────────

class Game_Interpreter
  attr_accessor :list
  attr_accessor :index
  attr_accessor :depth
  attr_accessor :event_id
  attr_accessor :wait_count
  attr_accessor :message_waiting
  attr_accessor :map_id
  attr_accessor :child_interpreter

  def initialize(depth = 0)
    @depth = depth
    @index = 0
    @list = []
    @event_id = 0
    @wait_count = 0
    @message_waiting = false
    @map_id = 0
    @child_interpreter = nil
    @choice_index = 0
    @choice_available = false
    @choice_cancel = 3
  end

  def setup(list, event_id = 0)
    @list = list || []
    @index = 0
    @event_id = event_id
    @wait_count = 0
    @message_waiting = false
    @child_interpreter = nil
    @choice_available = false
  end

  def running?
    @list && @index < @list.size
  end

  # ── Truy cập game objects (clean-room: global do rpg_player_setup_runtime tạo)
  def game_switches
    $game_switches
  end

  def game_variables
    $game_variables
  end

  def game_self_switches
    $game_self_switches
  end

  def game_map
    $game_map
  end

  def game_player
    $game_player
  end

  def game_system
    $game_system
  end

  def game_temp
    $game_temp
  end

  def game_party
    $game_party
  end

  def game_message
    $game_message
  end

  # ── Vòng chạy chính — gọi mỗi frame
  def update
    if @child_interpreter
      @child_interpreter.update
      @child_interpreter = nil unless @child_interpreter.running?
      return
    end
    # M6.5 fix: wait_count giảm 1 mỗi frame (RGSS3) — nếu không, interpreter
    # kẹt vĩnh viễn ở lệnh Wait (230).
    if @wait_count > 0
      @wait_count -= 1
      return
    end
    return if @message_waiting && !confirm_message
    return if @choice_available && !confirm_choice
    return if @message_waiting || @choice_available

    loop do
      cmd = @list[@index]
      break unless cmd
      @index += 1
      execute_command(cmd)
      break if @wait_count > 0
      break if @message_waiting
      break if @choice_available
    end
  end

  def execute_command(cmd)
    case cmd.code
    when 101 then command_101(cmd)
    when 102 then command_102(cmd)
    when 108, 408 then :comment               # không cần thực thi
    when 111 then command_111(cmd)
    when 113 then :loop_marker                # Loop — marker, tiếp tục
    when 115 then command_115(cmd)
    when 117 then command_117(cmd)
    when 118 then :label_marker               # Label — marker
    when 119 then command_119(cmd)
    when 121 then command_121(cmd)
    when 122 then command_122(cmd)
    when 123 then command_123(cmd)
    when 125 then command_125(cmd)
    when 129 then command_129(cmd)
    when 201 then command_201(cmd)
    when 202 then command_202(cmd)
    when 217 then command_217(cmd)
    when 230 then command_230(cmd)
    when 250 then command_250(cmd)
    when 355 then command_355(cmd)
    when 399 then :placeholder
    when 401 then :text_line                  # 401 được 101 gom trước
    when 402 then command_402(cmd)            # When (marker — skip tới End)
    when 403 then command_403(cmd)            # Cancel (marker — skip tới End)
    when 404 then :choice_end                 # End Choices — marker
    when 411 then command_411(cmd)            # Else — skip tới End
    when 412 then :block_end                  # End (chung) — marker
    when 413 then command_413(cmd)            # Repeat Above — quay lại Loop
    when 655 then command_655(cmd)
    else
      warn "[RPGPlayer] EventInterpreter: opcode #{cmd.code} chưa hỗ trợ — bỏ qua (indent #{cmd.indent})"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 101 Show Text (+ 401 lines)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_101(cmd)
    # Gom các lệnh 401 theo sau có indent > indent của 101
    lines = []
    i = @index
    while i < @list.size
      c = @list[i]
      break unless c.code == 401 && c.indent > cmd.indent
      lines.push(c.parameters[0].to_s)
      i += 1
    end
    @index = i
    text = lines.join("\n")
    game_message.clear
    game_message.add(text)
    window = $game_message_window
    if window
      window.start_message(game_message.all_text)
    end
    @message_waiting = true
  end

  # User nhấn C khi message đang hiển thị → đóng + cho interpreter chạy tiếp
  def confirm_message
    return true unless @message_waiting
    if Input.trigger?(Input::C)
      @message_waiting = false
      window = $game_message_window
      window.clear if window
      true
    else
      false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 102 Show Choices (+ 402 When / 403 Cancel / 404 End)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_102(cmd)
    choices = cmd.parameters[0] || []
    return if choices.empty?
    @choice_index = 0
    @choice_count = choices.size
    @choice_cancel = (cmd.parameters[1] || 3).to_i
    @choice_available = true
    window = $game_message_window
    if window
      window.clear
      window.draw_items(choices)
    end
  end

  def confirm_choice
    return true unless @choice_available
    window = $game_message_window
    @choice_count = window.item_max if window && window.respond_to?(:item_max)
    if Input.trigger?(Input::DOWN)
      @choice_index = (@choice_index + 1) % @choice_count
      window.cursor_down if window && window.respond_to?(:cursor_down)
    elsif Input.trigger?(Input::UP)
      @choice_index = (@choice_index - 1 + @choice_count) % @choice_count
      window.cursor_up if window && window.respond_to?(:cursor_up)
    end
    if Input.trigger?(Input::C)
      @choice_available = false
      jump_to_choice(@choice_index)
      true
    elsif Input.trigger?(Input::B) && @choice_cancel > 0 && @choice_cancel <= 4
      @choice_available = false
      jump_to_choice_cancel
      true
    else
      false
    end
  end

  def jump_to_choice(choice_id)
    # Tìm 402 (When) có parameter[0] == choice_id, indent = indent(102) + 1
    i = @index
    while i < @list.size
      c = @list[i]
      if c.code == 402 && c.parameters[0].to_i == choice_id
        @index = i + 1   # bỏ qua 402 (marker) — chạy block chọn
        return
      end
      if c.code == 404 && c.indent <= 1
        @index = i + 1   # không tìm thấy → hết choices
        return
      end
      i += 1
    end
    @index = @list.size
  end

  def jump_to_choice_cancel
    i = @index
    while i < @list.size
      c = @list[i]
      if c.code == 403
        @index = i + 1   # bỏ qua 403 (marker) — chạy block cancel
        return
      end
      if c.code == 404
        @index = i + 1
        return
      end
      i += 1
    end
    @index = @list.size
  end

  def command_402(_cmd)
    skip_to_branch_marker
  end

  def command_403(_cmd)
    skip_to_branch_marker
  end

  # Skip tới marker kế tiếp của choices (404 End / 402 When khác / 403 Cancel)
  # — dùng khi 402/403 bị thực thi fallback (flow chuẩn qua confirm_choice).
  def skip_to_branch_marker
    cmd = @list[@index - 1]
    indent = cmd.indent
    i = @index
    while i < @list.size
      c = @list[i]
      if c.indent == indent && (c.code == 404 || c.code == 402 || c.code == 403)
        @index = i + 1
        return
      end
      i += 1
    end
    @index = @list.size
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 111 Conditional Branch (+ 411 Else / 412 End)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_111(cmd)
    if condition_ok?(cmd)
      # Nhánh if chạy — khi gặp 411 (else) sẽ bị skip bởi command_411
      :run
    else
      # Nhảy tới else+1 (chạy nhánh else) hoặc end+1 (không else).
      # RGSS3: Else (411) / End (412) có indent = indent(111) + 1.
      target_indent = cmd.indent + 1
      i = @index
      while i < @list.size
        c = @list[i]
        if c.indent == target_indent
          return @index = i + 1 if c.code == 411
          return @index = i + 1 if c.code == 412
        end
        i += 1
      end
      # Fallback: quét mọi 411/412 sau vị trí hiện tại (đề phòng định dạng
      # indent khác) — 411 được ưu tiên (else gần nhất), nếu không có thì 412.
      i = @index
      while i < @list.size
        c = @list[i]
        return @index = i + 1 if c.code == 411
        return @index = i + 1 if c.code == 412
        i += 1
      end
      @index = @list.size
    end
  end

  def command_411(_cmd)
    skip_to_end_of_block
  end

  # Điều kiện (Batch 1: switch / variable / self switch / button / script)
  def condition_ok?(cmd)
    params = cmd.parameters
    type = params[0].to_i
    case type
    when 0   # Switch
      game_switches[params[1].to_i] == (params[2].to_i != 0)
    when 1   # Variable
      var_id = params[1].to_i
      value  = params[2].to_i
      cmp    = params[3].to_i
      actual = game_variables[var_id]
      case cmp
      when 0 then actual == value
      when 1 then actual != value
      when 2 then actual >= value
      when 3 then actual <= value
      when 4 then actual > value
      when 5 then actual < value
      else false
      end
    when 2   # Self Switch
      ch = params[1].to_s
      want = (params[2].to_s == "ON")
      game_self_switches[self_switch_key(ch)] == want
    when 11  # Button (hằng số Input — hỗ trợ khi Input module có)
      button_id = params[1].to_i
      Input.trigger?(button_id)
    when 12  # Script
      safe_eval(params[1].to_s)
    else
      # Actor/Enemy/Character/Gold/Item/Weapon/Armor chưa hỗ trợ Batch 1
      warn "[RPGPlayer] EventInterpreter: điều kiện type #{type} chưa hỗ trợ — coi là false"
      false
    end
  end

  def self_switch_key(ch)
    "#{@map_id},#{@event_id},#{ch}"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Loop / Break / Repeat
  # ═══════════════════════════════════════════════════════════════════════════
  def command_115(cmd)
    # Break Loop: nhảy tới 412 (End) của loop. RGSS3: Break (115) là lệnh con
    # của Loop → indent(115) = indent(113) + 1; 412 End cũng có indent = indent(113)+1
    # = indent(115). Nếu End ở mức khác (indent nhỏ hơn), fallback quét bừa.
    indent = cmd.indent
    i = @index
    while i < @list.size
      c = @list[i]
      if c.code == 412 && c.indent == indent
        @index = i + 1
        return
      end
      i += 1
    end
    @index = @list.size
  end

  def command_413(cmd)
    # Repeat Above: nhảy tới lệnh 113 (Loop) gần nhất có indent = indent(this)-1
    loop_indent = cmd.indent - 1
    i = @index - 1
    while i >= 0
      c = @list[i]
      if c.indent == loop_indent && c.code == 113
        @index = i
        return
      end
      i -= 1
    end
    @index = @list.size
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 117 Common Event — child interpreter (độ sâu lồng nhau)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_117(cmd)
    common_id = cmd.parameters[0].to_i
    list = nil
    if defined?($data_common_events) && $data_common_events
      ce = $data_common_events[common_id]
      list = ce.list if ce && ce.respond_to?(:list)
    end
    if list.nil? || list.empty?
      warn "[RPGPlayer] EventInterpreter: common event #{common_id} không tìm thấy — bỏ qua"
      return
    end
    if @depth >= 100
      warn "[RPGPlayer] EventInterpreter: depth quá sâu (common event #{common_id}) — bỏ qua"
      return
    end
    child = Game_Interpreter.new(@depth + 1)
    child.map_id = @map_id
    child.setup(list, 0)
    @child_interpreter = child
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 118 Label / 119 Jump to Label
  # ═══════════════════════════════════════════════════════════════════════════
  def command_119(cmd)
    name = cmd.parameters[0].to_s
    i = 0
    while i < @list.size
      c = @list[i]
      if c.code == 118 && c.parameters[0].to_s == name
        @index = i + 1
        return
      end
      i += 1
    end
    warn "[RPGPlayer] EventInterpreter: label '#{name}' không tìm thấy"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 121 Control Switches
  # ═══════════════════════════════════════════════════════════════════════════
  def command_121(cmd)
    start_id = cmd.parameters[0].to_i
    end_id   = cmd.parameters[1].to_i
    value    = cmd.parameters[2].to_i != 0
    (start_id..end_id).each { |i| game_switches[i] = value }
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 122 Control Variables
  # ═══════════════════════════════════════════════════════════════════════════
  def command_122(cmd)
    params = cmd.parameters
    start_id = params[0].to_i
    end_id   = params[1].to_i
    operation = params[2].to_i   # 0=set 1=add 2=sub 3=mul 4=div 5=mod
    operand   = params[3].to_i   # 0=const 1=var 2=random 3=game data 4=script
    value = operand_value(operand, params)
    (start_id..end_id).each do |i|
      current = game_variables[i]
      result = value
      result = current + value if operation == 1
      result = current - value if operation == 2
      result = current * value if operation == 3
      result = (value == 0 ? 0 : current / value) if operation == 4
      result = (value == 0 ? 0 : current % value) if operation == 5
      game_variables[i] = result
    end
  end

  def operand_value(operand, params)
    case operand
    when 0 then params[4].to_i                     # Constant
    when 1 then game_variables[params[4].to_i]     # Variable
    when 2 then rand(params[4].to_i + 1)           # Random 0..N
    when 4 then safe_eval(params[4].to_s).to_i     # Script
    when 3
      # Game Data — Batch 1: chỉ hỗ trợ gold (11) / steps (12)
      data_type = params[4].to_i
      di = params[5].to_i
      case data_type
      when 11 then game_party.gold
      when 12 then game_party.steps
      else
        warn "[RPGPlayer] EventInterpreter: game data type #{data_type} chưa hỗ trợ — dùng 0"
        0
      end
    else 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 123 Control Self Switch
  # ═══════════════════════════════════════════════════════════════════════════
  def command_123(cmd)
    ch    = cmd.parameters[0].to_s
    value = (cmd.parameters[1].to_s == "ON")
    game_self_switches[self_switch_key(ch)] = value
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 125 Change Gold / 129 Change Party Member (subset)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_125(cmd)
    op    = cmd.parameters[0].to_i           # 0=increase 1=decrease
    value = cmd.parameters[1].to_i
    if op == 0
      game_party.gold += value
    else
      game_party.gold -= value
    end
  end

  def command_129(cmd)
    op   = cmd.parameters[0].to_i            # 0=add 1=remove
    ids  = cmd.parameters[1] || []
    ids.each do |actor_id|
      if op == 0
        actor = nil
        if defined?($game_actors) && $game_actors
          actor = $game_actors[actor_id]
        end
        if actor
          game_party.add_actor(actor)
        end
      else
        game_party.remove_actor(actor_id)
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 201 Transfer Player (cùng map — Batch 1)
  # ═══════════════════════════════════════════════════════════════════════════
  def command_201(cmd)
    params = cmd.parameters
    _type   = params[0].to_i     # 0=cùng map, 1=chỉ định (chưa hỗ trợ khác map)
    map_id  = params[1].to_i
    x       = params[2].to_i
    y       = params[3].to_i
    dir     = params[4].to_i
    player = game_player
    return unless player
    if map_id != 0 && map_id != game_map.map_id
      warn "[RPGPlayer] EventInterpreter: transfer tới map #{map_id} chưa hỗ trợ (M6.5 Batch 1) — giữ map hiện tại"
    end
    player.x = x
    player.y = y
    player.real_x = x
    player.real_y = y
    # RGSS3: direction 0 = giữ nguyên hướng hiện tại
    player.direction = dir unless dir == 0
    game_map.setup_player_start if game_map.respond_to?(:setup_player_start)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 202 Set Event Location
  # ═══════════════════════════════════════════════════════════════════════════
  def command_202(cmd)
    params = cmd.parameters
    char_id = params[0].to_i     # 0=player, -1=this event, >0=event id
    _type   = params[1].to_i     # 0=direct, 1=variables (chưa hỗ trợ variables)
    x = params[2].to_i
    y = params[3].to_i
    dir = params[4].to_i
    char = nil
    if char_id == 0
      char = game_player
    elsif char_id == -1
      char = game_map.events[@event_id]
    else
      char = game_map.events[char_id]
    end
    return unless char
    char.x = x
    char.y = y
    char.real_x = x
    char.real_y = y
    # RGSS3: direction 0 = giữ nguyên hướng hiện tại
    char.direction = dir unless dir == 0
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 217 Set Move Route
  # ═══════════════════════════════════════════════════════════════════════════
  def command_217(cmd)
    params = cmd.parameters
    char_id = params[0].to_i     # 0=player, -1=this event, >0=event id
    char = nil
    if char_id == 0
      char = game_player
    elsif char_id == -1
      char = game_map.events[@event_id]
    else
      char = game_map.events[char_id]
    end
    return unless char
    route = RPG::MoveRoute.new
    route.repeat    = params[1] ? true : false
    route.skippable = params[2] ? true : false
    route.wait      = params[3] ? true : false
    route.list = params[4] || []
    char.move_route = route
    char.move_route_index = 0
    @wait_count = 1 if route.wait   # dừng ít nhất 1 frame chờ route bắt đầu
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 230 Wait
  # ═══════════════════════════════════════════════════════════════════════════
  def command_230(cmd)
    @wait_count = cmd.parameters[0].to_i
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 250 Play SE — chưa có audio, log + bỏ qua an toàn
  # ═══════════════════════════════════════════════════════════════════════════
  def command_250(cmd)
    se = cmd.parameters[0]
    name = se.respond_to?(:name) ? se.name : nil
    warn "[RPGPlayer] EventInterpreter: Play SE '#{name}' chưa hỗ trợ audio — bỏ qua"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 355 / 655 Script — eval hạn chế, guard lỗi
  # ═══════════════════════════════════════════════════════════════════════════
  def command_355(cmd)
    script = cmd.parameters[0].to_s
    safe_eval(script)
  end

  def command_655(cmd)
    # Gom các dòng script có indent > indent(655)
    lines = []
    i = @index
    while i < @list.size
      c = @list[i]
      break unless c.code == 655 && c.indent > cmd.indent
      lines.push(c.parameters[0].to_s)
      i += 1
    end
    @index = i
    safe_eval(lines.join("\n"))
  end

  def safe_eval(script)
    return false if script.nil? || script.strip.empty?
    begin
      eval(script)
    rescue Exception => e
      warn "[RPGPlayer] EventInterpreter: script lỗi (#{e.message}) — script=#{script[0, 80]}"
      false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Hỗ trợ dùng chung
  # ═══════════════════════════════════════════════════════════════════════════

  # Skip tới lệnh End (412) cùng indent — dùng cho Else/When/Cancel.
  def skip_to_end_of_block
    cmd = @list[@index - 1]
    indent = cmd.indent
    i = @index
    while i < @list.size
      c = @list[i]
      if c.indent == indent && c.code == 412
        @index = i + 1
        return
      end
      i += 1
    end
    @index = @list.size
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Khởi tạo runtime — gọi từ Swift sau khi load scripts (scene loop M6.5+)
# ─────────────────────────────────────────────────────────────────────────────

def rpg_player_setup_runtime
  $game_temp = Game_Temp.new
  $game_system = Game_System.new
  $game_switches = Game_Switches.new
  $game_variables = Game_Variables.new
  $game_self_switches = Game_SelfSwitches.new
  $game_party = Game_Party.new
  $game_message = Game_Message.new
  $game_map = Game_Map.new
  $game_player = Game_Player.new($game_map)
  $game_map.player = $game_player
  # M6.5: interpreter của map — Game_Map.setup_starting_event gọi setup() khi
  # có event.starting (touch/action trigger).
  $game_interpreter = Game_Interpreter.new
  $game_map.interpreter = $game_interpreter
  if defined?(Window_Message) && !$game_message_window
    $game_message_window = Window_Message.new(40, 200, 400, 100)
  end
  true
end
