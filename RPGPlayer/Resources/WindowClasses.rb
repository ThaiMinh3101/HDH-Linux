# RPGPlayer/Resources/WindowClasses.rb
# M6.4 — Window_Base / Window_Message / Window_Selectable cho RPG Maker VX Ace (RGSS3).
#
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
# RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
# mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).
#
# LƯU Ý KIẾN TRÚC:
#   - Window là RGSS BUILT-IN class (định nghĩa trong C — mruby_bridge.c):
#     Window.new(x, y, width, height), x=, y=, width=, height=, opacity=,
#     visible=, z=, windowskin=, contents=, refresh.
#   - Window_Base/Window_Message/Window_Selectable là các class được GAME
#     định nghĩa (default scripts trong Scripts.rvdata2). Bản M6.4 này chạy
#     như scaffold/test base: khi game thật load, default scripts sẽ redefine
#     các class này (Ruby cho phép redefine) và dùng Window built-in của ta.
#
# PHẠM VI M6.4:
#   - Window_Base: vẽ khung + text qua Window#contents= (text đơn giản),
#     refresh tự động khi set geometry.
#   - Window_Message: hiển thị hội thoại, control codes cơ bản:
#       \C[n] đổi màu, \N[n] tên actor, \V[n] biến, \\ dấu gạch chéo,
#       \. dừng 1/4 giây, \| dừng 1 giây, \! chờ input, \> / \< tốc độ,
#       \^ không chờ input ở cuối.
#     Text speed (ký tự/frame) điều khiển qua @text_speed.
#   - Window_Selectable: danh sách chọn, di chuyển cursor lên/xuống.
#
# NỢ KỸ THUẬT (ghi nhận M6.4):
#   - Text rendering thật (màu, font VL Gothic) do Swift WindowRenderer lo —
#     control codes \C[n] chỉ parsed trong Ruby, chưa ảnh hưởng màu hiển thị.
#   - Window_Message chưa tích hợp input (chờ nút) — chỉ hiển thị text tĩnh.

# ─────────────────────────────────────────────────────────────────────────────
# Window_Base — class nền cho mọi cửa sổ
# ─────────────────────────────────────────────────────────────────────────────

class Window_Base < Window
  attr_accessor :opening
  attr_accessor :closing
  attr_accessor :text_speed
  attr_accessor :contents_text

  # Tạo window với geometry + làm mới hiển thị.
  def initialize(x, y, width, height)
    super(x, y, width, height)
    @opening = false
    @closing = false
    @text_speed = 1          # ký tự/frame (RGSS3 mặc định ~1-2)
    @contents_text = ""
    refresh
  end

  # Refesh toàn bộ — gọi contents= để đẩy text xuống Swift renderer.
  def refresh
    self.contents = @contents_text
  end

  # Đặt text hiển thị (đè contents= của Window built-in).
  def draw_text_ex(x, y, text)
    @contents_text = text
    refresh
  end

  # Vẽ text đơn giản tại vị trí (bản M6.4: chỉ set text toàn cục).
  def draw_text(x, y, width, height, text, align = 0)
    @contents_text = text
    refresh
  end

  # Kích thước chữ (RGSS3: 24px chuẩn cho VX Ace messages).
  def standard_padding
    16
  end

  # Clear nội dung.
  def clear
    @contents_text = ""
    refresh
  end

  # Cập nhật mỗi frame (mở/đóng window — bản M6.4 tối thiểu).
  def update
    super if defined?(super)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window_Message — hiển thị hội thoại
# ─────────────────────────────────────────────────────────────────────────────

