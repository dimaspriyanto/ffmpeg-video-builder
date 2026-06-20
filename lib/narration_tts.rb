# frozen_string_literal: true

require_relative "kokoro_tts"
require_relative "google_ai_tts"

module NarrationTTS
  DEFAULT_ENGINE = "kokoro"
  ENGINES = %w[kokoro google_ai].freeze

  def self.engine(options = {})
    engine = options.fetch(:tts_engine, DEFAULT_ENGINE).to_s.strip.downcase
    raise ArgumentError, "Unsupported TTS engine: #{engine.inspect}. Use one of: #{ENGINES.join(', ')}" unless ENGINES.include?(engine)

    engine
  end

  def self.speak(text_file:, download_dir:, options: {})
    engine = engine(options)

    case engine
    when "google_ai"
      GoogleAITTS.speak(
        text_file: text_file,
        output_file: options[:google_ai_tts_output],
        download_dir: download_dir,
        api_key: options[:google_ai_api_key],
        model: options.fetch(:google_ai_tts_model, GoogleAITTS::DEFAULT_MODEL),
        voice: options.fetch(:google_ai_tts_voice, GoogleAITTS::DEFAULT_VOICE),
        style: options[:google_ai_tts_style]
      )
    else
      KokoroTTS.speak(
        text_file: text_file,
        voice: options.fetch(:kokoro_voice, KokoroTTS::DEFAULT_VOICE),
        speed: options.fetch(:kokoro_speed, KokoroTTS::DEFAULT_SPEED),
        lang_code: options.fetch(:kokoro_lang_code, KokoroTTS::DEFAULT_LANG_CODE),
        download_dir: download_dir
      )
    end
  end
end
