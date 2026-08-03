# RPGPlayer/Resources/RGSSBuiltins.rb
# M6.3 — RGSS built-in classes (Table) cho RPG Maker VX Ace (RGSS3).
#
# CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
# RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
# mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).
#
# Table là RGSS built-in class — dữ liệu lưu trong .rvdata2 dưới dạng object
# với instance variables: @dim, @xsize, @ysize, @zsize, @data (Array phẳng).
# Marshal.load Map.data / Tileset.flags sẽ tạo object Table qua binding này.
#
# Load qua mrb_load_nstring() TRƯỚC RPGClasses.rb (Table cần cho Marshal.load
# RPG::Map.data / RPG::Tileset.flags).

class Table
  attr_accessor :dim
  attr_accessor :xsize
  attr_accessor :ysize
  attr_accessor :zsize
  attr_accessor :data

  def initialize(xsize = 0, ysize = 1, zsize = 1)
    @dim = 1
    @dim = 2 if ysize > 1
    @dim = 3 if zsize > 1
    @xsize = xsize
    @ysize = ysize
    @zsize = zsize
    @data = Array.new(xsize * ysize * zsize, 0)
  end

  # table[x]           — 1D
  # table[x, y]        — 2D
  # table[x, y, z]     — 3D
  def [](*args)
    return 0 unless @data
    x = args[0] || 0
    y = args[1] || 0
    z = args[2] || 0
    index = x + y * @xsize + z * @xsize * @ysize
    @data[index] || 0
  end

  # table[x] = v       — 1D
  # table[x, y] = v    — 2D
  # table[x, y, z] = v — 3D
  def []=(*args)
    return nil unless @data
    value = args.pop
    x = args[0] || 0
    y = args[1] || 0
    z = args[2] || 0
    index = x + y * @xsize + z * @xsize * @ysize
    @data[index] = value
  end

  def resize(xsize, ysize = 1, zsize = 1)
    new_data = Array.new(xsize * ysize * zsize, 0)
    [@xsize, xsize].min.times do |ix|
      [@ysize, ysize].min.times do |iy|
        [@zsize, zsize].min.times do |iz|
          old_index = ix + iy * @xsize + iz * @xsize * @ysize
          new_index = ix + iy * xsize + iz * xsize * ysize
          new_data[new_index] = @data[old_index] if @data
        end
      end
    end
    @dim = 1
    @dim = 2 if ysize > 1
    @dim = 3 if zsize > 1
    @xsize = xsize
    @ysize = ysize
    @zsize = zsize
    @data = new_data
  end
end