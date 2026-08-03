# RPGPlayer/EngineRGSS/RPGClasses.rb
# M6.1 — RPG::* data classes cho RPG Maker VX Ace (RGSS3).
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai).
# KHÔNG tham chiếu cấu trúc field từ engine mã nguồn mở GPL/LGPL.
# Thứ tự attr_accessor = thứ tự Marshal ghi instance variable (sai thứ tự
# sẽ đọc lệch dữ liệu). Xác minh bằng RPGClassesTests.swift đối chiếu
# instance variable names từ file .rvdata2 thật.
# Load qua mrb_load_nstring() ngay sau mrb_open(), trước Scripts.rvdata2.

module RPG

  # ── BaseItem: cha chung của Skill/Item/Weapon/Armor/Enemy/State ──
  class BaseItem
    attr_accessor :id
    attr_accessor :name
    attr_accessor :icon_index
    attr_accessor :description
    attr_accessor :features   # Array of RPG::Feature
    attr_accessor :note
  end

  # ── Feature: đơn vị tính năng (VX Ace dùng hệ thống features) ──
  class Feature
    attr_accessor :code
    attr_accessor :data_id
    attr_accessor :value
  end

  # ── UsableItem: cha của Skill, Item ──
  class UsableItem < BaseItem
    attr_accessor :scope
    attr_accessor :occasion
    attr_accessor :speed
    attr_accessor :success_rate
    attr_accessor :repeats
    attr_accessor :tp_gain
    attr_accessor :hit_type
    attr_accessor :animation_id
    attr_accessor :damage      # RPG::Damage
    attr_accessor :effects     # Array of RPG::Effect
  end

  # ── Damage: công thức sát thương ──
  class Damage
    attr_accessor :type
    attr_accessor :element_id
    attr_accessor :formula
    attr_accessor :variance
    attr_accessor :critical
  end

  # ── Effect: hiệu ứng ──
  class Effect
    attr_accessor :code
    attr_accessor :data_id
    attr_accessor :value1
    attr_accessor :value2
  end

  # ── EquipItem: cha của Weapon, Armor ──
  class EquipItem < BaseItem
    attr_accessor :price
    attr_accessor :etype_id
    attr_accessor :params      # Array[8]
  end

  # ── Skill ──
  class Skill < UsableItem
    attr_accessor :stype_id
    attr_accessor :mp_cost
    attr_accessor :tp_cost
    attr_accessor :message1
    attr_accessor :message2
    attr_accessor :required_wtype_id1
    attr_accessor :required_wtype_id2
  end

  # ── Item ──
  class Item < UsableItem
    attr_accessor :itype_id
    attr_accessor :price
    attr_accessor :consumable
  end

  # ── Weapon ──
  class Weapon < EquipItem
    attr_accessor :animation_id
  end

  # ── Armor ──
  class Armor < EquipItem
    attr_accessor :atype_id
  end

  # ── Actor ──
  class Actor
    attr_accessor :id
    attr_accessor :name
    attr_accessor :class_id
    attr_accessor :initial_level
    attr_accessor :max_level
    attr_accessor :profile
    attr_accessor :nickname
    attr_accessor :character_name
    attr_accessor :character_index
    attr_accessor :face_name
    attr_accessor :face_index
    attr_accessor :equips      # Array[5]
    attr_accessor :features    # Array of RPG::Feature
    attr_accessor :note
  end

  # ── Class (nhân vật class) ──
  class Class
    attr_accessor :id
    attr_accessor :name
    attr_accessor :exp_params  # Array[3]
    attr_accessor :params      # Array[8] of Array[max_level]
    attr_accessor :learnings   # Array of RPG::Class::Learning
    attr_accessor :features    # Array of RPG::Feature
    attr_accessor :note

    class Learning
      attr_accessor :level
      attr_accessor :skill_id
    end
  end

  # ── Enemy ──
  class Enemy < BaseItem
    attr_accessor :battler_name
    attr_accessor :battler_hue
    attr_accessor :params      # Array[8]
    attr_accessor :exp
    attr_accessor :gold
    attr_accessor :drop_items  # Array of RPG::Enemy::DropItem
    attr_accessor :actions     # Array of RPG::Enemy::Action
    attr_accessor :features    # Array of RPG::Feature

    class DropItem
      attr_accessor :kind
      attr_accessor :data_id
      attr_accessor :denominator
    end

    class Action
      attr_accessor :skill_id
      attr_accessor :condition_type
      attr_accessor :condition_param1
      attr_accessor :condition_param2
      attr_accessor :rating
    end
  end

  # ── Troop ──
  class Troop
    attr_accessor :id
    attr_accessor :name
    attr_accessor :members     # Array of RPG::Troop::Member
    attr_accessor :pages       # Array of RPG::Troop::Page

    class Member
      attr_accessor :enemy_id
      attr_accessor :x
      attr_accessor :y
      attr_accessor :hidden
    end

    class Page
      attr_accessor :condition  # RPG::Troop::Page::Condition
      attr_accessor :span
      attr_accessor :list       # Array of RPG::EventCommand

      class Condition
        attr_accessor :turn_ending
        attr_accessor :turn_valid
        attr_accessor :turn_a
        attr_accessor :turn_b
        attr_accessor :enemy_valid
        attr_accessor :enemy_index
        attr_accessor :enemy_hp
        attr_accessor :actor_valid
        attr_accessor :actor_id
        attr_accessor :actor_hp
        attr_accessor :switch_valid
        attr_accessor :switch_id
      end
    end
  end

  # ── State ──
  class State < BaseItem
    attr_accessor :restriction
    attr_accessor :priority
    attr_accessor :remove_at_battle_end
    attr_accessor :remove_by_restriction
    attr_accessor :auto_removal_timing
    attr_accessor :min_turns
    attr_accessor :max_turns
    attr_accessor :remove_by_damage
    attr_accessor :chance_by_damage
    attr_accessor :remove_by_walking
    attr_accessor :steps_to_remove
    attr_accessor :message1
    attr_accessor :message2
    attr_accessor :message3
    attr_accessor :message4
    attr_accessor :features    # Array of RPG::Feature
    attr_accessor :note
  end

  # ── Animation ──
  class Animation
    attr_accessor :id
    attr_accessor :name
    attr_accessor :animation1_name
    attr_accessor :animation1_hue
    attr_accessor :animation2_name
    attr_accessor :animation2_hue
    attr_accessor :position
    attr_accessor :frame_max
    attr_accessor :frames      # Array of RPG::Animation::Frame
    attr_accessor :timings     # Array of RPG::Animation::Timing

    class Frame
      attr_accessor :cell_max
      attr_accessor :cell_data  # Table (2D: [cell_max][8])
    end

    class Timing
      attr_accessor :frame
      attr_accessor :se         # RPG::AudioFile
      attr_accessor :flash_scope
      attr_accessor :flash_color
      attr_accessor :flash_duration
    end
  end

  # ── Tileset ──
  class Tileset
    attr_accessor :id
    attr_accessor :name
    attr_accessor :tileset_names  # Array[9]
    attr_accessor :flags          # Table (1D)
    attr_accessor :note
  end

  # ── CommonEvent ──
  class CommonEvent
    attr_accessor :id
    attr_accessor :name
    attr_accessor :trigger
    attr_accessor :switch_id
    attr_accessor :list        # Array of RPG::EventCommand
  end

  # ── System ──
  class System
    attr_accessor :game_title
    attr_accessor :version_id
    attr_accessor :japanese
    attr_accessor :party_members   # Array of actor id
    attr_accessor :currency_unit
    attr_accessor :skill_types     # Array of String
    attr_accessor :weapon_types    # Array of String
    attr_accessor :armor_types     # Array of String
    attr_accessor :elements        # Array of String
    attr_accessor :switches        # Array of String
    attr_accessor :variables       # Array of String
    attr_accessor :boat            # RPG::Vehicle
    attr_accessor :ship            # RPG::Vehicle
    attr_accessor :airship         # RPG::Vehicle
    attr_accessor :title1_name
    attr_accessor :title2_name
    attr_accessor :opt_draw_title
    attr_accessor :opt_use_midnight
    attr_accessor :opt_transition
    attr_accessor :opt_followers
    attr_accessor :opt_slip_death
    attr_accessor :opt_floor_death
    attr_accessor :opt_display_tp
    attr_accessor :opt_extra_exp
    attr_accessor :opt_cruel_commands
    attr_accessor :start_map_id
    attr_accessor :start_x
    attr_accessor :start_y
    attr_accessor :battleback_name
    attr_accessor :battler_name
    attr_accessor :battler_hue
    attr_accessor :edit_map_id
    attr_accessor :terms         # RPG::Terms
    attr_accessor :test_battlers # Array of RPG::TestBattler
    attr_accessor :sounds        # Array of RPG::AudioFile
  end

  # ── Vehicle: phương tiện (boat, ship, airship) ──
  class Vehicle
    attr_accessor :character_name
    attr_accessor :character_index
    attr_accessor :bgm          # RPG::AudioFile
    attr_accessor :start_map_id
    attr_accessor :start_x
    attr_accessor :start_y
  end

  # ── Terms: thuật ngữ UI ──
  class Terms
    attr_accessor :basic        # Array[8]
    attr_accessor :params       # Array[8]
    attr_accessor :etypes       # Array[5]
    attr_accessor :commands     # Array[24]
  end

  # ── TestBattler: dùng trong System.test_battlers ──
  class TestBattler
    attr_accessor :actor_id
    attr_accessor :level
    attr_accessor :equips       # Array[5]
  end

  # ── AudioFile: BGM/BGS/ME/SE dùng chung ──
  class AudioFile
    attr_accessor :name
    attr_accessor :volume
    attr_accessor :pitch
  end

  # ── Event: sự kiện trên map ──
  class Event
    attr_accessor :id
    attr_accessor :name
    attr_accessor :x
    attr_accessor :y
    attr_accessor :pages        # Array of RPG::Event::Page

    class Page
      attr_accessor :condition  # RPG::Event::Page::Condition
      attr_accessor :graphic    # RPG::Event::Page::Graphic
      attr_accessor :move_type
      attr_accessor :move_speed
      attr_accessor :move_frequency
      attr_accessor :move_route # RPG::MoveRoute
      attr_accessor :walk_anime
      attr_accessor :step_anime
      attr_accessor :direction_fix
      attr_accessor :through
      attr_accessor :priority_type
      attr_accessor :trigger
      attr_accessor :list       # Array of RPG::EventCommand

      class Condition
        attr_accessor :switch1_valid
        attr_accessor :switch1_id
        attr_accessor :switch2_valid
        attr_accessor :switch2_id
        attr_accessor :variable_valid
        attr_accessor :variable_id
        attr_accessor :variable_value
        attr_accessor :self_switch_valid
        attr_accessor :self_switch_ch
      end

      class Graphic
        attr_accessor :tile_id
        attr_accessor :character_name
        attr_accessor :character_index
        attr_accessor :direction
        attr_accessor :pattern
      end
    end
  end

  # ── EventCommand: lệnh sự kiện ──
  class EventCommand
    attr_accessor :code
    attr_accessor :indent
    attr_accessor :parameters   # Array
  end

  # ── MoveRoute: lộ trình di chuyển ──
  class MoveRoute
    attr_accessor :repeat
    attr_accessor :skippable
    attr_accessor :wait
    attr_accessor :list         # Array of RPG::MoveCommand
  end

  # ── MoveCommand: lệnh di chuyển ──
  class MoveCommand
    attr_accessor :code
    attr_accessor :parameters   # Array
  end

  # ── Map: dữ liệu map ──
  class Map
    attr_accessor :display_name
    attr_accessor :tileset_id
    attr_accessor :width
    attr_accessor :height
    attr_accessor :scroll_type
    attr_accessor :specify_battleback
    attr_accessor :battleback1_name
    attr_accessor :battleback2_name
    attr_accessor :autoplay_bgm
    attr_accessor :bgm           # RPG::AudioFile
    attr_accessor :autoplay_bgs
    attr_accessor :bgs           # RPG::AudioFile
    attr_accessor :encounter_list  # Array of troop id
    attr_accessor :encounter_step
    attr_accessor :parallax_name
    attr_accessor :parallax_loop_x
    attr_accessor :parallax_loop_y
    attr_accessor :parallax_sx
    attr_accessor :parallax_sy
    attr_accessor :parallax_show
    attr_accessor :note
    attr_accessor :data          # Table (3D: [width][height][4])
    attr_accessor :events        # Hash (id → RPG::Event)
  end

  # ── MapInfo: thông tin map trong MapInfos.rvdata2 ──
  class MapInfo
    attr_accessor :name
    attr_accessor :parent_id
    attr_accessor :order
    attr_accessor :expanded
    attr_accessor :scroll_x
    attr_accessor :scroll_y
  end

end