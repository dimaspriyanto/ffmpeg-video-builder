# frozen_string_literal: true

require "date"
require "fileutils"

module ProjectDirectory
  DEFAULT_ROOT = "projects"

  def self.create(root: DEFAULT_ROOT, date: Date.today)
    root = File.expand_path(root)
    FileUtils.mkdir_p(root)

    stamp = date.strftime("%d%m%Y")
    sequence = next_sequence(root, stamp)
    dir = File.join(root, "Project_#{sequence}_#{stamp}")

    while File.exist?(dir)
      sequence += 1
      dir = File.join(root, "Project_#{sequence}_#{stamp}")
    end

    FileUtils.mkdir_p(dir)
    File.expand_path(dir)
  end

  def self.ensure(path)
    FileUtils.mkdir_p(path)
    File.expand_path(path)
  end

  def self.next_sequence(root, stamp)
    pattern = /\AProject_(\d+)_#{Regexp.escape(stamp)}\z/
    sequences = Dir.children(root).map do |entry|
      match = entry.match(pattern)
      Integer(match[1]) if match
    end.compact

    sequences.max.to_i + 1
  end
end