class Window_Message < Window_Base
  # Các control code RGSS3 (màu, tên, biến, tốc độ...).
  #
  # Quy ước sentinel: \e (ESC, 0x1B) — text game RGSS không chứa ESC nên
  # an toàn làm placeholder. Mọi backslash trong input được thay bằng ESC
  # TRƯỚC, sau đó mới convert \C[n]/\N[n]/\V[n] (regex `\eC[...]` chỉ match
  # control code thật — không ăn nhầm literal backslash), cuối cùng ESC còn
  # sót (tức `\\` trong input) thành 1 literal backslash — đúng hành vi RGSS3.
  def convert_escape_characters(text)
    result = text.to_s.gsub(/\\/) { "\e" }     # mọi \ → ESC sentinel
    result.gsub!(/\eC\[(\d+)\]/, "\x01[\\1]")  # \C[n] → màu
    result.gsub!(/\eN\[(\d+)\]/, "\x02[\\1]")  # \N[n] → tên actor
    result.gsub!(/\eV\[(\d+)\]/, "\x03[\\1]")  # \V[n] → biến
    # Chạy ESC còn sót (`\\` trong input) → collapse còn 1 literal backslash
    # (hành vi chuẩn RGSS3: \\ hiển thị 1 dấu \).
    result.gsub!(/\e+/, "\\")
    result
  end

  # Thay \V[n] bằng giá trị biến (cần Game_Variables — bản M6.4 fallback 0).
  def obtain_escape_code
    @interpreter_text.to_s
  end

  # Hiển thị message box: parse control codes + set text.
  def start_message(text, actor_names = {}, variables = {})
    converted = convert_escape_characters(text)
    # \N[n] → tên actor (fallback "Actor n" nếu không có)
    converted = converted.gsub(/\x02\[(\d+)\]/) do
      id = Regexp.last_match(1).to_i
      actor_names[id] || "Actor #{id}"
    end
    # \V[n] → giá trị biến (fallback 0)
    converted = converted.gsub(/\x03\[(\d+)\]/) do
      id = Regexp.last_match(1).to_i
      (variables[id] || 0).to_s
    end
    # \C[n] → giữ nguyên (Swift renderer sẽ xử lý màu trong tương lai)
    converted = converted.gsub(/\x01\[(\d+)\]/, "")
    # \. = dừng ngắn, \| = dừng dài, \! = chờ input, \^ = không chờ cuối
    # (bản M6.4: thay bằng khoảng trắng — chưa tích hợp wait/input).
    converted = converted.gsub(/\\[.|\|\!\^]/, " ")
    draw_text_ex(0, 0, converted)
  end

  # Tốc độ hiện chữ (ký tự/frame) — bản M6.4: text hiện toàn bộ ngay.
  def update_message_speed
    @text_speed
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Window_Selectable — danh sách chọn
# ─────────────────────────────────────────────────────────────────────────────

class Window_Selectable < Window_Base
  attr_accessor :index
  attr_accessor :item_max
  attr_accessor :cursor_visible

  def initialize(x, y, width, height)
    super(x, y, width, height)
    @index = 0
    @item_max = 0
    @cursor_visible = true
    @item_height = 24
    @cursor_state = false
  end

  # Danh sách item (bản M6.4: array string).
  def draw_items(items)
    @item_max = items.size
    # Nối các item thành text nhiều dòng (Swift renderer sẽ hiển thị)
    text = items.each_with_index.map do |item, i|
      prefix = (i == @index && @cursor_visible) ? "> " : "  "
      "#{prefix}#{item}\n"
    end.join
    draw_text_ex(0, 0, text)
  end

  # Di chuyển cursor lên/xuống (mặc định: xuống).
  def move_cursor(down = true)
    return if @item_max <= 0
    step = down ? 1 : -1
    @index = (@index + step) % @item_max
    @index = 0 if @index < 0
    refresh_cursor
  end

  def cursor_down
    move_cursor(true)
  end

  def cursor_up
    move_cursor(false)
  end

  def refresh_cursor
    # Bản M6.4: chỉ set cursor state — text vẽ lại khi gọi draw_items.
    @cursor_state = true
  end

  def selected_item
    @index
  end
end