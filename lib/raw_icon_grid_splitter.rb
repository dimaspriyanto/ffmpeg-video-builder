# frozen_string_literal: true

require "fileutils"
require "open3"

module RawIconGridSplitter
  DEFAULT_COLUMNS = 3
  DEFAULT_ROWS = 3
  DEFAULT_COUNT = 8
  DEFAULT_BORDER = 5
  DEFAULT_OUTPUT_SIZE = 512

  POSITIONS = [
    [0, 0], # top-left
    [1, 0], # top-center
    [2, 0], # top-right
    [0, 1], # middle-left
    [1, 1], # middle-center
    [2, 1], # middle-right
    [0, 2], # bottom-left
    [1, 2] # bottom-center
  ].freeze

  def self.split(**kwargs)
    Client.new.split(**kwargs)
  end

  class Client
    def split(source_file:, output_dir:, count: DEFAULT_COUNT, border: DEFAULT_BORDER,
              output_size: DEFAULT_OUTPUT_SIZE, columns: DEFAULT_COLUMNS, rows: DEFAULT_ROWS)
      source_file = File.expand_path(source_file.to_s)
      raise ArgumentError, "Raw icon grid file not found: #{source_file}" unless File.file?(source_file)

      output_dir = File.expand_path(output_dir.to_s)
      FileUtils.mkdir_p(output_dir)
      width, height = image_dimensions(source_file)
      cell_width = width / columns
      cell_height = height / rows
      raise ArgumentError, "Raw icon grid is too small for #{columns}x#{rows}: #{source_file}" if cell_width <= (border * 2) || cell_height <= (border * 2)

      POSITIONS.first(count).each_with_index.map do |(column, row), index|
        crop_width = cell_width - (border * 2)
        crop_height = cell_height - (border * 2)
        x = (column * cell_width) + border
        y = (row * cell_height) + border
        output_file = File.join(output_dir, "#{index + 1}.png")
        process_cell(
          source_file: source_file,
          output_file: output_file,
          crop: "#{crop_width}x#{crop_height}+#{x}+#{y}",
          output_size: output_size
        )
        output_file
      end
    end

    private

    def image_dimensions(file)
      stdout, stderr, status = Open3.capture3("identify", "-format", "%w %h", file)
      raise "Could not read raw icon grid dimensions for #{file}: #{stderr}" unless status.success?

      width, height = stdout.split.map(&:to_i)
      raise "Invalid raw icon grid dimensions for #{file}: #{stdout.inspect}" unless width.positive? && height.positive?

      [width, height]
    end

    def process_cell(source_file:, output_file:, crop:, output_size:)
      command = image_magick_command
      raise "ImageMagick convert is required to split raw icon grids" unless command

      args = [
        command,
        source_file,
        "-alpha", "set",
        "-crop", crop,
        "+repage",
        "-resize", "#{output_size}x#{output_size}",
        "-background", "none",
        "-gravity", "center",
        "-extent", "#{output_size}x#{output_size}",
        "PNG32:#{output_file}"
      ]
      _stdout, stderr, status = Open3.capture3(*args)
      raise "Could not split raw icon grid cell #{crop} from #{source_file}: #{stderr}" unless status.success?
    end

    def image_magick_command
      %w[magick convert].find { |command| executable_in_path?(command) }
    end

    def executable_in_path?(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, command)
        File.executable?(path) && !File.directory?(path)
      end
    end
  end
end
