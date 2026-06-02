# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

require_relative "icon_search"
require_relative "kokoro_tts"
require_relative "openai_whisper"
require_relative "project_directory"

module ScriptVideoPipeline
  DEFAULT_DOWNLOADS_ROOT = ProjectDirectory::DEFAULT_ROOT
  DEFAULT_WIDTH = 1080
  DEFAULT_HEIGHT = 1920
  DEFAULT_FPS = 30
  DEFAULT_BACKGROUND = { "type" => "color", "color" => "#111827" }.freeze
  DEFAULT_ICON_WIDTH = 320
  DEFAULT_ICON_X = "center"
  DEFAULT_ICON_Y = 560
  DEFAULT_TEXT_Y = 980
  DEFAULT_TEXT_FONT_SIZE = 48
  ICON_ANIMATIONS = %w[pop slide_left slide_up slide_right].freeze

  STOP_WORDS = %w[
    a about after again all am an and are as at be because been before being
    but by can could did do does doing down during each few for from further
    had has have having he her here hers herself him himself his how i if in
    into is it its itself just me more most my myself no nor not of off on once
    only or other our ours ourselves out over own same she should so some such
    than that the their theirs them themselves then there these they this those
    through to too under until up very was we were what when where which while
    who whom why will with you your yours yourself yourselves
  ].freeze

  Result = Struct.new(:project_dir, :script_file, :audio_file, :subtitle_file, :icon_plan_file, :config_file, :output_file, keyword_init: true) do
    def to_h
      {
        project_dir: project_dir,
        script_file: script_file,
        audio_file: audio_file,
        subtitle_file: subtitle_file,
        icon_plan_file: icon_plan_file,
        config_file: config_file,
        output_file: output_file
      }
    end
  end

  def self.prepare(script_file:, options: {})
    Client.new.prepare(script_file: script_file, options: options)
  end

  class Client
    def prepare(script_file:, options: {})
      script_file = validate_script_file!(script_file)
      project_dir = create_project_dir(options.fetch(:downloads_root, DEFAULT_DOWNLOADS_ROOT))
      local_script_file = File.join(project_dir, "script_input.txt")
      FileUtils.cp(script_file, local_script_file)

      narration = KokoroTTS.speak(
        text_file: local_script_file,
        voice: options.fetch(:kokoro_voice, KokoroTTS::DEFAULT_VOICE),
        speed: options.fetch(:kokoro_speed, KokoroTTS::DEFAULT_SPEED),
        lang_code: options.fetch(:kokoro_lang_code, KokoroTTS::DEFAULT_LANG_CODE),
        download_dir: project_dir
      )

      transcription = OpenAIWhisper.transcribe(
        file: narration.audio_file,
        model: options.fetch(:whisper_model, OpenAIWhisper::DEFAULT_MODEL),
        output_format: "json",
        task: options.fetch(:whisper_task, OpenAIWhisper::DEFAULT_TASK),
        word_timestamps: options.fetch(:whisper_word_timestamps, OpenAIWhisper::DEFAULT_WORD_TIMESTAMPS),
        language: options[:whisper_language],
        prompt: options[:whisper_prompt],
        download_dir: project_dir
      )

      sentences = transcription.sentences
      raise "Whisper did not produce sentence timings" if sentences.empty?

      icon_plan = build_icon_plan(sentences, project_dir, options)
      icon_plan_file = write_json(File.join(project_dir, "icon_plan.json"), icon_plan)
      config = build_ffmpeg_config(sentences, icon_plan, narration.audio_file, project_dir, options)
      config_file = write_json(File.join(project_dir, "config_project.json"), config)

      write_json(
        File.join(project_dir, "pipeline_metadata.json"),
        {
          script_file: local_script_file,
          audio_file: narration.audio_file,
          subtitle_file: transcription.sentence_files[:srt],
          icon_plan_file: icon_plan_file,
          config_file: config_file,
          output_file: File.join(project_dir, config.fetch("output"))
        }
      )

      Result.new(
        project_dir: project_dir,
        script_file: local_script_file,
        audio_file: narration.audio_file,
        subtitle_file: transcription.sentence_files[:srt],
        icon_plan_file: icon_plan_file,
        config_file: config_file,
        output_file: File.join(project_dir, config.fetch("output"))
      )
    end

    private

    def validate_script_file!(script_file)
      path = File.expand_path(script_file.to_s)
      raise ArgumentError, "Script file not found: #{path}" unless File.file?(path)

      path
    end

    def create_project_dir(downloads_root)
      ProjectDirectory.create(root: downloads_root)
    end

    def build_icon_plan(sentences, project_dir, options)
      sentences.map do |sentence|
        index = sentence.fetch("index")
        keyword = icon_keyword(sentence.fetch("text"))
        icon_dir = File.join(project_dir, "icons", format("%02d", index))
        batch = IconSearch.search_and_download(
          keyword: keyword,
          style: options.fetch(:icon_style, IconSearch::DEFAULT_STYLE),
          source: options.fetch(:icon_source, IconSearch::DEFAULT_SOURCE),
          license_type: options.fetch(:icon_license_type, IconSearch::DEFAULT_LICENSE_TYPE),
          size: options.fetch(:icon_size, IconSearch::DEFAULT_SIZE),
          limit: 1,
          download_dir: icon_dir
        )
        icon = batch.results.first

        {
          "sentence_index" => index,
          "sentence" => sentence.fetch("text"),
          "keyword" => keyword,
          "start" => sentence.fetch("start"),
          "end" => sentence.fetch("end"),
          "duration" => (sentence.fetch("end").to_f - sentence.fetch("start").to_f).round(3),
          "icon_id" => icon&.id,
          "icon_file" => icon&.downloaded_file,
          "animation" => ICON_ANIMATIONS[(index - 1) % ICON_ANIMATIONS.length]
        }
      end
    end

    def build_ffmpeg_config(sentences, icon_plan, audio_file, project_dir, options)
      duration = [sentences.map { |sentence| sentence.fetch("end").to_f }.max + 0.35, 1.0].max.round(3)
      elements = [
        {
          "type" => "rectangle",
          "start" => 0,
          "end" => duration,
          "x" => 70,
          "y" => 250,
          "width" => 940,
          "height" => 1180,
          "color" => "white@0.08"
        }
      ]

      icon_plan.each do |planned_icon|
        if planned_icon["icon_file"]
          elements << {
            "type" => "image",
            "file" => relative_path(planned_icon.fetch("icon_file"), project_dir),
            "start" => planned_icon.fetch("start"),
            "end" => planned_icon.fetch("end"),
            "width" => options.fetch(:pipeline_icon_width, DEFAULT_ICON_WIDTH),
            "x" => DEFAULT_ICON_X,
            "y" => DEFAULT_ICON_Y,
            "animation" => planned_icon.fetch("animation")
          }
        end

        elements << {
          "type" => "text",
          "text" => wrap_text(planned_icon.fetch("sentence")),
          "start" => planned_icon.fetch("start"),
          "end" => planned_icon.fetch("end"),
          "font_size" => DEFAULT_TEXT_FONT_SIZE,
          "color" => "white",
          "x" => "center",
          "y" => DEFAULT_TEXT_Y,
          "box" => true,
          "box_color" => "black@0.35",
          "box_border" => 22
        }
      end

      {
        "output" => "video_output.mp4",
        "width" => options.fetch(:width, DEFAULT_WIDTH),
        "height" => options.fetch(:height, DEFAULT_HEIGHT),
        "fps" => options.fetch(:fps, DEFAULT_FPS),
        "duration" => duration,
        "background" => DEFAULT_BACKGROUND,
        "audio" => relative_path(audio_file, project_dir),
        "elements" => elements
      }
    end

    def icon_keyword(text)
      words = text.downcase.scan(/[a-z][a-z'-]*/)
                  .map { |word| word.delete("'") }
                  .reject { |word| STOP_WORDS.include?(word) || word.length < 3 }
      return "idea" if words.empty?

      words.each_with_index.max_by { |word, index| [word.length, -index] }.first
    end

    def wrap_text(text, max_line_length = 30)
      words = text.to_s.split(/\s+/)
      lines = []
      current = +""

      words.each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.length > max_line_length && !current.empty?
          lines << current
          current = word
        else
          current = candidate
        end
      end

      lines << current unless current.empty?
      lines.join("\n")
    end

    def relative_path(path, from)
      Pathname.new(path).relative_path_from(Pathname.new(from)).to_s
    end

    def write_json(path, payload)
      File.write(path, "#{JSON.pretty_generate(payload)}\n")
      path
    end
  end
end
