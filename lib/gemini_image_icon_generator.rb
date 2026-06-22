# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "time"
require "uri"
require_relative "script_video_pipeline"

module GeminiImageIconGenerator
  DEFAULT_MODEL = "gemini-2.5-flash-image"
  DEFAULT_OUTPUT_DIR = "workspace/icons/gemini_image/generated"
  DEFAULT_SIZE = 512
  DEFAULT_INNER_SIZE = 400
  DEFAULT_PROMPT_TEMPLATE = <<~PROMPT.freeze
    Generate a clean artistic monoline icon. Extract most perfect descriptioin of symbol to the Subject below.

    Subject: [SUBJECT]

    Style requirements:

      - Artistic monoline icon style
      - Slim clean white line art
      - Smooth elegant curves
      - Minimal detail, not too complex
      - Spacious composition with good negative space
      - Rounded stroke caps and rounded joins
      - No filled shapes
      - No shadows
      - No gradients
      - No glow
      - No text
      - No border frame
      - No background object
      - Transparent background
      - Pure white lines only
      - Square format
      - Centered composition
      - Suitable for dark video background
      - Icon should look modern, calm, editorial, and premium
      - Avoid cartoonish, childish, messy, or overly detailed style

    Technical output:

      - PNG
      - Transparent background
      - 512x512 px
      - The icon should fit inside the canvas on inner 400x400 px area
      - Clean edges, no broken lines, no extra artifacts
  PROMPT

  Result = Struct.new(:output_dir, :icon_config_file, :metadata_file, :icons, keyword_init: true) do
    def to_h
      {
        output_dir: output_dir,
        icon_config_file: icon_config_file,
        metadata_file: metadata_file,
        icons: icons
      }
    end
  end

  def self.generate(**kwargs)
    Client.new.generate(**kwargs)
  end

  class Client
    API_BASE = "https://generativelanguage.googleapis.com"

    def generate(script_file:, output_dir: DEFAULT_OUTPUT_DIR, icon_config_file: nil, api_key: nil,
                 model: DEFAULT_MODEL, size: DEFAULT_SIZE, inner_size: DEFAULT_INNER_SIZE,
                 prompt_template: DEFAULT_PROMPT_TEMPLATE)
      script = parse_script(script_file)
      sentences = sentence_texts(script.body)
      raise ArgumentError, "No sentences found in script content: #{script_file}" if sentences.empty?

      output_dir = File.expand_path(output_dir.to_s)
      FileUtils.mkdir_p(output_dir)
      key = required_value(api_key || ENV["GOOGLE_AI_API_KEY"] || ENV["GEMINI_API_KEY"], "Google AI API key")

      icons = sentences.each_with_index.map do |sentence, index|
        prompt = build_prompt(prompt_template, sentence)
        response = request_image(api_key: key, model: model, prompt: prompt)
        image = extract_image(response)
        raw_file = File.join(output_dir, "#{format('%02d', index + 1)}_raw.png")
        final_file = File.join(output_dir, "#{format('%02d', index + 1)}.png")
        File.binwrite(raw_file, image.fetch(:bytes))
        process_image(raw_file: raw_file, final_file: final_file, size: size, inner_size: inner_size)

        {
          "sentence_index" => index + 1,
          "text" => sentence,
          "file" => final_file,
          "raw_file" => raw_file,
          "mime_type" => image.fetch(:mime_type),
          "model" => model,
          "prompt" => prompt
        }
      end

      icon_config_file ||= File.join(output_dir, "icon_config.json")
      icon_config_file = File.expand_path(icon_config_file.to_s)
      write_icon_config(icon_config_file, icons)
      metadata_file = write_metadata(output_dir, script_file, model, size, inner_size, icons)

      Result.new(
        output_dir: output_dir,
        icon_config_file: icon_config_file,
        metadata_file: metadata_file,
        icons: icons
      )
    end

    private

    def parse_script(script_file)
      ScriptVideoPipeline::Client.new.send(:parse_script_content, File.expand_path(script_file.to_s))
    end

    def sentence_texts(script_body)
      ScriptVideoPipeline::Client.new.send(:source_sentence_texts, script_body)
    end

    def build_prompt(template, subject)
      template.to_s.gsub("[SUBJECT]", subject.to_s.strip)
    end

    def request_image(api_key:, model:, prompt:)
      uri = URI("#{API_BASE}/v1beta/models/#{model}:generateContent")
      request_json(uri, api_key: api_key, body: JSON.generate(gemini_request_body(prompt)))
    end

    def gemini_request_body(prompt)
      {
        contents: [
          {
            parts: [
              { text: prompt }
            ]
          }
        ]
      }
    end

    def request_json(uri, api_key:, body:)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["x-goog-api-key"] = api_key
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      parsed = JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed.dig("error", "message") || response.body
      raise "Gemini image icon request failed with status #{response.code}: #{message}"
    rescue JSON::ParserError => e
      raise "Gemini image icon request returned invalid JSON: #{e.message}"
    end

    def extract_image(response)
      parts = response.dig("candidates", 0, "content", "parts") || []
      image_part = parts.find { |part| part["inlineData"] || part["inline_data"] }
      inline_data = image_part && (image_part["inlineData"] || image_part["inline_data"])
      unless inline_data && inline_data["data"].to_s.strip != ""
        text = parts.filter_map { |part| part["text"] }.join("\n").strip
        detail = text.empty? ? "no image part returned" : text
        raise "Gemini image icon response did not include inline image data: #{detail}"
      end

      {
        mime_type: inline_data["mimeType"] || inline_data["mime_type"] || "image/png",
        bytes: Base64.decode64(inline_data.fetch("data"))
      }
    end

    def process_image(raw_file:, final_file:, size:, inner_size:)
      command = image_magick_command
      raise "ImageMagick convert is required to crop Gemini icon images" unless command

      args = [
        command,
        raw_file,
        "-alpha", "set",
        "-resize", "#{size}x#{size}^",
        "-gravity", "center",
        "-extent", "#{size}x#{size}",
        "-resize", "#{inner_size}x#{inner_size}",
        "-background", "none",
        "-gravity", "center",
        "-extent", "#{size}x#{size}",
        "PNG32:#{final_file}"
      ]
      _stdout, stderr, status = Open3.capture3(*args)
      raise "Could not process Gemini icon image #{raw_file}: #{stderr}" unless status.success?

      final_file
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

    def write_icon_config(icon_config_file, icons)
      FileUtils.mkdir_p(File.dirname(icon_config_file))
      base_dir = File.dirname(icon_config_file)
      payload = {
        "icons" => icons.map do |icon|
          icon.slice("sentence_index", "text").merge(
            "file" => relative_path(icon.fetch("file"), base_dir),
            "raw_file" => relative_path(icon.fetch("raw_file"), base_dir),
            "source_name" => "Gemini image generation",
            "icon_source_name" => "Gemini image generation"
          )
        end
      }
      write_json(icon_config_file, payload)
    end

    def write_metadata(output_dir, script_file, model, size, inner_size, icons)
      write_json(
        File.join(output_dir, "gemini_image_icons.json"),
        {
          "script_file" => File.expand_path(script_file.to_s),
          "model" => model,
          "size" => size,
          "inner_size" => inner_size,
          "generated_at" => Time.now.utc.iso8601,
          "icons" => icons
        }
      )
    end

    def relative_path(file, base_dir)
      Pathname.new(file).relative_path_from(Pathname.new(base_dir)).to_s
    rescue ArgumentError
      file
    end

    def write_json(file, payload)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "#{JSON.pretty_generate(payload)}\n")
      file
    end

    def required_value(value, label)
      value = value.to_s.strip
      raise ArgumentError, "#{label} is required" if value.empty?

      value
    end
  end
end
