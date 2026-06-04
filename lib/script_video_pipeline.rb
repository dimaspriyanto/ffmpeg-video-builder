# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "date"
require "time"

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
  DEFAULT_WATERMARK_TEXT = "Financial\nAdvice"
  DEFAULT_WATERMARK_Y = 80
  DEFAULT_WATERMARK_FONT_SIZE = 30
  DEFAULT_WATERMARK_WIDTH = 360
  DEFAULT_WATERMARK_CANVAS_WIDTH = 480
  DEFAULT_TEXT_Y = 1320
  DEFAULT_TEXT_FONT_SIZE = 54
  DEFAULT_TEXT_WIDTH = 1000
  DEFAULT_TEXT_CANVAS_WIDTH = 1080
  DEFAULT_TEXT_RASTERIZE_SIZE = 640
  DEFAULT_TEXT_MAX_LINE_LENGTH = 20
  DEFAULT_WAVEFORM_WIDTH = DEFAULT_ICON_WIDTH
  DEFAULT_WAVEFORM_HEIGHT = 64
  DEFAULT_WAVEFORM_GAP = 44
  DEFAULT_WAVEFORM_OPACITY = 0.72
  DEFAULT_SUBTITLE_WORDS_PER_PARAGRAPH = 12
  DEFAULT_OPENING_TITLE_DURATION = 3.0
  DEFAULT_ICON_CANDIDATE_LIMIT = 8
  ICON_ANIMATIONS = %w[
    pop fade slide_left slide_right drop_in zoom_blur bounce rotate_in wipe_reveal pulse_in
  ].freeze
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

  ScriptContent = Struct.new(:title, :category, :body, keyword_init: true)

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

  def self.prepare_bulk(workspace_dir:, scripts_file: nil, options: {})
    Client.new.prepare_bulk(workspace_dir: workspace_dir, scripts_file: scripts_file, options: options)
  end

  def self.rebuild(project_dir:, options: {})
    Client.new.rebuild(project_dir: project_dir, options: options)
  end

  class Client
    def prepare(script_file:, options: {})
      script_file = validate_script_file!(script_file)
      script_content = parse_script_content(script_file)
      prepare_script_content(script_content: script_content, source_file: script_file, options: options)
    end

    def prepare_bulk(workspace_dir:, scripts_file: nil, options: {})
      workspace_dir = validate_workspace_dir!(workspace_dir)
      scripts_file = resolve_bulk_scripts_file(workspace_dir, scripts_file)
      script_contents = parse_bulk_script_contents(scripts_file)
      raise ArgumentError, "No scripts found in bulk script file: #{scripts_file}" if script_contents.empty?

      background = options[:background] || detect_workspace_background(workspace_dir)
      results = script_contents.map do |script_content|
        prepare_script_content(
          script_content: script_content,
          source_file: scripts_file,
          options: options.merge(background: background)
        )
      end

      write_json(
        File.join(workspace_dir, "bulk_manifest.json"),
        {
          "workspace_dir" => workspace_dir,
          "scripts_file" => scripts_file,
          "background" => background,
          "generated_at" => Time.now.iso8601,
          "videos" => results.map(&:to_h)
        }
      )

      results
    end

    def prepare_script_content(script_content:, source_file:, options: {})
      project_dir = create_project_dir(options.fetch(:downloads_root, DEFAULT_DOWNLOADS_ROOT))
      local_script_file = File.join(project_dir, "script_input.txt")
      File.write(local_script_file, script_content.body)

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
      config = build_ffmpeg_config(
        sentences,
        icon_plan,
        narration.audio_file,
        project_dir,
        options,
        title_text: script_content.title,
        category_text: script_content.category
      )
      config_file = write_json(File.join(project_dir, "config_project.json"), config)

      write_json(
        File.join(project_dir, "pipeline_metadata.json"),
        {
          title: script_content.title,
          category: script_content.category,
          source_script_file: source_file,
          script_file: local_script_file,
          audio_file: narration.audio_file,
          subtitle_file: transcription.sentence_files[:srt],
          icon_plan_file: icon_plan_file,
          config_file: config_file,
          background: config.fetch("background"),
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

    def rebuild(project_dir:, options: {})
      project_dir = validate_project_dir!(project_dir)
      metadata = read_json(File.join(project_dir, "pipeline_metadata.json"), default: {})
      existing_config = read_json(File.join(project_dir, "config_project.json"), default: {})
      icon_plan_file = File.join(project_dir, "icon_plan.json")
      subtitle_json_file = File.join(project_dir, "subtitle_sentences.json")
      audio_file = metadata["audio_file"] || File.join(project_dir, "audio_voiceover.wav")

      raise "Missing icon plan: #{icon_plan_file}" unless File.file?(icon_plan_file)
      raise "Missing audio file: #{audio_file}" unless File.file?(audio_file)

      icon_plan = read_json(icon_plan_file)
      sentences = File.file?(subtitle_json_file) ? read_json(subtitle_json_file) : sentences_from_icon_plan(icon_plan)
      raise "No sentence timings found for rebuild in #{project_dir}" if sentences.empty?

      icon_plan = download_icons_from_plan(icon_plan, project_dir, options)
      icon_plan_file = write_json(icon_plan_file, icon_plan)
      rebuild_options = options.dup
      existing_background = existing_config["background"] || metadata["background"]
      rebuild_options[:background] = existing_background if existing_background && !rebuild_options.key?(:background)
      rebuild_options[:width] ||= existing_config["width"] if existing_config["width"]
      rebuild_options[:height] ||= existing_config["height"] if existing_config["height"]
      rebuild_options[:fps] ||= existing_config["fps"] if existing_config["fps"]

      config = build_ffmpeg_config(
        sentences,
        icon_plan,
        audio_file,
        project_dir,
        rebuild_options,
        title_text: metadata["title"].to_s,
        category_text: metadata["category"].to_s
      )
      config_file = write_json(File.join(project_dir, "config_project.json"), config)

      write_json(
        File.join(project_dir, "pipeline_metadata.json"),
        metadata.merge(
          "audio_file" => audio_file,
          "subtitle_file" => metadata["subtitle_file"] || File.join(project_dir, "subtitle_sentences.srt"),
          "icon_plan_file" => icon_plan_file,
          "config_file" => config_file,
          "background" => config.fetch("background"),
          "output_file" => File.join(project_dir, config.fetch("output"))
        )
      )

      Result.new(
        project_dir: project_dir,
        script_file: metadata["script_file"] || File.join(project_dir, "script_input.txt"),
        audio_file: audio_file,
        subtitle_file: metadata["subtitle_file"] || File.join(project_dir, "subtitle_sentences.srt"),
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

    def validate_workspace_dir!(workspace_dir)
      path = File.expand_path(workspace_dir.to_s)
      raise ArgumentError, "Workspace directory not found: #{path}" unless File.directory?(path)

      path
    end

    def validate_project_dir!(project_dir)
      path = File.expand_path(project_dir.to_s)
      raise ArgumentError, "Project directory not found: #{path}" unless File.directory?(path)

      path
    end

    def create_project_dir(downloads_root)
      ProjectDirectory.create(root: downloads_root)
    end

    def read_json(path, default: nil)
      return default unless File.file?(path)

      JSON.parse(File.read(path))
    end

    def sentences_from_icon_plan(icon_plan)
      icon_plan.map do |planned_icon|
        {
          "index" => planned_icon["sentence_index"],
          "start" => planned_icon.fetch("start"),
          "end" => planned_icon.fetch("end"),
          "text" => planned_icon.fetch("sentence")
        }
      end
    end

    def download_icons_from_plan(icon_plan, project_dir, options)
      validate_unique_icon_ids!(icon_plan)

      icon_plan.each_with_index.map do |planned_icon, index|
        icon_id = planned_icon["icon_id"].to_s.strip
        planned_icon = planned_icon.dup

        if icon_id.empty?
          planned_icon.delete("icon_file")
          next planned_icon
        end

        icon_dir = File.join(project_dir, "icons", format("%02d", planned_icon["sentence_index"] || index + 1))
        icon = IconSearch.download_icon_by_id(
          icon_id: icon_id,
          license_type: options.fetch(:icon_license_type, IconSearch::DEFAULT_LICENSE_TYPE),
          size: options.fetch(:icon_size, IconSearch::DEFAULT_SIZE),
          download_dir: icon_dir
        )

        planned_icon.merge(
          "keyword" => planned_icon["keyword"].to_s.empty? ? icon.name : planned_icon["keyword"],
          "icon_id" => icon.id,
          "icon_file" => icon.downloaded_file,
          "icon_license" => icon.license,
          "icon_license_type" => icon.license_type,
          "icon_source" => icon.source,
          "icon_source_name" => icon.source_name,
          "icon_style" => icon.style,
          "icon_svg_url" => icon.svg_url
        )
      end
    end

    def validate_unique_icon_ids!(icon_plan)
      seen = {}

      icon_plan.each_with_index do |planned_icon, index|
        icon_id = planned_icon["icon_id"].to_s.strip
        next if icon_id.empty?

        if seen[icon_id]
          sentence = planned_icon["sentence_index"] || index + 1
          raise ArgumentError, "Duplicate icon_id in icon_plan.json: #{icon_id}. Choose a different icon for sentence #{sentence}."
        end

        seen[icon_id] = true
      end
    end

    def parse_script_content(script_file)
      text = File.read(script_file, encoding: "UTF-8").gsub(/\r\n?/, "\n")
      parse_script_text(text, script_file)
    end

    def parse_bulk_script_contents(scripts_file)
      text = File.read(scripts_file, encoding: "UTF-8").gsub(/\r\n?/, "\n")
      blocks = split_bulk_script_text(text)

      blocks.each_with_index.map do |block, index|
        parse_script_text(block, "#{scripts_file}##{index + 1}")
      end
    end

    def split_bulk_script_text(text)
      lines = text.lines(chomp: true)
      title_indexes = lines.each_index.select { |index| lines[index].strip.match?(/\ATitle:\s*\S/i) }

      if title_indexes.length > 1
        return title_indexes.each_with_index.map do |start_index, index|
          end_index = title_indexes[index + 1] || lines.length
          lines[start_index...end_index].join("\n")
        end
      end

      delimiter_blocks = text.split(/^\s*-{3,}\s*$/).map(&:strip).reject(&:empty?)
      return delimiter_blocks if delimiter_blocks.length > 1

      [text]
    end

    def parse_script_text(text, script_file)
      lines = text.lines(chomp: true)
      raise ArgumentError, "Script file is empty: #{script_file}" if lines.all? { |line| line.strip.empty? }

      title = nil
      category = nil
      content_index = lines.find_index { |line| line.strip.match?(/\AContent:\s*/i) }

      if content_index
        header_lines = lines[0...content_index]
        title, category = extract_script_headers(header_lines)
        first_content = lines[content_index].strip.sub(/\AContent:\s*/i, "")
        body_lines = []
        body_lines << first_content unless first_content.empty?
        body_lines.concat(lines[(content_index + 1)..] || [])
      else
        body_lines = []
        reading_headers = true

        lines.each do |line|
          stripped = line.strip
          if reading_headers
            if (match = stripped.match(/\ATitle:\s*(.+)\z/i))
              title = match[1].strip
              next
            end

            if (match = stripped.match(/\ACategory:\s*(.+)\z/i))
              category = match[1].strip
              next
            end

            next if stripped.empty? && (title || category)
          end

          reading_headers = false
          body_lines << line
        end
      end

      body = normalize_script_body(body_lines.join("\n"), script_file)
      ScriptContent.new(
        title: title.to_s.strip.empty? ? first_paragraph_text(body) : title.to_s.strip,
        category: category.to_s.strip,
        body: body
      )
    end

    def extract_script_headers(lines)
      title = nil
      category = nil

      lines.each do |line|
        case line.strip
        when /\ATitle:\s*(.+)\z/i
          title = Regexp.last_match(1).strip
        when /\ACategory:\s*(.+)\z/i
          category = Regexp.last_match(1).strip
        end
      end

      [title, category]
    end

    def normalize_script_body(text, script_file)
      body = text.gsub(/\A[[:space:]]+/, "").gsub(/[[:space:]]+\z/, "")
      raise ArgumentError, "Script content is empty after parsing headers: #{script_file}" if body.empty?

      "#{body}\n"
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

    def build_ffmpeg_config(sentences, icon_plan, audio_file, project_dir, options, title_text:, category_text:)
      duration = [sentences.map { |sentence| sentence.fetch("end").to_f }.max + 0.35, 1.0].max.round(3)
      elements = [watermark_element(duration, category_text)]
      elements << waveform_element(duration, audio_file, project_dir) if options.fetch(:pipeline_waveform, true)
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

        subtitle_paragraphs(text, text_start, text_end).each do |paragraph|
          elements << {
            "type" => "text",
            "text" => wrap_text(paragraph.fetch("text"), DEFAULT_TEXT_MAX_LINE_LENGTH),
            "start" => paragraph.fetch("start"),
            "end" => paragraph.fetch("end"),
            "paragraph_index" => paragraph.fetch("paragraph_index"),
            "paragraph_count" => paragraph.fetch("paragraph_count"),
            "font_size" => DEFAULT_TEXT_FONT_SIZE,
            "color" => "black",
            "x" => "center",
            "y" => DEFAULT_TEXT_Y,
            "text_align" => "left",
            "box" => false,
            "fallback_width" => DEFAULT_TEXT_WIDTH,
            "fallback_canvas_width" => DEFAULT_TEXT_CANVAS_WIDTH,
            "fallback_rasterize_size" => DEFAULT_TEXT_RASTERIZE_SIZE
          }
        end
      end

      {
        "output" => output_filename(project_dir, title_text),
        "width" => options.fetch(:width, DEFAULT_WIDTH),
        "height" => options.fetch(:height, DEFAULT_HEIGHT),
        "fps" => options.fetch(:fps, DEFAULT_FPS),
        "duration" => duration,
        "background" => background_config(options),
        "audio" => relative_path(audio_file, project_dir),
        "elements" => elements
      }
    end

    def background_config(options)
      deep_dup(options.fetch(:background, DEFAULT_BACKGROUND))
    end

    def resolve_bulk_scripts_file(workspace_dir, scripts_file)
      if scripts_file
        direct_path = File.expand_path(scripts_file.to_s)
        workspace_path = File.expand_path(scripts_file.to_s, workspace_dir)
        return direct_path if File.file?(direct_path)
        return workspace_path if File.file?(workspace_path)

        raise ArgumentError, "Bulk script file not found: #{scripts_file}"
      end

      preferred = %w[scripts.txt script.txt bulk_scripts.txt input.txt content.txt]
      preferred.each do |filename|
        path = File.join(workspace_dir, filename)
        return path if File.file?(path)
      end

      text_files = Dir.children(workspace_dir)
                      .map { |entry| File.join(workspace_dir, entry) }
                      .select { |path| File.file?(path) && File.extname(path).downcase == ".txt" }
                      .sort

      return text_files.first if text_files.length == 1

      if text_files.empty?
        raise ArgumentError, "No script text file found in #{workspace_dir}. Add scripts.txt or pass --bulk-scripts FILE."
      end

      raise ArgumentError, "Multiple text files found in #{workspace_dir}. Pass --bulk-scripts FILE."
    end

    def detect_workspace_background(workspace_dir)
      preferred = supported_background_files(workspace_dir).select do |path|
        File.basename(path).match?(/\Abackground\./i)
      end
      return background_config_from_path(preferred.sort.first) unless preferred.empty?

      media_files = supported_background_files(workspace_dir)
      return DEFAULT_BACKGROUND if media_files.empty?
      return background_config_from_path(media_files.first) if media_files.length == 1

      raise ArgumentError, "Multiple background media files found in #{workspace_dir}. Name one background.ext or pass --background-image/--background-video."
    end

    def supported_background_files(workspace_dir)
      Dir.children(workspace_dir)
         .map { |entry| File.join(workspace_dir, entry) }
         .select { |path| File.file?(path) && background_media_type(path) }
         .sort
    end

    def background_config_from_path(path)
      { "type" => background_media_type(path), "path" => File.expand_path(path) }
    end

    def background_media_type(path)
      case File.extname(path.to_s).downcase
      when ".png", ".jpg", ".jpeg", ".webp", ".bmp"
        "image"
      when ".mp4", ".mov", ".webm", ".mkv"
        "video"
      end
    end

    def deep_dup(value)
      JSON.parse(JSON.generate(value))
    end

    def waveform_element(duration, audio_file, project_dir)
      {
        "type" => "waveform",
        "audio" => relative_path(audio_file, project_dir),
        "start" => 0,
        "end" => duration,
        "width" => DEFAULT_WAVEFORM_WIDTH,
        "height" => DEFAULT_WAVEFORM_HEIGHT,
        "x" => "center",
        "position" => "bottom",
        "anchor_y" => DEFAULT_ICON_Y,
        "anchor_height" => DEFAULT_ICON_WIDTH,
        "gap" => DEFAULT_WAVEFORM_GAP,
        "color" => "0x111111",
        "opacity" => DEFAULT_WAVEFORM_OPACITY,
        "mode" => "cline",
        "scale" => "sqrt",
        "remove_background" => true
      }
    end

    def output_filename(project_dir, title_text)
      "#{project_date_stamp(project_dir)}_#{title_filename_component(title_text)}.mp4"
    end

    def project_date_stamp(project_dir)
      basename = File.basename(project_dir.to_s)
      match = basename.match(/_(\d{8})\z/)
      return match[1] if match

      Date.today.strftime("%d%m%Y")
    end

    def title_filename_component(title_text)
      words = title_text.to_s.scan(/[[:alnum:]]+/)
      return "UntitledVideo" if words.empty?

      words.map { |word| word[0].upcase + word[1..].to_s }.join
    end

    def watermark_element(duration, category_text)
      {
        "type" => "text",
        "text" => watermark_text(category_text),
        "start" => 0,
        "end" => duration,
        "font_size" => DEFAULT_WATERMARK_FONT_SIZE,
        "color" => "black",
        "x" => "center",
        "y" => DEFAULT_WATERMARK_Y,
        "text_align" => "center",
        "box" => false,
        "fallback_width" => DEFAULT_WATERMARK_WIDTH,
        "fallback_canvas_width" => DEFAULT_WATERMARK_CANVAS_WIDTH,
        "fallback_rasterize_size" => DEFAULT_TEXT_RASTERIZE_SIZE
      }
    end

    def watermark_text(category_text)
      text = category_text.to_s.strip
      return DEFAULT_WATERMARK_TEXT if text.empty?
      return text if text.include?("\n")

      text.split(/\s+/).join("\n")
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

    def first_paragraph_text(text)
      text.to_s.split(/\n{2,}/)
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

    def subtitle_paragraphs(text, start_time, end_time)
      words = text.to_s.split(/\s+/)
      return [] if words.empty?

      chunks = words.each_slice(DEFAULT_SUBTITLE_WORDS_PER_PARAGRAPH).to_a
      start_time = start_time.to_f
      end_time = end_time.to_f
      duration = [end_time - start_time, 0.001].max
      chunk_duration = duration / chunks.length

      chunks.each_with_index.map do |chunk, index|
        chunk_start = (start_time + (chunk_duration * index)).round(3)
        chunk_end = if index == chunks.length - 1
                      end_time.round(3)
                    else
                      (start_time + (chunk_duration * (index + 1))).round(3)
                    end

        {
          "text" => chunk.join(" "),
          "start" => chunk_start,
          "end" => chunk_end,
          "paragraph_index" => index + 1,
          "paragraph_count" => chunks.length
        }
      end
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
