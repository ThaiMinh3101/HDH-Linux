# RPG Player — EventClasses.rb (M6.5)
# Clean-room implementation based on the public RGSS3 Reference Manual
# (help file shipped with RPG Maker VX Ace). No code was copied or derived
# from any open-source RGSS engine.
#
# Provides:
#   Game_Message     — message buffer for Window_Message (via C bridge)
#   Game_Interpreter — RGSS3-style event command interpreter
#   rpg_player_bootstrap / rpg_player_advance_frame — Swift entry points
#
# LƯU Ý: Game_* runtime classes (Game_Map, Game_Player, Game_Switches, ...)
# định nghĩa ở GameClasses.rb (M6.2) — file này KHÔNG redefine chúng. Chỉ
# thêm Game_Message + Game_Interpreter + gluing.
#
# M6.5 opcodes: 101, 102, 111, 121, 122, 201, 230, 355 (+ structure 402/403/404/411/412)
# Stubs: 117 Common Event, 123 Self Switch, 250 SE

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
# khi gặp lệnh chờ (Wait 230 / message đang hiển thị).
class Game_Interpreter
  COMMANDS_PER_FRAME = 40

  attr_reader :depth, :index, :list, :event_id
  attr_accessor :wait_count, :message_waiting
  attr_accessor :map_id

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
    steps = 0
    while @index < @list.size
      command = @list[@index]
      unless command
        @index += 1
        next
      end
      code = command.is_a?(Array) ? command[0] : (command.respond_to?(:code) ? command.code : 0)
      indent = command.is_a?(Array) ? (command[1] || 0) : (command.respond_to?(:indent) ? command.indent : 0)
      if code == 411 && @branch[indent]
        # Nhánh TRUE: gặp Else cùng indent → nhảy thẳng tới Branch End
        # (bỏ qua else body — đúng RGSS3: else chỉ chạy khi điều kiện false).
        @index = find_skip_to_412(indent)
        next
      end
      if [402, 403, 404, 411, 412].include?(code)
        @index += 1
        next
      end
      run_command(code, indent, command)
      @index += 1
      steps += 1
      break if @wait_count > 0 || @message_waiting
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
    when 117 then command_117(indent, command)
    when 121 then command_121(indent, command)
    when 122 then command_122(indent, command)
    when 123 then command_123(indent, command)
    when 201 then command_201(indent, command)
    when 230 then command_230(indent, command)
    when 250 then command_250(indent, command)
    when 401 then  # text line — đã được command_101 tiêu thụ
    when 355, 655 then command_355(indent, command)
    when 0
    else
      record_unsupported(code)
    end
  end

  def record_unsupported(code)
    $rpg_player_unsupported = [] unless $rpg_player_unsupported
    $rpg_player_unsupported.push(code) unless $rpg_player_unsupported.include?(code)
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
    return unless $game_win_message
    $game_win_message.start_message($game_message.texts.join("\n"), {}, {})
  end

  # ---- Event Commands (Nhóm A + B theo RGSS3 Reference Manual) ----

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
      break unless cmd_indent(c) == indent
      cparams = cmd_params(c)
      text = cparams.is_a?(Array) && cparams[0] ? cparams[0].to_s : ""
      $game_message.add(text)
      i += 1
    end
    @index = i - 1
    @message_waiting = true
    feed_message_to_window
  end

  # 102 Show Choices — hiển thị danh sách lựa chọn (chưa xử lý chọn, hiển thị là đủ)
  def command_102(indent, command)
    params = cmd_params(command)
    $game_message.clear
    if params.is_a?(Array)
      choices = params[0].is_a?(Array) ? params[0] : []
      $game_message.choices = choices.map(&:to_s)
      $game_message.choice_max = choices.size
      $game_message.choice_cancel_type = (params[1] || 0).to_i
    end
    @message_waiting = true
    feed_message_to_window
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

  # Nhảy tới Else (411) hoặc Branch End (412) cùng indent
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
      if ccode == 411 && cindent == indent && depth == 0
        @index = i
        return
      end
      i += 1
    end
    @index = @list.size
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
  #             operand_type(0 const,1 var,2 random,3 data), operand, operand2]
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
      record_unsupported(122)
      0  # Game Data (map id, party size, ...) chưa hỗ trợ
    else
      0
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
      $game_player.moveto(x, y)
      $game_player.direction = direction if direction != 0
    else
      # Chưa có $game_player (test core) — dùng $rpg_player_transfer
      # để Swift/Scene biết vị trí mới.
    end
    $rpg_player_transfer = { :map_id => map_id, :x => x, :y => y, :direct => direct }
    @wait_count = 5 if direct == 0
  end

  # 230 Wait — params = [frames]
  def command_230(indent, command)
    params = cmd_params(command)
    @wait_count = (params.is_a?(Array) && params[0]) ? params[0].to_i : 0
  end

  # 117 Common Event — chưa hỗ trợ, báo unsupported
  def command_117(indent, command)
    record_unsupported(117)
  end

  # 123 Self Switch — params = [switch_id("A".."D"), value(0/1)]
  def command_123(indent, command)
    params = cmd_params(command)
    return unless params.is_a?(Array)
    key = "#{@map_id},#{@event_id},#{params[0]}"
    $game_self_switches[key] = ((params[1] || 0).to_i == 1) if $game_self_switches
  end

  # 250 Play SE — chưa hỗ trợ audio, báo unsupported
  def command_250(indent, command)
    record_unsupported(250)
  end

  # 355/655 Script — chưa hỗ trợ eval script, báo unsupported
  def command_355(indent, command)
    params = cmd_params(command)
    script = params.is_a?(Array) ? params[0].to_s : params.to_s
    record_unsupported(355)
  end
