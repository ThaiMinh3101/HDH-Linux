# RPG Player — EventClasses.rb (M6.5)
# Clean-room implementation based on the public RGSS3 Reference Manual
# (help file shipped with RPG Maker VX Ace). No code was copied or derived
# from any open-source RGSS engine.
#
# Provides:
#   Game_Message     — message buffer for Window_Message (via C bridge)
#   Game_Interpreter — RGSS3-style event command interpreter
#   rpg_player_setup_runtime / rpg_player_advance_frame — Swift entry points
#
# LƯU Ý: Game_* runtime classes (Game_Map, Game_Player, Game_Switches, ...)
# định nghĩa ở GameClasses.rb (M6.2) — file này KHÔNG redefine chúng. Chỉ
# thêm Game_Message + Game_Interpreter + gluing.
#
# M6.5 opcodes (Batch 1):
#   101 Show Text, 102 Show Choices, 111 Conditional Branch,
#   121/122/123 Control Switches/Variables/SelfSwitch,
#   201 Transfer Player, 202 Event Location, 217 Set Move Route,
#   230 Wait, 117 Common Event, 113/115/413 Loop/Break/Repeat,
#   118/119 Label/Jump, 125/129 Change Gold/Party, 250 Play SE (log),
#   355/655 Script (safe_eval)
# Structure: 402/403/404 (choices), 411/412 (branch end)
#
# Opcode chưa hỗ trợ (106/406, 104/105, 132-145, 203-236, 241-249, 261,
# 320-326) → record_unsupported + bỏ qua an toàn.

# ---------- Game_Message ----------
class Game_Message
  attr_accessor :texts, :choices, :choice_cancel_type,
                :choice_max, :face_name, :face_index,
                :background, :position_type, :wait_more
  attr_reader :item_choice_variable_id, :scroll_mode, :scroll_speed

  def initialize
    clear
  end

  def clear
    @texts        = []
    @choices      = []
    @choice_max   = 0
    @choice_cancel_type = 0
    @face_name    = nil
    @face_index   = 0
    @background   = 0
    @position_type = 2
    @wait_more    = false
    @scroll_mode  = false
    @scroll_speed = 2
    @item_choice_variable_id = 0
  end

  def visible_message?
    !@texts.empty?
  end

  def add(text)
    @texts.push(text.to_s)
  end
end

