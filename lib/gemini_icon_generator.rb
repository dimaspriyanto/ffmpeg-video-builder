# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "pathname"
require "time"
require "uri"
require_relative "icon_search"
require_relative "script_video_pipeline"

module GeminiIconGenerator
  DEFAULT_MODEL = "gemini-2.5-flash"
  DEFAULT_SOURCE = "material-symbols"
  DEFAULT_STYLE = "material-symbols"
  DEFAULT_OUTPUT_DIR = "workspace/icons/material_design/generated"

  Result = Struct.new(:output_dir, :raw_plan_file, :resolved_plan_file, :icon_config_file, :icons, keyword_init: true) do
    def to_h
      {
        output_dir: output_dir,
        raw_plan_file: raw_plan_file,
        resolved_plan_file: resolved_plan_file,
        icon_config_file: icon_config_file,
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
                 model: DEFAULT_MODEL, source: DEFAULT_SOURCE, style: DEFAULT_STYLE, size: IconSearch::DEFAULT_SIZE)
      script = parse_script(script_file)
      sentences = sentence_texts(script.body)
      raise ArgumentError, "No sentences found in script content: #{script_file}" if sentences.empty?

      output_dir = File.expand_path(output_dir.to_s)
      FileUtils.mkdir_p(output_dir)
      key = required_value(api_key || ENV["GOOGLE_AI_API_KEY"] || ENV["GEMINI_API_KEY"], "Google AI API key")

      raw_plan = request_icon_plan(api_key: key, model: model, script: script, sentences: sentences)
      raw_plan_file = write_json(File.join(output_dir, "gemini_material_icons.json"), raw_plan)
      resolved_icons = resolve_and_download_icons(
        raw_plan: raw_plan,
        sentences: sentences,
        output_dir: output_dir,
        source: source,
        style: style,
        size: size
      )
      resolved_plan_file = write_json(File.join(output_dir, "gemini_material_icons_resolved.json"), resolved_icons)
      icon_config_file ||= File.join(output_dir, "icon_config.json")
      icon_config_file = File.expand_path(icon_config_file.to_s)
      write_icon_config(icon_config_file, resolved_icons)

      Result.new(
        output_dir: output_dir,
        raw_plan_file: raw_plan_file,
        resolved_plan_file: resolved_plan_file,
        icon_config_file: icon_config_file,
        icons: resolved_icons
      )
    end

    private

    def parse_script(script_file)
      ScriptVideoPipeline::Client.new.send(:parse_script_content, File.expand_path(script_file.to_s))
    end

    def sentence_texts(script_body)
      ScriptVideoPipeline::Client.new.send(:source_sentence_texts, script_body)
    end

    def request_icon_plan(api_key:, model:, script:, sentences:)
      response = request_json(generate_content_uri(api_key, model), body: JSON.generate(gemini_request_body(script, sentences)))
      parse_icon_plan(response_text(response), expected_count: sentences.length)
    end

    def generate_content_uri(api_key, model)
      uri = URI("#{API_BASE}/v1beta/models/#{model}:generateContent")
      uri.query = URI.encode_www_form(key: api_key)
      uri
    end

    def gemini_request_body(script, sentences)
      numbered = sentences.each_with_index.map { |text, index| "#{index + 1}. #{text}" }.join("\n")
      prompt = <<~PROMPT
        Choose one Google Material Symbols icon for each sentence below.
        Return only a JSON array. Do not wrap it in markdown.
        Each item must contain: number, text, icon, reason.
        The icon value must be a short Material Symbols icon name, lowercase, using underscores or hyphens.

        Title: #{script.title}
        Category: #{script.category}

        Sentences:
        #{numbered}
      PROMPT

      {
        contents: [
          {
            parts: [
              { text: prompt }
            ]
          }
        ],
        generationConfig: {
          responseMimeType: "application/json"
        }
      }
    end

    def request_json(uri, body:)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      parsed = JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed.dig("error", "message") || response.body
      raise "Gemini icon request failed with status #{response.code}: #{message}"
    rescue JSON::ParserError => e
      raise "Gemini icon request returned invalid JSON: #{e.message}"
    end

    def response_text(response)
      response.dig("candidates", 0, "content", "parts", 0, "text").to_s
    end

    def parse_icon_plan(text, expected_count:)
      json_text = text.to_s.strip
      json_text = json_text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "").strip
      parsed = JSON.parse(json_text)
      raise ArgumentError, "Gemini icon response must be a JSON array" unless parsed.is_a?(Array)
      raise ArgumentError, "Gemini returned #{parsed.length} icons, expected #{expected_count}" unless parsed.length == expected_count

      parsed.each_with_index.map do |item, index|
        item = item.transform_keys(&:to_s)
        {
          "number" => item.fetch("number", index + 1).to_i,
          "text" => item.fetch("text", ""),
          "icon" => item.fetch("icon").to_s,
          "reason" => item.fetch("reason", "").to_s
        }
      end
    rescue JSON::ParserError => e
      raise "Gemini icon response did not contain valid JSON: #{e.message}"
    end

    def resolve_and_download_icons(raw_plan:, sentences:, output_dir:, source:, style:, size:)
      raw_plan.each_with_index.map do |item, index|
        icon_name = item.fetch("icon").to_s
        result, note = resolve_icon(icon_name, source: source, style: style, size: size, output_dir: output_dir)
        target_file = File.join(output_dir, "#{format('%02d', index + 1)}_#{safe_filename(result.name)}.svg")
        FileUtils.mv(result.downloaded_file, target_file)

        payload = {
          "sentence_index" => index + 1,
          "text" => sentences.fetch(index),
          "file" => target_file,
          "icon_id" => result.id,
          "icon_source" => result.source,
          "icon_source_name" => result.source_name,
          "license" => result.license,
          "license_type" => result.license_type,
          "style" => style,
          "gemini_icon" => icon_name,
          "gemini_reason" => item.fetch("reason", "")
        }
        payload["resolved_note"] = note if note
        payload
      end
    end

    def resolve_icon(icon_name, source:, style:, size:, output_dir:)
      normalized_names(icon_name).each do |candidate|
        icon_id = "#{source}:#{candidate}"
        begin
          return [download_icon(icon_id, output_dir: output_dir, size: size), nil]
        rescue StandardError
          next
        end
      end

      result = search_icon(icon_name, source: source, style: style, size: size, output_dir: output_dir)
      note = "Gemini icon #{icon_name.inspect} was not available in #{source}; resolved to #{result.name.inspect}."
      [result, note]
    end

    def normalized_names(icon_name)
      base = icon_name.to_s.strip.downcase.gsub(/[^a-z0-9_-]+/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
      [base, base.tr("_", "-"), base.tr("-", "_")].reject(&:empty?).uniq
    end

    def download_icon(icon_id, output_dir:, size:)
      IconSearch.download_icon_by_id(
        icon_id: icon_id,
        license_type: "permissive",
        size: size,
        download_dir: output_dir
      )
    end

    def search_icon(icon_name, source:, style:, size:, output_dir:)
      batch = IconSearch.search_and_download(
        keyword: icon_name.to_s.tr("_-", " "),
        style: style,
        source: source,
        license_type: "permissive",
        size: size,
        limit: 1,
        download_dir: output_dir
      )
      result = batch.results.first
      raise "Could not resolve Gemini icon #{icon_name.inspect} in #{source}" unless result

      result
    end

    def write_icon_config(icon_config_file, resolved_icons)
      FileUtils.mkdir_p(File.dirname(icon_config_file))
      base_dir = File.dirname(icon_config_file)
      payload = {
        "icons" => resolved_icons.map do |icon|
          icon.merge("file" => relative_path(icon.fetch("file"), base_dir))
        end
      }
      write_json(icon_config_file, payload)
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

    def safe_filename(value)
      value.to_s.downcase.gsub(/[^a-z0-9_-]+/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def required_value(value, label)
      value = value.to_s.strip
      raise ArgumentError, "#{label} is required" if value.empty?

      value
    end
  end
end
