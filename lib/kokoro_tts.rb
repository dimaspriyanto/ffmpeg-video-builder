# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tempfile"
require_relative "project_directory"

module KokoroTTS
  DEFAULT_PYTHON = "python3"
  DEFAULT_SCRIPT = File.expand_path("../bin/kokoro-tts", __dir__)
  DEFAULT_VOICE = "af_heart"
  DEFAULT_SPEED = 1.0
  DEFAULT_LANG_CODE = "a"
  DEFAULT_OUTPUT_FILE = "audio_voiceover.wav"

  Result = Struct.new(:download_dir, :audio_file, :metadata_file, :stdout, :stderr, keyword_init: true) do
    def to_h
      {
        download_dir: download_dir,
        audio_file: audio_file,
        metadata_file: metadata_file,
        stdout: stdout,
        stderr: stderr
      }
    end
  end

  def self.speak(text: nil, text_file: nil, voice: DEFAULT_VOICE, speed: DEFAULT_SPEED, lang_code: DEFAULT_LANG_CODE, downloads_root: ProjectDirectory::DEFAULT_ROOT, download_dir: nil, python: ENV.fetch("KOKORO_PYTHON", DEFAULT_PYTHON), script: ENV.fetch("KOKORO_SCRIPT", DEFAULT_SCRIPT))
    Client.new.speak(
      text: text,
      text_file: text_file,
      voice: voice,
      speed: speed,
      lang_code: lang_code,
      downloads_root: downloads_root,
      download_dir: download_dir,
      python: python,
      script: script
    )
  end

  class Client
    def speak(text: nil, text_file: nil, voice: DEFAULT_VOICE, speed: DEFAULT_SPEED, lang_code: DEFAULT_LANG_CODE, downloads_root: ProjectDirectory::DEFAULT_ROOT, download_dir: nil, python: DEFAULT_PYTHON, script: DEFAULT_SCRIPT)
      input = normalize_input(text, text_file)
      python = normalize_command(python, "KOKORO_PYTHON")
      script = validate_script!(script)
      download_dir = download_dir ? ensure_download_dir(download_dir) : create_download_dir(downloads_root)
      audio_file = File.join(download_dir, DEFAULT_OUTPUT_FILE)

      stdout, stderr = run_kokoro(
        python: python,
        script: script,
        input: input,
        output: audio_file,
        voice: voice,
        speed: speed,
        lang_code: lang_code
      )

      metadata_file = write_metadata(
        download_dir: download_dir,
        audio_file: audio_file,
        input: input,
        voice: voice,
        speed: speed,
        lang_code: lang_code,
        script: script
      )

      Result.new(
        download_dir: download_dir,
        audio_file: audio_file,
        metadata_file: metadata_file,
        stdout: stdout,
        stderr: stderr
      )
    end

    private

    def normalize_input(text, text_file)
      has_text = !blank?(text)
      has_text_file = !blank?(text_file)
      raise ArgumentError, "Provide either text or text_file, not both" if has_text && has_text_file
      raise ArgumentError, "Kokoro text or text_file is required" unless has_text || has_text_file

      if has_text
        { type: :text, value: text.to_s.strip }
      else
        path = File.expand_path(text_file.to_s)
        raise ArgumentError, "Kokoro text file not found: #{path}" unless File.file?(path)

        { type: :text_file, value: path }
      end
    end

    def normalize_command(command, env_name)
      value = command.to_s.strip
      value = DEFAULT_PYTHON if value.empty?
      return value if value.include?(File::SEPARATOR) && File.executable?(value)
      return value if ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, value))
      end

      raise "#{env_name} command not found: #{value.inspect}. Set #{env_name}=/full/path/to/#{value} or add it to PATH."
    end

    def validate_script!(script)
      path = File.expand_path(script.to_s)
      raise ArgumentError, "Kokoro script not found: #{path}" unless File.file?(path)

      path
    end

    def run_kokoro(python:, script:, input:, output:, voice:, speed:, lang_code:)
      args = [
        python,
        script,
        "--output", output,
        "--voice", voice.to_s,
        "--speed", speed.to_s,
        "--lang-code", lang_code.to_s
      ]

      if input.fetch(:type) == :text
        Tempfile.create(["kokoro-text", ".txt"]) do |file|
          file.write(input.fetch(:value))
          file.flush
          return capture(args + ["--text-file", file.path])
        end
      end

      capture(args + ["--text-file", input.fetch(:value)])
    end

    def capture(args)
      stdout, stderr, status = Open3.capture3(*args)
      unless status.success?
        raise "Kokoro failed with status #{status.exitstatus}: #{stderr.empty? ? stdout : stderr}"
      end

      [stdout, stderr]
    end

    def create_download_dir(downloads_root)
      ProjectDirectory.create(root: downloads_root)
    end

    def ensure_download_dir(download_dir)
      ProjectDirectory.ensure(download_dir)
    end

    def write_metadata(download_dir:, audio_file:, input:, voice:, speed:, lang_code:, script:)
      metadata_file = File.join(download_dir, "audio_kokoro.json")
      payload = {
        audio_file: audio_file,
        input_type: input.fetch(:type),
        text_file: input.fetch(:type) == :text_file ? input.fetch(:value) : nil,
        voice: voice,
        speed: Float(speed),
        lang_code: lang_code,
        script: script
      }
      File.write(metadata_file, "#{JSON.pretty_generate(payload)}\n")
      metadata_file
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