end

# ---------- Bootstrap ----------
# Swift set global $rpg_player_boot_json (Ruby Hash literal: { "map_id" => n,
# "x" => n, "y" => n, "events" => {map_id_str => [commands...]} }) rồi gọi
# rpg_player_bootstrap (niladic — mrb_bridge_call_global không truyền được args).
# ⚠️ mruby build KHÔNG có mruby-json mgem → dùng eval (mruby-eval có sẵn, xem
# build_config_ios.rb) để biến boot string thành Ruby Hash. Giá trị do chính app
# tạo từ file người dùng tự import — cùng trust model với RGSS scripts.
#
# Game_Map/Game_Player/Game_Switches/... dùng class từ GameClasses.rb (M6.2).
def rpg_player_bootstrap
  $game_switches      = Game_Switches.new
  $game_variables     = Game_Variables.new
  $game_self_switches = Game_SelfSwitches.new
  $game_message       = Game_Message.new
  $game_interpreter   = Game_Interpreter.new
  $game_win_message   = nil
  $rpg_player_unsupported = []
  $rpg_player_transfer = nil
  $rpg_player_event_lists = {}
  $rpg_player_event_setup_error = nil
  $rpg_player_map_id = 0
  $rpg_player_last_message = nil

  # Map trống (mặc định) — DataFileLoader wire map data sau (M6-test).
  map = Game_Map.new
  player = Game_Player.new(map)
  map.player = player
  map.interpreter = $game_interpreter
  $game_map = map
  $game_player = player

  boot = $rpg_player_boot_json
  if boot && !boot.empty?
    begin
      parsed = eval(boot)
      if parsed.is_a?(Hash)
        $rpg_player_map_id = (parsed["map_id"] || 0).to_i
        $game_interpreter.map_id = $rpg_player_map_id
        px = (parsed["x"] || 0).to_i
        py = (parsed["y"] || 0).to_i
        $game_player.moveto(px, py)
        events = parsed["events"]
        if events.is_a?(Hash)
          parsed_events = {}
          events.each do |k, v|
            if v.is_a?(Array)
              parsed_events[k] = v
            elsif v.is_a?(Hash)
              # Swift gửi dạng { "map_1" => { "events": [ { "id": 1, "list": [...] } ] } }
              elist = v["events"] || v["list"]
              parsed_events[k] = elist.is_a?(Array) ? elist : []
            end
          end
          $rpg_player_event_lists = parsed_events
        end
      else
        $rpg_player_event_setup_error = "Boot JSON invalid (not Hash)"
      end
    rescue => e
      $rpg_player_event_setup_error = e.message
    end
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
  if $game_win_message && $game_message && $game_message.visible_message?
    text = $game_message.texts.join("\n")
    if $rpg_player_last_message != text
      $rpg_player_last_message = text
      $game_win_message.start_message(text, {}, {})
    end
  else
    $rpg_player_last_message = nil
  end
  true
end
