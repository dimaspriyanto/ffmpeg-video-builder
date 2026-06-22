# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/gemini_icon_generator"

class GeminiIconGeneratorTest < Minitest::Test
  def test_generates_material_icon_config_from_script
    Dir.mktmpdir do |dir|
      script_file = File.join(dir, "script.txt")
      output_dir = File.join(dir, "icons")
      config_file = File.join(dir, "icon_config.json")
      File.write(script_file, <<~SCRIPT)
        Title: Test Quote
        Category: Inspirational Quotes
        Content:
        Kalimat pertama.
        Kalimat kedua.
      SCRIPT

      client = RecordingClient.new
      result = client.generate(
        script_file: script_file,
        output_dir: output_dir,
        icon_config_file: config_file,
        api_key: "key-123"
      )

      assert_equal output_dir, result.output_dir
      assert File.file?(File.join(output_dir, "01_favorite.svg"))
      assert File.file?(File.join(output_dir, "02_lightbulb.svg"))
      assert File.file?(result.raw_plan_file)
      assert File.file?(result.resolved_plan_file)
      assert_equal config_file, result.icon_config_file

      config = JSON.parse(File.read(config_file))
      icons = config.fetch("icons")
      assert_equal 2, icons.length
      assert_equal 1, icons[0].fetch("sentence_index")
      assert_equal "icons/01_favorite.svg", icons[0].fetch("file")
      assert_equal "material-symbols:favorite", icons[0].fetch("icon_id")
      assert_equal "Kalimat kedua.", icons[1].fetch("text")
    end
  end

  class RecordingClient < GeminiIconGenerator::Client
    private

    def request_json(_uri, body:)
      @body = JSON.parse(body)
      {
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {
                  "text" => JSON.generate([
                    {
                      number: 1,
                      text: "Kalimat pertama.",
                      icon: "favorite",
                      reason: "Represents care."
                    },
                    {
                      number: 2,
                      text: "Kalimat kedua.",
                      icon: "lightbulb",
                      reason: "Represents insight."
                    }
                  ])
                }
              ]
            }
          }
        ]
      }
    end

    def download_icon(icon_id, output_dir:, size:)
      name = icon_id.split(":", 2).last
      file = File.join(output_dir, "icon_#{name}.svg")
      File.write(file, "<svg width=\"#{size}\" height=\"#{size}\"></svg>")
      IconSearch::Result.new(
        id: icon_id,
        name: name,
        source: "material-symbols",
        source_name: "Material Symbols",
        license: "Apache 2.0",
        license_type: "permissive",
        style: "material-symbols",
        svg_url: "https://example.test/#{name}.svg",
        downloaded_file: file
      )
    end
  end
end
