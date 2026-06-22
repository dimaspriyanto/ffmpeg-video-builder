# frozen_string_literal: true

require "minitest/autorun"
require "shellwords"
require "tmpdir"

require_relative "../lib/raw_icon_grid_splitter"

class RawIconGridSplitterTest < Minitest::Test
  def test_splits_three_by_three_grid_into_first_eight_icons
    Dir.mktmpdir do |dir|
      source = File.join(dir, "grid.png")
      output_dir = File.join(dir, "icons")
      create_grid(source)

      files = RawIconGridSplitter.split(
        source_file: source,
        output_dir: output_dir,
        border: 5,
        output_size: 64
      )

      assert_equal (1..8).map { |index| File.join(output_dir, "#{index}.png") }, files
      files.each { |file| assert File.file?(file), "Expected #{file} to exist" }
      dimensions = files.map { |file| image_dimensions(file) }.uniq
      assert_equal [[64, 64]], dimensions
    end
  end

  private

  def create_grid(file)
    colors = %w[red green blue cyan magenta yellow orange purple gray]
    args = ["convert", "-size", "90x90", "xc:none"]
    colors.each_with_index do |color, index|
      column = index % 3
      row = index / 3
      args += ["-fill", color, "-draw", "rectangle #{column * 30},#{row * 30} #{(column * 30) + 29},#{(row * 30) + 29}"]
    end
    args << file
    system(*args) || raise("Could not create test grid")
  end

  def image_dimensions(file)
    output = `identify -format '%w %h' #{file.shellescape}`
    output.split.map(&:to_i)
  end
end