# ---------- Game_Interpreter ----------
# Thực thi danh sách RPG::EventCommand (opcode chuẩn RGSS3) từ `list`.
# Mỗi frame xử lý tối đa COMMANDS_PER_FRAME lệnh (chống frame drop), trừ
# khi gặp lệnh chờ (Wait 230 / message đang hiển thị / choice đang chờ).
class Game_Interpreter
  COMMANDS_PER_FRAME = 40

  attr_reader :depth, :index, :list, :event_id
  attr_accessor :wait_count, :message_waiting
  attr_accessor :map_id
  attr_accessor :choice_available

  def initialize(depth = 0)
    @depth = depth
    clear
  end

  def clear
    @index            = 0
    @list             = []
    @event_id         = 0
    @branch           = {}
    @wait_count       = 0
    @message_waiting  = false
    @common_event_id  = 0
    @map_id           = 0
    # M6.5: choice state
    @choice_index     = 0
    @choice_count     = 0
    @choice_cancel    = 0
    @choice_available = false
    @last_script_code = 0
  end

  def setup(list, event_id = 0)
    clear
    @list = list || []
    @event_id = event_id
  end

  def running?
    !@list.empty?
  end

  def setup_children
    return if @children
    @children = []
    3.times { @children.push(Game_Interpreter.new(@depth + 1)) }
  end

  def update_child
    setup_children
    @children.each do |child|
      return true if child.update
    end
    false
  end

  # Per-frame update. Returns true while still running.
  #
  # ⚠️ LƯU Ý (fix M6.5): `@index += 1` phải nằm TRONG vòng while, ngay sau
  # run_command — nếu để sau vòng while, mỗi command bị chạy lặp
  # COMMANDS_PER_FRAME (40) lần trước khi index được tăng (bug: Wait 230
  # không bao giờ kết thúc, Control Switches chạy lặp). Index chỉ KHÔNG tăng
  # khi command tự điều khiển luồng (111 false → skip tới Else/End qua
  # skip_branch_to_else_or_end).
  def update
    return false if @list.empty?
    return true if update_child
    if @wait_count > 0
      @wait_count -= 1
      return true
    end
    if @message_waiting
      if $game_message && !$game_message.visible_message?
        @message_waiting = false
      else
        return true
      end
    end
    if @choice_available
      confirm_choice
      return true
    end
    steps = 0
    while @index < @list.size
      command = @list[@index]
      unless command
        @index += 1
        next
      end
      code = cmd_code(command)
      indent = cmd_indent(command)
      if code == 411 && @branch[indent - 1]
        # Nhánh TRUE: gặp Else (411, có indent = indent(111)+1) → nhảy thẳng
        # tới Branch End 412 (có indent = indent(111)) — bỏ qua else body.
        # Đúng RGSS3: else chỉ chạy khi điều kiện false.
        @index = find_skip_to_412(indent - 1)
        next
      end
      if [402, 403, 411, 412].include?(code)
        @index += 1
        next
      end
      if code == 404
        # End Choices — dừng block choice, nhảy qua 404 tới lệnh sau
        @index += 1
        break
      end
      run_command(code, indent, command)
      @index += 1
      steps += 1
      break if @wait_count > 0 || @message_waiting || @choice_available
      break if steps >= COMMANDS_PER_FRAME
    end
    true
  end

  # Nhảy thẳng tới Branch End (412) cùng indent — dùng khi nhánh TRUE gặp
  # Else (411): bỏ qua toàn bộ else body. Xử lý nested branch bằng depth.
  def find_skip_to_412(indent)
    depth = 0
    i = @index + 1
    while i < @list.size
      c = @list[i]
      ccode = cmd_code(c)
      cindent = cmd_indent(c)
      if ccode == 111 && cindent > indent
        depth += 1
      elsif ccode == 412 && cindent == indent
        return i if depth == 0
        depth -= 1
      end
      i += 1
    end
    @list.size
  end

  def run_command(code, indent, command)
    case code
    when 101 then command_101(indent, command)
    when 102 then command_102(indent, command)
    when 111 then command_111(indent, command)
    when 113 then command_113(indent, command)
    when 115 then command_115(indent, command)
    when 117 then command_117(indent, command)
    when 118 then command_118(indent, command)
    when 119 then command_119(indent, command)
    when 121 then command_121(indent, command)
    when 122 then command_122(indent, command)
    when 123 then command_123(indent, command)
    when 125 then command_125(indent, command)
    when 129 then command_129(indent, command)
    when 201 then command_201(indent, command)
    when 202 then command_202(indent, command)
    when 217 then command_217(indent, command)
    when 230 then command_230(indent, command)
    when 250 then command_250(indent, command)
    when 355, 655 then command_355(code, indent, command)
    when 401 then  # text line — đã được command_101 tiêu thụ
    when 413 then command_413(indent, command)
    when 0
    else
      record_unsupported(code)
    end
  end

  def record_unsupported(opcode)
    $rpg_player_unsupported = [] unless $rpg_player_unsupported
    $rpg_player_unsupported.push(opcode) unless $rpg_player_unsupported.include?(opcode)
  end

  # ---- Helpers ----

  def cmd_code(cmd)
    cmd.is_a?(Array) ? cmd[0] : (cmd.respond_to?(:code) ? cmd.code : 0)
  end

  def cmd_indent(cmd)
    cmd.is_a?(Array) ? (cmd[1] || 0) : (cmd.respond_to?(:indent) ? cmd.indent : 0)
  end

  def cmd_params(cmd)
    if cmd.is_a?(Array) && cmd.size > 2
      cmd[2]
    elsif cmd.respond_to?(:parameters)
      cmd.parameters
    else
      []
    end
  end

  def feed_message_to_window
    return unless $game_message && $game_message.texts && !$game_message.texts.empty?
    return unless $game_message_window
    $game_message_window.start_message($game_message.texts.join("\n"), {}, {})
  end

  # ---- Event Commands (Batch 1 theo RGSS3 Reference Manual) ----

  # 101 Show Text: các dòng text nằm trong command 401 ngay sau (cùng indent)
  def command_101(indent, command)
    params = cmd_params(command)
    $game_message.clear
    if params.is_a?(Array)
      $game_message.face_name = params[0] ? params[0].to_s : ""
      $game_message.face_index = (params[1] || 0).to_i
      $game_message.background = (params[2] || 0).to_i
      $game_message.position_type = (params[3] || 2).to_i
    end
    i = @index + 1
    while i < @list.size
      c = @list[i]
      break unless cmd_code(c) == 401
      break unless cmd_indent(c) > indent
      cparams = cmd_params(c)
      text = cparams.is_a?(Array) && cparams[0] ? cparams[0].to_s : ""
      $game_message.add(text)
      i += 1
    end
    @index = i - 1
    @message_waiting = true
    feed_message_to_window
  end

  # 102 Show Choices — lưu choice state; confirm_choice xử lý Input mỗi frame
  def command_102(indent, command)
    params = cmd_params(command)
    $game_message.clear
    if params.is_a?(Array)
      choices = params[0].is_a?(Array) ? params[0] : []
      $game_message.choices = choices.map(&:to_s)
      $game_message.choice_max = choices.size
      $game_message.choice_cancel_type = (params[1] || 0).to_i
    end
    @choice_index = 0
    @choice_count = $game_message.choice_max
    @choice_cancel = $game_message.choice_cancel_type
    @choice_available = true
    feed_choice_to_window
  end

  # Xử lý input cho choice: UP/DOWN di chuyển (wrap-around), C chọn, B cancel.
  # Gọi từ update() mỗi frame khi @choice_available.
  def confirm_choice
    return unless @choice_available
    if Input.trigger?(Input::UP)
      @choice_index = (@choice_index - 1) % @choice_count if @choice_count > 0
      @choice_index = @choice_count - 1 if @choice_index < 0
      feed_choice_to_window
    elsif Input.trigger?(Input::DOWN)
      @choice_index = (@choice_index + 1) % @choice_count if @choice_count > 0
      feed_choice_to_window
    elsif Input.trigger?(Input::C)
      @choice_available = false
      jump_to_choice(@choice_index)
    elsif Input.trigger?(Input::B)
      if @choice_cancel == 1
        @choice_available = false
        jump_to_choice_cancel
      end
    end
  end

  def feed_choice_to_window
    return unless $game_message_window
    lines = $game_message.choices.each_with_index.map do |c, i|
      prefix = (i == @choice_index) ? "> " : "  "
      prefix + c
    end
    $game_message_window.start_message(lines.join("\n"), {}, {})
  end

  # Nhảy tới 402 có parameter[0] == choice_id; hết → 403 (cancel) → 404
  def jump_to_choice(choice_id)
    @choice_available = false
    i = @index + 1
    while i < @list.size
      c = @list[i]
      if cmd_code(c) == 402
        p = cmd_params(c)
        if p.is_a?(Array) && p[0].to_i == choice_id
          @index = i
          return
        end
      end
      i += 1
    end
    jump_to_choice_cancel
  end

  def jump_to_choice_cancel
    @choice_available = false
    i = @index + 1
    while i < @list.size
      c = @list[i]
      if cmd_code(c) == 403
        @index = i
        return
      end
      i += 1
    end
    # Không có 403 → tìm 404 (kết thúc choices)
    i = @index + 1
    while i < @list.size
      c = @list[i]
      if cmd_code(c) == 404
        @index = i
        return
      end
      i += 1
    end
    @index = @list.size
  end

  # 111 Conditional Branch
  #   params = [code, value1, value2, value3, value4]
  #   code 0 = switch, 1 = variable, 2 = self switch, 4 = actor, 5 = timer, 6 = party
  def command_111(indent, command)
    params = cmd_params(command)
    return skip_branch_to_else_or_end(indent) unless params.is_a?(Array)
    code   = (params[0] || 0).to_i
    value1 = params[1]
    value2 = params[2]
    value3 = params[3]
    result =
      case code
      when 0  # Switch
        sid = (value1 || 0).to_i
        cur = ($game_switches ? $game_switches[sid] : false)
        cur == (value2 == 1 || value2.to_s == "true")
      when 1  # Variable
        vid = (value1 || 0).to_i
        v = $game_variables ? $game_variables[vid] : 0
        op = (value2 || 0).to_i
        n  = (value3 || 0).to_i
        case op
        when 0 then v == n
        when 1 then v >= n
        when 2 then v <= n
        when 3 then v > n
        when 4 then v < n
        when 5 then v != n
        else false
        end
      when 2  # Self switch
        key = "#{@map_id},#{@event_id},#{value1}"
        cur = ($game_self_switches ? $game_self_switches[key] : false)
        cur == (value2 == 1 || value2.to_s == "true")
      else
        record_unsupported(code)
        false  # actor/timer/party chưa hỗ trợ — coi là false
      end
    @branch[indent] = result
    skip_branch_to_else_or_end(indent) unless result
  end

  # Nhảy tới Else (411, có indent = indent+1) hoặc Branch End (412, có indent).
  # RGSS3: 111 có indent N, body/else có indent N+1, 412 (end) có indent N.
  def skip_branch_to_else_or_end(indent)
    depth = 0
    i = @index + 1
    while i < @list.size
      c = @list[i]
      ccode = cmd_code(c)
      cindent = cmd_indent(c)
      if ccode == 111 && cindent == indent + 1
        depth += 1
        i += 1
        next
      end
      if ccode == 412 && cindent == indent
        if depth == 0
          @index = i
          return
        end
        depth -= 1
        i += 1
        next
      end
      if ccode == 411 && cindent == indent + 1 && depth == 0
        @index = i
        return
      end
      i += 1
    end
    @index = @list.size
  end

  # 113 Loop — không làm gì (vòng lặp tự nhiên khi gặp 413 Repeat)
  def command_113(indent, command)
    # No-op: loop body chạy tuần tự; 413 quay lại 113 cùng indent.
  end

  # 115 Break Loop — nhảy tới 412 có indent = indent(115) - 1 (kết thúc loop).
  # RGSS3: 115 nằm TRONG loop (indent > loop), 412 kết thúc loop có indent
  # = indent(loop) = indent(115) - 1.
  def command_115(indent, command)
    target_indent = indent - 1
    i = @index + 1
    while i < @list.size
      c = @list[i]
      if cmd_code(c) == 412 && cmd_indent(c) == target_indent
        @index = i
        return
      end
      i += 1
    end
    @index = @list.size
  end

  # 413 Repeat Loop — quay lại 113 có indent = indent(413) - 1
  def command_413(indent, command)
    target_indent = indent - 1
    i = @index - 1
    while i >= 0
      c = @list[i]
      if cmd_code(c) == 113 && cmd_indent(c) == target_indent
        @index = i
        return
      end
      i -= 1
    end
    @index = @list.size
  end

  # 117 Common Event — chạy interpreter con (bản tối thiểu: log unsupported)
  def command_117(indent, command)
    record_unsupported(117)
  end

  # 118 Label — nothing (điểm đánh dấu cho 119 Jump)
  def command_118(indent, command)
    # no-op
  end

  # 119 Jump to Label — nhảy tới 118 có parameter[0] == label
  def command_119(indent, command)
    params = cmd_params(command)
    label = params.is_a?(Array) ? params[0].to_s : ""
    i = @index + 1
    while i < @list.size
      c = @list[i]
      if cmd_code(c) == 118
        p = cmd_params(c)
        if p.is_a?(Array) && p[0].to_s == label
          @index = i
          return
        end
      end
      i += 1
    end
    # Label không tồn tại → cảnh báo, không crash (RGSS3: bỏ qua an toàn)
    record_unsupported(119)
  end

  # 121 Control Switches — params = [start_id, end_id, value(0/1)]
  def command_121(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    start_id = (params[0] || 0).to_i
    end_id   = (params[1] || 0).to_i
    value    = (params[2] || 0).to_i == 1
    (start_id..end_id).each { |i| $game_switches[i] = value } if $game_switches
  end

  # 122 Control Variables
  #   params = [start_id, end_id, op(0 set,1 add,2 sub,3 mul,4 div,5 mod),
  #             operand_type(0 const,1 var,2 random,3 game data,4 script),
  #             operand, operand2]
  def command_122(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    start_id = (params[0] || 0).to_i
    end_id   = (params[1] || 0).to_i
    op_type  = (params[2] || 0).to_i
    operand_type = (params[3] || 0).to_i
    operand  = params[4]
    operand2 = params[5]
    (start_id..end_id).each do |i|
      base = $game_variables ? $game_variables[i] : 0
      value = calc_operand(operand_type, operand, operand2)
      result =
        case op_type
        when 0 then value
        when 1 then base + value
        when 2 then base - value
        when 3 then base * value
        when 4 then (value == 0 ? base : base / value)
        when 5 then (value == 0 ? base : base % value)
        else base
        end
      $game_variables[i] = result if $game_variables
    end
  end

  def calc_operand(type, operand, operand2)
    case type
    when 0
      (operand || 0).to_i
    when 1
      oid = (operand || 0).to_i
      $game_variables ? $game_variables[oid] : 0
    when 2
      lo = (operand || 0).to_i
      hi = (operand2 || 0).to_i
      hi < lo ? lo : lo + rand(hi - lo + 1)
    when 3
      # Game Data — Batch 1: 11 = gold, 12 = steps
      case (operand || 0).to_i
      when 11
        $game_party ? $game_party.gold : 0
      when 12
        $game_party ? $game_party.steps : 0
      else
        record_unsupported(122)
        0
      end
    else
      record_unsupported(122)
      0
    end
  end

  # 123 Control Self Switch — params = [switch_id("A".."D"), value(0/1)]
  def command_123(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    key = "#{@map_id},#{@event_id},#{params[0]}"
    $game_self_switches[key] = ((params[1] || 0).to_i == 1) if $game_self_switches
  end

  # 125 Change Gold — params = [operation(0 add,1 sub), amount]
  def command_125(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    return unless $game_party
    amount = (params[1] || 0).to_i
    if (params[0] || 0).to_i == 1
      $game_party.gold = [$game_party.gold - amount, 0].max
    else
      $game_party.gold += amount
    end
  end

  # 129 Change Party — params = [operation(0 add, 1 remove), actor_id, init(0/1)]
  def command_129(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    return unless $game_party
    actor_id = (params[1] || 0).to_i
    if (params[0] || 0).to_i == 0
      # Add actor — cần Game_Actor từ $game_actors (chưa có đầy đủ M6.5)
      record_unsupported(129)
    else
      $game_party.remove_actor(actor_id)
    end
  end

  # 201 Transfer Player — params = [direct, map_id, x, y, direction, fade_type]
  def command_201(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    direct = (params[0] || 0).to_i
    map_id = (params[1] || 0).to_i
    x = (params[2] || 0).to_i
    y = (params[3] || 0).to_i
    direction = (params[4] || 0).to_i
    if $game_player
      if map_id == 0 || map_id == $game_map.map_id
        # Cùng map — set vị trí trực tiếp
        $game_player.moveto(x, y)
        $game_player.direction = direction if direction != 0
      else
        # Map khác — chưa hỗ trợ load map mới, giữ nguyên map + cảnh báo
        record_unsupported(201)
      end
    end
    $rpg_player_transfer = { :map_id => map_id, :x => x, :y => y, :direct => direct }
    @wait_count = 5 if direct == 0
  end

  # 202 Event Location — params = [event_id, x, y, direction]
  def command_202(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    return unless $game_map
    event_id = (params[0] || 0).to_i
    x = (params[1] || 0).to_i
    y = (params[2] || 0).to_i
    direction = (params[3] || 0).to_i
    ev = $game_map.events[event_id]
    if ev
      ev.moveto(x, y)
      ev.direction = direction if direction != 0
    end
  end

  # 217 Set Move Route — params = [character_id, route(RPG::MoveRoute)]
  def command_217(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    return unless $game_map
    char_id = (params[0] || 0).to_i
    route = params[1]
    return unless route
    char =
      if char_id == 0
        $game_player
      else
        $game_map.events[char_id]
      end
    return unless char
    char.move_route = route
    char.move_route_index = 0
    char.move_route_forcing = true
    @wait_count = 1 if route.respond_to?(:wait) && route.wait
  end

  # 230 Wait — params = [frames]
  def command_230(indent, command)
    params = cmd_params(command)
    @wait_count = (params.is_a?(Array) && params[0]) ? params[0].to_i : 0
  end

  # 250 Play SE — chưa hỗ trợ audio, log unsupported
  def command_250(indent, command)
    record_unsupported(250)
  end

  # 355/655 Script — safe_eval: rescue Exception → warn, không crash.
  # 355 = script 1 dòng; 655 = script nhiều dòng (gom các 655 có indent lớn hơn).
  def command_355(code, indent, command)
    params = cmd_params(command)
    script = params.is_a?(Array) ? params[0].to_s : params.to_s
    if code == 655
      # 655: gom các dòng script có indent lớn hơn
      i = @index + 1
      while i < @list.size
        c = @list[i]
        break unless cmd_code(c) == 655
        break unless cmd_indent(c) > indent
        cparams = cmd_params(c)
        script += "\n" + (cparams.is_a?(Array) ? cparams[0].to_s : "")
        i += 1
      end
      @index = i - 1
    end
    @last_script_code = code
    begin
      eval(script)
    rescue Exception => e
      record_unsupported(355)
      $rpg_player_script_error = e.message
    end
  end
end

# ---------- Bootstrap ----------
# Swift gọi rpg_player_setup_runtime sau khi load scripts (M6.5) — tạo đủ
# global cần thiết cho event interpreter chạy.
def rpg_player_setup_runtime
  $game_temp          = Game_Temp.new
  $game_system        = Game_System.new
  $game_switches      = Game_Switches.new
  $game_variables     = Game_Variables.new
  $game_self_switches = Game_SelfSwitches.new
  $game_party         = Game_Party.new
  $game_message       = Game_Message.new
  $game_interpreter   = Game_Interpreter.new
  $game_message_window = nil
  $game_troop         = Game_Troop.new
  # M7: Database globals — trỏ tới dữ liệu .rvdata2 thật (load qua
  # DataFileLoader sau này). Mặc định empty array để script truy cập
  # $data_states[id] trả nil thay vì NoMethodError.
  $data_actors        = []
  $data_classes       = []
  $data_skills        = []
  $data_items         = []
  $data_weapons       = []
  $data_armors        = []
  $data_enemies       = []
  $data_troops        = []
  $data_states        = []
  $data_animations    = []
  $data_system        = nil
  $data_common_events = []
  $rpg_player_unsupported = []
  $rpg_player_transfer = nil
  $rpg_player_event_lists = {}
  $rpg_player_event_setup_error = nil
  $rpg_player_map_id = 0
  $rpg_player_last_message = nil
  $rpg_player_script_error = nil

  # Map trống (mặc định) — DataFileLoader wire map data sau (M6-test).
  map = Game_Map.new
  player = Game_Player.new(map)
  map.player = player
  map.interpreter = $game_interpreter
  $game_map = map
  $game_player = player

  # Window_Message nếu class đã được định nghĩa (WindowClasses.rb M6.4)
  if defined?(Window_Message)
    $game_message_window = Window_Message.new(0, 0, 400, 160)
  end

  true
end

# ---------- Per-frame hook ----------
# M6.5: redefine rpg_player_advance_frame (bản M6.2 trong GameClasses.rb) —
# bổ sung message feed cho Window_Message. Gọi đầy đủ: map.update (chứa
# setup_starting_event → interpreter chạy event), player.update,
# interpreter.update, message feed.
def rpg_player_advance_frame
  map = $game_map
  if map
    map.update
    player = map.player
    player.update if player
  end
  interp = $game_interpreter
  interp.update if interp && interp.running?
  # Feed message text vào Window_Message mỗi frame (chỉ khi text đổi —
  # tránh re-render texture giống nhau mỗi frame).
  if $game_message_window && $game_message && $game_message.visible_message?
    text = $game_message.texts.join("\n")
    if $rpg_player_last_message != text
      $rpg_player_last_message = text
      $game_message_window.start_message(text, {}, {})
    end
  else
    $rpg_player_last_message = nil
  end
  true
end