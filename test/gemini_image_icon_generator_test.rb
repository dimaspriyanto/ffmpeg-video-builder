# frozen_string_literal: true

require "base64"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/gemini_image_icon_generator"

class GeminiImageIconGeneratorTest < Minitest::Test
  def test_generates_png_icons_from_each_script_sentence
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
      assert_equal 2, result.icons.length
      assert File.file?(File.join(output_dir, "01_raw.png"))
      assert File.file?(File.join(output_dir, "01.png"))
      assert File.file?(File.join(output_dir, "02.png"))
      assert File.file?(result.metadata_file)

      first_prompt = client.prompts.first
      assert_includes first_prompt, "Subject: Kalimat pertama."
      refute_includes first_prompt, "[SUBJECT]"
      assert_includes first_prompt, "Transparent background"
      assert_includes first_prompt, "512x512 px"
      assert_includes first_prompt, "inner 400x400 px area"
      assert_equal ["key-123", "key-123"], client.api_keys
      assert_equal [[512, 400], [512, 400]], client.processed_sizes

      config = JSON.parse(File.read(config_file))
      icons = config.fetch("icons")
      assert_equal 2, icons.length
      assert_equal "icons/01.png", icons[0].fetch("file")
      assert_equal "icons/01_raw.png", icons[0].fetch("raw_file")
      assert_equal "Gemini image generation", icons[0].fetch("icon_source_name")
      assert_equal "Kalimat kedua.", icons[1].fetch("text")
    end
  end

  class RecordingClient < GeminiImageIconGenerator::Client
    attr_reader :api_keys, :processed_sizes, :prompts

    def initialize
      super
      @api_keys = []
      @processed_sizes = []
      @prompts = []
    end

    private

    def request_json(_uri, api_key:, body:)
      @api_keys << api_key
      parsed = JSON.parse(body)
      @prompts << parsed.dig("contents", 0, "parts", 0, "text")
      {
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {
                  "inlineData" => {
                    "mimeType" => "image/png",
                    "data" => Base64.strict_encode64("fake-png")
                  }
                }
              ]
            }
          }
        ]
      }
    end

    def process_image(raw_file:, final_file:, size:, inner_size:)
      @processed_sizes << [size, inner_size]
      File.write(final_file, File.binread(raw_file))
      final_file
    end
  end
end
