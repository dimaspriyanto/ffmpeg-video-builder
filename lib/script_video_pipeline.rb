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
  DEFAULT_BACKGROUND = { "type" => "color", "color" => "#FFC067" }.freeze
  DEFAULT_ICON_WIDTH = 320
  DEFAULT_ICON_X = "center"
  DEFAULT_ICON_Y = 560
  DEFAULT_TEXT_Y = 1420
  DEFAULT_TEXT_FONT_SIZE = 46
  DEFAULT_TEXT_WIDTH = 1000
  DEFAULT_TEXT_CANVAS_WIDTH = 1080
  DEFAULT_TEXT_RASTERIZE_SIZE = 640
  DEFAULT_TEXT_MAX_LINE_LENGTH = 22
  DEFAULT_OPENING_TITLE_DURATION = 3.0
  DEFAULT_ICON_CANDIDATE_LIMIT = 8
  ICON_ANIMATIONS = %w[pop slide_left slide_right fade].freeze
  FALLBACK_ICON_KEYWORDS = %w[
    money wallet bank savings chart calendar document lightbulb idea
  ].freeze

  STOP_WORDS = %w[
    a about after again all am an and are as at be because been before being
    but by can could did do does doing down during each few for from further
    had has have having he her here hers herself him himself his how i if in
    into is it its itself just me more most my myself no nor not of off on once
    only or other our ours ourselves out over own same she should so some such
    than that the their theirs them themselves then there these they this those
    through to too under until up very was we were what when where which while
    who whom why will with you your yours yourself yourselves
    around first heres means might instead still trying
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
      title_text = first_paragraph(local_script_file)

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
      config = build_ffmpeg_config(sentences, icon_plan, narration.audio_file, project_dir, options, title_text: title_text)
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
      used_icon_ids = {}

      sentences.map do |sentence|
        index = sentence.fetch("index")
        keywords = icon_keywords(sentence.fetch("text"))
        icon_dir = File.join(project_dir, "icons", format("%02d", index))
        keyword, icon = first_matching_icon(
          keywords: keywords,
          icon_dir: icon_dir,
          options: options,
          used_icon_ids: used_icon_ids
        )
        used_icon_ids[icon.id] = true if icon

        {
          "sentence_index" => index,
          "sentence" => sentence.fetch("text"),
          "keyword" => keyword,
          "start" => sentence.fetch("start"),
          "end" => sentence.fetch("end"),
          "duration" => (sentence.fetch("end").to_f - sentence.fetch("start").to_f).round(3),
          "icon_id" => icon&.id,
          "icon_file" => icon&.downloaded_file,
          "icon_candidates" => keywords,
          "animation" => ICON_ANIMATIONS[(index - 1) % ICON_ANIMATIONS.length]
        }
      end
    end

    def build_ffmpeg_config(sentences, icon_plan, audio_file, project_dir, options, title_text:)
      duration = [sentences.map { |sentence| sentence.fetch("end").to_f }.max + 0.35, 1.0].max.round(3)
      elements = []
      visible_icons = icon_plan.select { |planned_icon| planned_icon["icon_file"] }
      icon_width = options.fetch(:pipeline_icon_width, DEFAULT_ICON_WIDTH)

      icon_plan.each do |planned_icon|
        text_start = visual_start_time(planned_icon)
        text_end = visual_text_end_time(planned_icon, text_start)
        text = planned_icon.fetch("sentence")

        if planned_icon.fetch("sentence_index") == 1
          text = title_text.empty? ? text : title_text
        end

        if planned_icon["icon_file"]
          position = visible_icons.index(planned_icon)
          icon_start = visual_start_time(planned_icon)
          elements << {
            "type" => "image",
            "file" => relative_path(planned_icon.fetch("icon_file"), project_dir),
            "start" => icon_start,
            "end" => icon_end_time(position, visible_icons, duration),
            "width" => icon_width,
            "x" => DEFAULT_ICON_X,
            "y" => DEFAULT_ICON_Y,
            "animation" => safe_icon_animation(planned_icon),
            "hold" => true
          }
        end

        elements << {
          "type" => "text",
          "text" => wrap_text(text, DEFAULT_TEXT_MAX_LINE_LENGTH),
          "start" => text_start,
          "end" => text_end,
          "font_size" => DEFAULT_TEXT_FONT_SIZE,
          "color" => "black",
          "x" => "center",
          "y" => DEFAULT_TEXT_Y,
          "box" => false,
          "fallback_width" => DEFAULT_TEXT_WIDTH,
          "fallback_canvas_width" => DEFAULT_TEXT_CANVAS_WIDTH,
          "fallback_rasterize_size" => DEFAULT_TEXT_RASTERIZE_SIZE
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

    def icon_end_time(position, visible_icons, duration)
      next_icon = visible_icons[position + 1]
      return duration unless next_icon

      visual_start_time(next_icon)
    end

    def safe_icon_animation(planned_icon)
      animation = planned_icon["animation"].to_s
      return animation if ICON_ANIMATIONS.include?(animation)

      ICON_ANIMATIONS[(planned_icon.fetch("sentence_index") - 1) % ICON_ANIMATIONS.length]
    end

    def first_matching_icon(keywords:, icon_dir:, options:, used_icon_ids:)
      last_keyword = keywords.first
      last_batch = nil

      keywords.each do |keyword|
        last_keyword = keyword
        last_batch = IconSearch.search_and_download(
          keyword: keyword,
          style: options.fetch(:icon_style, IconSearch::DEFAULT_STYLE),
          source: options.fetch(:icon_source, IconSearch::DEFAULT_SOURCE),
          license_type: options.fetch(:icon_license_type, IconSearch::DEFAULT_LICENSE_TYPE),
          size: options.fetch(:icon_size, IconSearch::DEFAULT_SIZE),
          limit: options.fetch(:icon_candidate_limit, DEFAULT_ICON_CANDIDATE_LIMIT),
          download_dir: icon_dir
        )
        icon = last_batch.results.find { |result| !used_icon_ids[result.id] }
        return [keyword, icon] if icon
      end

      [last_keyword, nil]
    end

    def first_paragraph(script_file)
      File.read(script_file)
          .split(/\R{2,}/)
          .map(&:strip)
          .find { |paragraph| !paragraph.empty? }
          .to_s
    end

    def visual_start_time(planned_icon)
      start = planned_icon.fetch("start").to_f
      return 0.0 if planned_icon.fetch("sentence_index") == 1

      [start, DEFAULT_OPENING_TITLE_DURATION].max.round(3)
    end

    def visual_text_end_time(planned_icon, visual_start)
      natural_end = planned_icon.fetch("end").to_f
      if planned_icon.fetch("sentence_index") == 1
        return [natural_end, DEFAULT_OPENING_TITLE_DURATION].max.round(3)
      end

      [natural_end, visual_start + 0.5].max.round(3)
    end

    def icon_keywords(text)
      words = text.downcase.scan(/[a-z][a-z'-]*/)
                  .map { |word| word.delete("'") }
                  .reject { |word| STOP_WORDS.include?(word) || word.length < 3 }
      domain_candidates = domain_icon_keywords(text.to_s.downcase, words)
      candidates = words.sort_by.with_index { |word, index| [-word.length, index] }
      candidates = domain_candidates + candidates + words
      candidates += FALLBACK_ICON_KEYWORDS

      candidates.map(&:strip).reject(&:empty?).uniq
    end

    def domain_icon_keywords(text, words)
      candidates = []
      candidates += %w[money chart] if words.include?("inflation")
      candidates += %w[currency money] if words.include?("euro") || text.include?("3.8%") || text.include?("3%")
      candidates += %w[money wallet] if words.include?("cash")
      candidates += %w[savings wallet money] if words.include?("emergency") || words.include?("fund")
      candidates += %w[payment money] if words.include?("debt")
      candidates += %w[chart money] if words.include?("invest") || words.include?("assets") || words.include?("market")
      candidates += %w[bank savings] if words.include?("accounts") || words.include?("savings")
      candidates += %w[bank money] if words.include?("rates") || words.include?("bank")
      candidates += %w[money document] if words.include?("financial") || words.include?("advice") || words.include?("decision")
      candidates += %w[arrow lightbulb] if words.include?("move")
      candidates
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
