# RPGPlayer/Resources/BattleClasses.rb
# M7 — Battle runtime classes cho RPG Maker VX Ace (RGSS3).
#
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
# RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
# mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).
#
# Mục tiêu M7 bước 1: script ATB (index 147-155) load được KHÔNG lỗi cú pháp,
# trận đấu vào được không crash (dù gauge/visual chưa đúng). Các class này là
# SKELETON tối thiểu — script ATB sẽ redefine/override chúng (Ruby cho phép).
#
# Load qua mrb_load_nstring() SAU GameClasses.rb, TRƯỚC Scripts.rvdata2.

# ─────────────────────────────────────────────────────────────────────────────
# Game_ActionResult — kết quả hành động (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_ActionResult
  attr_accessor :used
  attr_accessor :missed
  attr_accessor :evaded
  attr_accessor :critical
  attr_accessor :success
  attr_accessor :hp_damage
  attr_accessor :mp_damage
  attr_accessor :tp_damage
  attr_accessor :hp_drain
  attr_accessor :mp_drain
  attr_accessor :added_states
  attr_accessor :removed_states
  attr_accessor :added_buffs
  attr_accessor :added_debuffs
  attr_accessor :removed_buffs
  # M7: ATB chant/ap control messages
  attr_accessor :chant_cancel_state_messages
  attr_accessor :chant_control_state_messages
  attr_accessor :ap_control_state_messages

  def initialize(battler)
    @battler = battler
    clear
  end

  def clear
    @used = false
    @missed = false
    @evaded = false
    @critical = false
    @success = false
    @hp_damage = 0
    @mp_damage = 0
    @tp_damage = 0
    @hp_drain = 0
    @mp_drain = 0
    @added_states = []
    @removed_states = []
    @added_buffs = []
    @added_debuffs = []
    @removed_buffs = []
    clear_ap_control_state_messages
  end

  def clear_status_effects
    @added_states = []
    @removed_states = []
    @added_buffs = []
    @added_debuffs = []
    @removed_buffs = []
  end

  def clear_ap_control_state_messages
    @chant_cancel_state_messages = []
    @chant_control_state_messages = []
    @ap_control_state_messages = []
  end

  def status_affected?
    !(@added_states.empty? && @removed_states.empty? &&
      @added_buffs.empty? && @added_debuffs.empty? && @removed_buffs.empty?)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_BattlerBase — nền tảng battler (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_BattlerBase
  attr_accessor :hp
  attr_accessor :mp
  attr_accessor :tp
  attr_accessor :result

  def initialize
    @hp = 0
    @mp = 0
    @tp = 0
    @result = Game_ActionResult.new(self)
    @states = []
    @state_turns = {}
    @state_frames = {}
    @buffs = {}
  end

  # ── Stats (skeleton — script ATB dùng agi) ──
  def mhp
    100
  end

  def mmp
    50
  end

  def max_tp
    100
  end

  def agi
    10
  end

  def max_slip_damage
    10
  end

  # ── States ──
  def states
    @states ||= []
  end

  def state?(state_id)
    states.include?(state_id)
  end

  def death_state?
    state?(1)  # RGSS3: state 1 = death
  end

  def confusion?
    state?(2)  # RGSS3: state 2 = confusion
  end

  def add_state(state_id)
    return unless state_addable?(state_id)
    add_new_state(state_id) unless state?(state_id)
    reset_state_counts(state_id)
    @result.added_states.push(state_id).uniq!
  end

  def add_new_state(state_id)
    states.push(state_id)
  end

  def remove_state(state_id)
    states.delete(state_id)
    @result.removed_states.push(state_id).uniq!
  end

  def erase_state(state_id)
    states.delete(state_id)
  end

  def clear_states
    @states = []
    @state_turns = {}
    @state_frames = {}
  end

  def reset_state_counts(state_id)
    @state_turns[state_id] = 1
    @state_frames[state_id] = 360000
  end

  def remove_states_auto(timing)
    states.each do |state_id|
      state = $data_states ? $data_states[state_id] : nil
      next unless state
      next unless state.auto_removal_timing == timing
      remove_state(state_id)
    end
  end

  def state_addable?(state_id)
    state = $data_states ? $data_states[state_id] : nil
    return false unless state
    !death_state? || state_id == 1
  end

  # ── Buffs (skeleton) ──
  def update_buff_turns
    # no-op skeleton
  end

  def remove_buffs_auto
    # no-op skeleton
  end

  # ── Features ──
  def feature_objects
    []
  end

  # ── Usable ──
  def movable?
    !death_state?
  end

  def alive?
    @hp > 0
  end

  def occasion_ok?(item)
    true
  end

  def usable?(item)
    return false unless item
    usable_item_conditions_met?(item)
  end

  def usable_item_conditions_met?(item)
    movable? && occasion_ok?(item)
  end

  def chant_sealed?
    false
  end

  # ── Regenerate (skeleton) ──
  def regenerate_hp
    # no-op
  end

  def regenerate_mp
    # no-op
  end

  def regenerate_tp
    # no-op
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Battler — battler đầy đủ (RGSS3) + ATB skeleton
# ─────────────────────────────────────────────────────────────────────────────

class Game_Battler < Game_BattlerBase
  attr_accessor :ap
  attr_accessor :turn_count
  attr_accessor :actions
  attr_accessor :current_action
  attr_accessor :last_choice_target_index
  attr_reader :chant_object
  attr_reader :chant_type

  def initialize
    super
    @ap = 0
    @turn_count = 1
    @actions = []
    @current_action = nil
    @last_choice_target_index = 0
    @next_ap = 0
    clear_chant
  end

  # ── ATB ──
  def clear_chant
    @chant_object = nil
    @chant_type = nil
    @chant_count = nil
    @max_chant_count = nil
    @chant_action_forced = false
    @chant_target_index = nil
    @act_chant = false
    @chant_states = nil
  end

  def chanting?
    @chant_type
  end

  def act_chant?
    return false if !chanting? || @chant_count < @max_chant_count
    true
  end

  def set_chant(object)
    chant_param = object.chant
    return unless chant_param
    @chant_object = object
    @chant_type = chant_param[0]
    @chant_count = 0
    @max_chant_count = chant_param[1] + rand(chant_param[2] + 1)
    @chant_target_index = @current_action ? @current_action.target_index : nil
    @chant_states = []
  end

  def ap_rate
    if chanting?
      rate = @max_chant_count && @max_chant_count > 0 ? @chant_count.to_f / @max_chant_count : 0
    else
      rate = @ap.to_f / ATB::MAX_AP
    end
    rate = 1.0 if rate > 1
    rate
  end

  def ap_rate_100
    (ap_rate * 100).to_i
  end

  def frame_update
    ap_update
    state_frame_update
  end

  def ap_update
    point = ap_gain_point * ATB::REFRESH_FRAME
    if chanting?
      @chant_count += point
    else
      @ap += point
    end
  end

  def ap_gain_point
    result = agi
    result += ATB::FRAME_AP_GAIN
    result = ATB::GAUGE_GAIN_MIN if result < ATB::GAUGE_GAIN_MIN
    result
  end

  def make_start_ap(mode)
    rate =
      case mode
      when 1 then ATB::START_AP_RATE_PREEMPTIVE.dup
      when -1 then ATB::START_AP_RATE_SURPRISE.dup
      else ATB::START_AP_RATE_NORMAL.dup
      end
    rate = rate[0] + rand(rate[1] + 1)
    @ap = ATB::MAX_AP * rate / 100
  end

  def ap_reduce
    if chanting?
      @chant_count = @max_chant_count - 1 if @chant_count >= @max_chant_count
    else
      @ap = ATB::MAX_AP - 1 if @ap >= ATB::MAX_AP
    end
  end

  def ap_cancel_reduce
    if chanting?
      @chant_count = @max_chant_count if @chant_count == @max_chant_count - 1
    else
      @ap = ATB::MAX_AP if @ap == ATB::MAX_AP - 1
    end
  end

  def atb_identifier(n)
    [n, !enemy?, (enemy? ? @index : @actor_id)]
  end

  # ── Battle lifecycle ──
  def on_battle_start
    @turn_count = 1
  end

  def on_battle_end
    clear_chant
  end

  def on_action_end
    @turn_count += 1 if is_a?(Game_Enemy)
    @ap = ATB::MAX_AP * @next_ap / 100
    @next_ap = 0
  end

  def on_turn_end
    @result.clear
  end

  def inputable?
    movable?
  end

  def use_item(item)
    @next_ap = 0
  end

  def regenerate_all
    # no-op skeleton
  end

  def regenerate_all_after_action
    # no-op
  end

  def regenerate_all_before_action
    # no-op
  end

  def escape_failed_reset_ap
    rate = ATB::ESCAPE_FAILED_AP_RATE.dup
    rate = rate[0] + rand(rate[1] + 1)
    @ap = ATB::MAX_AP * rate / 100
  end

  def escape_failed_state_turn_count
    # no-op skeleton
  end

  def update_state_turns(timing)
    states.each do |state_id|
      state = $data_states ? $data_states[state_id] : nil
      next unless state
      next if state.auto_removal_timing != timing
      @state_turns[state_id] -= 1 if @state_turns[state_id] && @state_turns[state_id] > 0
    end
  end

  def remove_states_before_action
    false
  end

  def atb_state_on_action_end
    @result.clear
    update_state_turns(1)
    remove_states_auto(1)
  end

  def state_frame_update
    @result.clear_status_effects
    # no-op skeleton
  end

  def update_turnframe_state_turns(state, flag)
    # no-op
  end

  def remove_turnframe_state_by_turn(state)
    # no-op
  end

  def frame_state_regenerate(state)
    # no-op
  end

  def display_state_regenerate(hp_change, mp_change, tp_change, mode)
    # no-op
  end

  def display_state_regenerate_sv_pop(hp_change, mp_change, tp_change, mode)
    false
  end

  def display_state_regenerate_message(hp_change, mp_change, tp_change, mode)
    # no-op
  end

  def state_regenerate_message_set(id)
    ""
  end

  def chant_not_usable
    # no-op
  end

  def chant_force_action
    # no-op
  end

  def add_state_ap_control(state_id)
    # no-op
  end

  def state_chant_cancel(state_id)
    # no-op
  end

  def state_chant_control(state_id)
    # no-op
  end

  def state_ap_control(state_id)
    # no-op
  end

  def ap_control_resist_rate(state_id, control)
    1.0
  end

  def ap_control_no_resist?(resist, state_id)
    true
  end

  # ── Actions ──
  def make_actions
    # no-op skeleton
  end

  def clear_actions
    @actions = []
  end

  def force_action(skill_id, target_index)
    # no-op skeleton
  end

  def subject
    self
  end

  def valid?
    true
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Enemy — kẻ địch (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Enemy < Game_Battler
  attr_accessor :index
  attr_accessor :actor_id

  def initialize(index, enemy_id)
    super()
    @index = index
    @enemy_id = enemy_id
    @actor_id = 0
  end

  def enemy?
    true
  end

  def conditions_met_turns?(param1, param2)
    n = @turn_count
    if param2 == 0
      n == param1
    else
      n > 0 && n >= param1 && n % param2 == param1 % param2
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Unit — đơn vị (party/troop) (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Unit
  def members
    []
  end

  def alive_members
    members.select(&:alive?)
  end

  def movable_members
    members.select(&:movable?)
  end

  def make_actions
    members.each do |member|
      next if member.current_action && member.current_action.forcing
      member.make_actions
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Party — M7: thêm members/alive_members/movable_members (Game_Unit API)
# Game_Party được khai báo trong GameClasses.rb (không extends Game_Unit) —
# gắn thêm methods trực tiếp để BattleManager/Scene_Battle dùng được.
# ─────────────────────────────────────────────────────────────────────────────

class Game_Party
  def members
    @actors || []
  end

  def alive_members
    members.select(&:alive?)
  end

  def movable_members
    members.select(&:movable?)
  end

  def make_actions
    members.each do |member|
      next if member.current_action && member.current_action.forcing
      member.make_actions
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Troop — nhóm kẻ địch (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Troop < Game_Unit
  attr_accessor :members

  def initialize
    @members = []
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Game_Action — hành động (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Game_Action
  attr_accessor :target_index
  attr_accessor :forcing
  attr_reader :item

  def initialize(subject, forcing = false)
    @subject = subject
    @forcing = forcing
    @item = nil
    @target_index = -1
  end

  def set_skill(skill_id)
    @item = $data_skills ? $data_skills[skill_id] : nil
  end

  def set_item(item_id)
    @item = $data_items ? $data_items[item_id] : nil
  end

  def clear
    @item = nil
    @target_index = -1
  end

  def valid?
    (@forcing && @item) || @subject.usable?(@item)
  end

  def make_targets
    []
  end

  def subject
    @subject
  end

  def confusion_target
    nil
  end

  def targets_for_opponents
    []
  end

  def targets_for_friends
    []
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# BattleManager — module quản lý trận đấu (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

module BattleManager
  @action_battlers = []
  @action_forced = nil
  @preemptive = false
  @surprise = false

  class << self
    attr_accessor :action_battlers
    attr_accessor :action_forced
    attr_accessor :preemptive
    attr_accessor :surprise
  end

  def self.battle_start
    make_battlers_ap
    @preemptive = false
    @surprise = false
  end

  def self.make_battlers_ap
    mode = (@preemptive ? 1 : (@surprise ? -1 : 0))
    $game_party.members.each { |member| member.make_start_ap(mode) }
    $game_troop.members.each { |member| member.make_start_ap(mode * -1) }
  end

  def self.check_members
    ($game_party ? $game_party.alive_members : []) +
      ($game_troop ? $game_troop.alive_members : [])
  end

  def self.input_battler
    check_members.find { |battler| battler.ap >= ATB::MAX_AP }
  end

  def self.act_chant_battler
    check_members.find(&:act_chant?)
  end

  def self.act_forced_battler
    @action_forced if @action_forced && @action_forced.ap >= ATB::MAX_AP
  end

  def self.action_battler
    [act_forced_battler, act_chant_battler, input_battler].compact[0]
  end

  def self.make_action_orders
    @action_battlers = [action_battler].compact
    @action_battlers
  end

  def self.force_action(battler)
    @action_forced = battler
  end

  def self.clear_action_force
    @action_forced = nil
  end

  def self.in_turn?
    false
  end

  def self.judge_win_loss
    # no-op skeleton
  end

  def self.input_start
    false
  end

  def self.next_command
    # no-op
  end

  def self.actor
    nil
  end

  def self.process_escape
    false
  end

  def self.turn_start
    # no-op
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# SceneManager — module quản lý scene (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

module SceneManager
  @scene = nil

  class << self
    attr_accessor :scene
  end

  def self.scene
    @scene
  end

  def self.scene_is?(scene_class)
    @scene.is_a?(scene_class)
  end

  def self.run(scene_class)
    @scene = scene_class.new
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Scene_Base — scene nền (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────
# PHẢI khai báo TRƯỚC Scene_File/Scene_Battle (Ruby cần class cha tồn tại).

class Scene_Base
  def initialize
    # no-op
  end

  def update
    # no-op
  end

  def wait(duration)
    # no-op
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Scene_File / Scene_Load / Scene_Save — scene quản lý file (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────
# Script ATB (index 149) có `class Scene_Load < Scene_File` — nếu Scene_File
# không tồn tại, script load sẽ NameError. Skeleton này tránh cascade lỗi.

class Scene_File < Scene_Base
  def on_load_success
    # no-op
  end
end

class Scene_Load < Scene_File
  def on_load_success
    # no-op
  end
end

class Scene_Save < Scene_File
end

# ─────────────────────────────────────────────────────────────────────────────
# Scene_Battle — scene trận đấu (RGSS3) + ATB skeleton
# ─────────────────────────────────────────────────────────────────────────────

class Scene_Battle < Scene_Base
  attr_accessor :log_window

  def initialize
    super
    @log_window = nil
    @atb_wait_flag = false
    @escaped = nil
    @subject = nil
    @chant_battler = nil
  end

  def refresh_status
    # no-op
  end

  def update_for_wait
    # no-op
  end

  def show_animation(targets, animation_id)
    # no-op
  end

  def log_wait
    @log_window.wait if @log_window
  end

  def log_wait_and_clear
    @log_window.wait_and_clear if @log_window
  end

  def original_log_wait_and_clear(time = 1)
    wait(time * 2) if @log_window && @log_window.line_number > 0
    @log_window.clear if @log_window
  end

  def process_before_action
    # no-op
  end

  def turn_start
    # no-op
  end

  def start_party_command_selection
    # no-op
  end

  def start_actor_command_selection
    # no-op
  end

  def prior_command
    # no-op
  end

  def command_escape
    # no-op
  end

  def process_action_end
    # no-op
  end

  def process_forced_action
    false
  end

  def display_chant_message(object)
    # no-op
  end

  def chant_display_end_item
    # no-op
  end

  def battlers_frame_update
    all_alive_members.each(&:frame_update)
  end

  def battlers_ap_reduce
    all_alive_members.each do |battler|
      battler.ap_reduce if battler != BattleManager.action_battler
    end
  end

  def battlers_ap_cancel_reduce
    all_alive_members.each(&:ap_cancel_reduce)
  end

  def all_movable_members
    ($game_party ? $game_party.movable_members : []) +
      ($game_troop ? $game_troop.movable_members : [])
  end

  def all_alive_members
    ($game_party ? $game_party.alive_members : []) +
      ($game_troop ? $game_troop.alive_members : [])
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window_BattleLog — log trận đấu (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Window_BattleLog < Window_Selectable
  attr_accessor :message_speed

  def initialize
    super(0, 0, 544, 160)
    @message_speed = 1
    @lines = []
  end

  def line_number
    @lines.size
  end

  def max_line_number
    4
  end

  def last_text
    @lines.last
  end

  def add_text(text)
    @lines.push(text)
  end

  def clear
    @lines = []
  end

  def wait
    # no-op
  end

  def wait_and_clear
    clear
  end

  def back_one
    @lines.pop
  end

  def back_to(line_number)
    @lines = @lines[0, line_number]
  end

  def display_affected_status(target, item)
    # no-op
  end

  def display_auto_affected_status(target)
    # no-op
  end

  def display_added_ap_control_states(target)
    # no-op
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window_ItemList — danh sách item (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────
# RGSS3: Window_ItemList < Window_Selectable, quản lý danh sách item của player.
# Script ATB (index 152) có `class Window_BattleItem < Window_ItemList` — nếu
# Window_ItemList không tồn tại, script load sẽ NameError. Cần có skeleton này
# để script ATB load không crash.

class Window_ItemList < Window_Selectable
  def initialize(x, y, width, height)
    super
    @data = []
  end

  def enable?(item)
    true
  end

  def make_item_list
    # no-op skeleton
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window_BattleItem — danh sách item trong trận (RGSS3)
# ─────────────────────────────────────────────────────────────────────────────

class Window_BattleItem < Window_ItemList
  def enable?(item)
    BattleManager.action_battler.usable?(item)
  end
end
