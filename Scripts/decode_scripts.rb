#!/usr/bin/env ruby
# Decode Scripts.rvdata2 (RPG Maker VX Ace) — dùng Ruby system Marshal.load.
# Chỉ để đọc dữ liệu game người dùng tự import (bước chẩn đoán M7).
# Không phải code engine RGSS.
#
# Lọc theo INDEX trong mảng (0-based) — script id trong .rvdata2 là hash
# số ngẫu nhiên, không phải index.

require 'zlib'

path = ARGV[0] or abort("Usage: ruby decode_scripts.rb <Scripts.rvdata2> [start_index] [end_index]")
start_i = (ARGV[1] || 0).to_i
end_i   = (ARGV[2] || 99999).to_i

data = File.binread(path)
scripts = Marshal.load(data)  # Array of [id, name, compressed_data]

puts "Total scripts: #{scripts.size}"

scripts.each_with_index do |entry, i|
  next if i < start_i || i > end_i
  next unless entry.is_a?(Array) && entry.size == 3
  sid, name, comp = entry
  # id/name có thể là String (game này) hoặc Integer (game khác)
  next unless (sid.is_a?(String) || sid.is_a?(Integer)) && name.is_a?(String) && comp.is_a?(String)
  begin
    source = Zlib::Inflate.inflate(comp)
    puts "\n#{'=' * 80}"
    puts "INDEX #{i}: id=#{sid} name=#{name} (#{source.bytesize} bytes)"
    puts '=' * 80
    puts source
  rescue => e
    puts "Index #{i} (id=#{sid} #{name}): zlib error #{e.message}"
  end
end