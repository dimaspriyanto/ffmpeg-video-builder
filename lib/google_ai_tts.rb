# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

module GoogleAITTS
  DEFAULT_MODEL = "gemini-3.1-flash-tts-preview"
  DEFAULT_VOICE = "Kore"
  DEFAULT_OUTPUT_FILE = "audio_voiceover.wav"
  DEFAULT_API_BASE = "https://generativelanguage.googleapis.com"
  DEFAULT_SAMPLE_RATE = 24_000
  DEFAULT_CHANNELS = 1
  DEFAULT_SAMPLE_WIDTH = 2

  Result = Struct.new(:download_dir, :audio_file, :metadata_file, :model, :voice, :response, keyword_init: true) do
    def to_h
      {
        download_dir: download_dir,
        audio_file: audio_file,
        metadata_file: metadata_file,
        model: model,
        voice: voice,
        response: response
      }
    end
  end

  def self.speak(**kwargs)
    Client.new.speak(**kwargs)
  end

  class Client
    def speak(text: nil, text_file: nil, output_file: nil, download_dir: nil, api_key: nil,
              model: DEFAULT_MODEL, voice: DEFAULT_VOICE, style: nil)
      input = normalize_input(text, text_file)
      prompt = build_prompt(input.fetch(:text), style)
      key = required_value(api_key || ENV["GOOGLE_AI_API_KEY"] || ENV["GEMINI_API_KEY"], "Google AI API key")
      response = generate_content(api_key: key, model: model, prompt: prompt, voice: voice)
      pcm = extract_audio(response)
      output_file = resolve_output_file(output_file, download_dir)
      FileUtils.mkdir_p(File.dirname(output_file))
      write_wave(output_file, pcm)
      metadata_file = write_metadata(
        output_file: output_file,
        input: input,
        model: model,
        voice: voice,
        style: style,
        response: response
      )

      Result.new(
        download_dir: File.dirname(output_file),
        audio_file: output_file,
        metadata_file: metadata_file,
        model: model,
        voice: voice,
        response: response
      )
    end

    private

    def resolve_output_file(output_file, download_dir)
      return File.expand_path(output_file.to_s) unless blank?(output_file)

      dir = blank?(download_dir) ? Dir.pwd : File.expand_path(download_dir.to_s)
      File.join(dir, DEFAULT_OUTPUT_FILE)
    end

    def generate_content(api_key:, model:, prompt:, voice:)
      uri = URI("#{DEFAULT_API_BASE}/v1beta/models/#{model}:generateContent")
      uri.query = URI.encode_www_form(key: api_key)
      body = {
        contents: [
          {
            parts: [
              { text: prompt }
            ]
          }
        ],
        generationConfig: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName: voice
              }
            }
          }
        },
        model: model
      }
      request_json(uri, body: JSON.generate(body))
    end

    def request_json(uri, body:)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      parsed = parse_json_response(response)
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed.dig("error", "message") || response.body
      raise "Google AI TTS request failed with status #{response.code}: #{message}"
    end

    def extract_audio(response)
      part = response.dig("candidates", 0, "content", "parts", 0) || {}
      inline_data = part["inlineData"] || part["inline_data"] || {}
      data = inline_data["data"].to_s
      raise "Google AI TTS response did not include inline audio data" if data.empty?

      Base64.decode64(data)
    end

    def write_wave(file, pcm, channels: DEFAULT_CHANNELS, sample_rate: DEFAULT_SAMPLE_RATE,
                   sample_width: DEFAULT_SAMPLE_WIDTH)
      byte_rate = sample_rate * channels * sample_width
      block_align = channels * sample_width
      data_size = pcm.bytesize
      File.binwrite(
        file,
        [
          "RIFF",
          [36 + data_size].pack("V"),
          "WAVE",
          "fmt ",
          [16, 1, channels, sample_rate, byte_rate, block_align, sample_width * 8].pack("VvvVVvv"),
          "data",
          [data_size].pack("V"),
          pcm
        ].join
      )
    end

    def write_metadata(output_file:, input:, model:, voice:, style:, response:)
      metadata_file = output_file.sub(/\.[^.]*\z/, ".google_ai_tts.json")
      payload = {
        audio_file: output_file,
        input_type: input.fetch(:type),
        text_file: input[:text_file],
        model: model,
        voice: voice,
        style: style,
        generated_at: Time.now.utc.iso8601,
        response: response
      }
      File.write(metadata_file, "#{JSON.pretty_generate(payload)}\n")
      metadata_file
    end

    def normalize_input(text, text_file)
      has_text = !blank?(text)
      has_text_file = !blank?(text_file)
      raise ArgumentError, "Provide either text or text_file, not both" if has_text && has_text_file
      raise ArgumentError, "Google AI TTS text or text_file is required" unless has_text || has_text_file

      return { type: :text, text: text.to_s.strip } if has_text

      path = File.expand_path(text_file.to_s)
      raise ArgumentError, "Google AI TTS text file not found: #{path}" unless File.file?(path)

      { type: :text_file, text: File.read(path).strip, text_file: path }
    end

    def build_prompt(text, style)
      return text if blank?(style)

      "#{style.to_s.strip}:\n#{text}"
    end

    def parse_json_response(response)
      JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    rescue JSON::ParserError
      { "raw" => response.body.to_s }
    end

    def required_value(value, label)
      normalized = value.to_s.strip
      raise ArgumentError, "#{label} is required" if normalized.empty?

      normalized
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
