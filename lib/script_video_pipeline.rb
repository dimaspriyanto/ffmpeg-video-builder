# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "date"
require "time"

require_relative "icon_search"
require_relative "narration_tts"
require_relative "openai_whisper"
require_relative "project_directory"

module ScriptVideoPipeline
  DEFAULT_DOWNLOADS_ROOT = ProjectDirectory::DEFAULT_ROOT
  DEFAULT_WIDTH = 1080
  DEFAULT_HEIGHT = 1920
  DEFAULT_FPS = 30
  DEFAULT_BACKGROUND = { "type" => "color", "color" => "#FFC067" }.freeze
  DEFAULT_ICON_WIDTH = 320
  DEFAULT_DARK_BACKGROUND_ICON_WIDTH = 320
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
  DEFAULT_FIRST_SUBTITLE_TITLE_DURATION = 1.0
  DEFAULT_ICON_CANDIDATE_LIMIT = 8
  ICON_ANIMATIONS = %w[
    pop fade slide_left slide_right drop_in zoom_blur bounce rotate_in wipe_reveal pulse_in delayed_zoom blink
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

  def self.synchronize_project_subtitles(project_dir:, script_file:)
    Client.new.synchronize_project_subtitles(project_dir: project_dir, script_file: script_file)
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
      results = script_contents.each_with_index.map do |script_content, index|
        prepare_script_content(
          script_content: script_content,
          source_file: scripts_file,
          options: options.merge(background: background, bulk_video_index: index + 1)
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
      copy_source_icon_config(source_file, project_dir)

      narration = NarrationTTS.speak(
        text_file: local_script_file,
        download_dir: project_dir,
        options: options
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

      sentences = synchronize_sentence_texts(transcription.sentences, script_content.body)
      raise "Whisper did not produce sentence timings" if sentences.empty?
      sentences, narration_audio_file = apply_sentence_pause(sentences, narration.audio_file, project_dir, options)
      subtitle_files = write_subtitle_files(project_dir, sentences)

      icon_config_file = File.join(project_dir, "icon_config.json")
      icon_config = read_json(icon_config_file, default: {})
      icon_config = expand_local_icon_pool(icon_config, sentences, options)
      write_json(icon_config_file, icon_config) unless icon_config.empty?
      local_icon_sentence_indexes = local_icon_config_by_sentence(icon_config, project_dir).keys
      icon_plan = build_icon_plan(sentences, project_dir, options, local_icon_sentence_indexes: local_icon_sentence_indexes)
      icon_plan = download_icons_from_plan(icon_plan, project_dir, options, icon_config)
      icon_plan_file = write_json(File.join(project_dir, "icon_plan.json"), icon_plan)
      config = build_ffmpeg_config(
        sentences,
        icon_plan,
        narration_audio_file,
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
          audio_file: narration_audio_file,
          original_audio_file: narration.audio_file == narration_audio_file ? nil : narration.audio_file,
          tts_engine: NarrationTTS.engine(options),
          tts_metadata_file: narration.metadata_file,
          subtitle_file: subtitle_files[:srt],
          icon_plan_file: icon_plan_file,
          config_file: config_file,
          background: config.fetch("background"),
          output_file: File.join(project_dir, config.fetch("output"))
        }
      )

      Result.new(
        project_dir: project_dir,
        script_file: local_script_file,
        audio_file: narration_audio_file,
        subtitle_file: subtitle_files[:srt],
        icon_plan_file: icon_plan_file,
        config_file: config_file,
        output_file: File.join(project_dir, config.fetch("output"))
      )
    end

    def synchronize_project_subtitles(project_dir:, script_file:)
      project_dir = validate_project_dir!(project_dir)
      script_file = validate_script_file!(script_file)
      script_content = parse_script_content(script_file)
      subtitle_file = File.join(project_dir, "subtitle_sentences.json")
      icon_plan_file = File.join(project_dir, "icon_plan.json")

      raise "Missing subtitle timings: #{subtitle_file}" unless File.file?(subtitle_file)
      raise "Missing icon plan: #{icon_plan_file}" unless File.file?(icon_plan_file)

      sentences = synchronize_sentence_texts(read_json(subtitle_file), script_content.body)
      write_subtitle_files(project_dir, sentences)

      icon_plan = read_json(icon_plan_file)
      synchronized_text = sentences.to_h { |sentence| [sentence.fetch("index").to_i, sentence.fetch("text")] }
      icon_plan.each do |planned_icon|
        planned_icon["sentence"] = synchronized_text.fetch(planned_icon.fetch("sentence_index").to_i)
      end
      write_json(icon_plan_file, icon_plan)

      sentences
    end

    def rebuild(project_dir:, options: {})
      project_dir = validate_project_dir!(project_dir)
      metadata = read_json(File.join(project_dir, "pipeline_metadata.json"), default: {})
      existing_config = read_json(File.join(project_dir, "config_project.json"), default: {})
      icon_plan_file = File.join(project_dir, "icon_plan.json")
      icon_config_file = File.join(project_dir, "icon_config.json")
      subtitle_json_file = File.join(project_dir, "subtitle_sentences.json")
      audio_file = metadata["audio_file"] || File.join(project_dir, "audio_voiceover.wav")

      raise "Missing icon plan: #{icon_plan_file}" unless File.file?(icon_plan_file)
      raise "Missing audio file: #{audio_file}" unless File.file?(audio_file)

      icon_plan = read_json(icon_plan_file)
      icon_config = read_json(icon_config_file, default: {})
      sentences = File.file?(subtitle_json_file) ? read_json(subtitle_json_file) : sentences_from_icon_plan(icon_plan)
      raise "No sentence timings found for rebuild in #{project_dir}" if sentences.empty?

      icon_plan = download_icons_from_plan(icon_plan, project_dir, options, icon_config)
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

    def copy_source_icon_config(source_file, project_dir)
      source_dir = File.dirname(File.expand_path(source_file.to_s))
      icon_config_file = File.join(source_dir, "icon_config.json")
      return unless File.file?(icon_config_file)

      FileUtils.cp(icon_config_file, File.join(project_dir, "icon_config.json"))
      source_icons_dir = File.join(source_dir, "icons")
      return unless File.directory?(source_icons_dir)

      FileUtils.mkdir_p(File.join(project_dir, "icons"))
      FileUtils.cp_r(Dir.glob(File.join(source_icons_dir, "*")), File.join(project_dir, "icons"))
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

    def download_icons_from_plan(icon_plan, project_dir, options, icon_config = {})
      validate_unique_icon_ids!(icon_plan)
      local_icons = local_icon_config_by_sentence(icon_config, project_dir)

      icon_plan.each_with_index.map do |planned_icon, index|
        planned_icon = planned_icon.dup
        sentence_index = planned_icon["sentence_index"] || index + 1

        if (local_icon = local_icons[sentence_index.to_i])
          next apply_local_icon_config(planned_icon, local_icon, project_dir, sentence_index)
        end

        icon_id = planned_icon["icon_id"].to_s.strip

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

    def local_icon_config_by_sentence(icon_config, project_dir)
      return {} unless icon_config.is_a?(Hash) || icon_config.is_a?(Array)

      entries =
        if icon_config.is_a?(Array)
          icon_config
        elsif icon_config["icons"].is_a?(Array)
          icon_config["icons"]
        else
          icon_config.map do |sentence_index, value|
            value.is_a?(Hash) ? value.merge("sentence_index" => sentence_index) : { "sentence_index" => sentence_index, "file" => value }
          end
        end

      entries.each_with_object({}) do |entry, local_icons|
        next unless entry.is_a?(Hash)

        entry = entry.transform_keys(&:to_s)
        sentence_index = entry["sentence_index"].to_i
        next if sentence_index <= 0

        file = entry["file"] || entry["path"] || entry["icon_file"]
        next if file.to_s.strip.empty?

        resolved_file = File.expand_path(file.to_s, project_dir)
        raise ArgumentError, "Local icon file not found for sentence #{sentence_index}: #{resolved_file}" unless File.file?(resolved_file)

        local_icons[sentence_index] = entry.merge("file" => resolved_file)
      end
    end

    def expand_local_icon_pool(icon_config, sentences, options)
      if icon_config.is_a?(Hash) && icon_config["icon_sets"].is_a?(Array)
        video_index = options.fetch(:bulk_video_index, 1).to_i
        icon_set = icon_config.fetch("icon_sets")[video_index - 1]
        raise ArgumentError, "icon_sets does not contain icons for bulk video #{video_index}" unless icon_set.is_a?(Array)

        pool = icon_set.map(&:to_s).reject(&:empty?)
        raise ArgumentError, "Icon set #{video_index} must contain at least one local icon file" if pool.empty?
        skip_second_icon = options[:pipeline_skip_second_icon_after_first_animation] &&
                           options[:pipeline_first_icon_delayed_animation].to_s != "" &&
                           options.fetch(:pipeline_first_icon_animation_delay, 0).to_f.positive?

        return {
          "icons" => sentences.each_with_index.map do |sentence, index|
            pool_index = skip_second_icon && index.positive? ? index + 1 : index
            {
              "sentence_index" => sentence.fetch("index"),
              "file" => pool[pool_index] || pool.last
            }
          end
        }
      end

      return icon_config unless icon_config.is_a?(Hash) && icon_config["icon_pool"].is_a?(Array)

      pool = icon_config.fetch("icon_pool").map(&:to_s).reject(&:empty?)
      raise ArgumentError, "icon_pool must contain at least one local icon file" if pool.empty?

      video_index = options.fetch(:bulk_video_index, 1).to_i
      first_icon = pool[video_index - 1]
      if first_icon.nil?
        raise ArgumentError, "icon_pool has #{pool.length} files, but bulk video #{video_index} needs a matching first icon"
      end

      previous_icon = first_icon
      assignments = sentences.map do |sentence|
        sentence_index = sentence.fetch("index").to_i
        icon_file =
          if sentence_index == 1
            first_icon
          else
            choices = pool.length > 1 ? pool.reject { |file| file == previous_icon } : pool
            choices.sample
          end
        previous_icon = icon_file

        {
          "sentence_index" => sentence_index,
          "file" => icon_file
        }
      end

      { "icons" => assignments }
    end

    def apply_local_icon_config(planned_icon, local_icon, project_dir, sentence_index)
      icon_dir = File.join(project_dir, "icons", format("%02d", sentence_index))
      FileUtils.mkdir_p(icon_dir)

      source = local_icon.fetch("file")
      target = File.join(icon_dir, "local_#{File.basename(source)}")
      FileUtils.cp(source, target) unless File.expand_path(source) == File.expand_path(target)

      planned_icon.merge(
        "keyword" => local_icon["keyword"].to_s.empty? ? planned_icon["keyword"] : local_icon["keyword"],
        "icon_id" => local_icon["icon_id"].to_s.empty? ? "local:#{File.basename(source, '.*')}" : local_icon["icon_id"],
        "icon_file" => target,
        "icon_license" => local_icon["license"] || local_icon["icon_license"] || "local",
        "icon_license_type" => local_icon["license_type"] || local_icon["icon_license_type"] || "local",
        "icon_source" => local_icon["source"] || local_icon["icon_source"] || "local",
        "icon_source_name" => local_icon["source_name"] || local_icon["icon_source_name"] || "Local icon_config.json",
        "icon_style" => local_icon["style"] || local_icon["icon_style"] || "local",
        "icon_svg_url" => local_icon["svg_url"] || local_icon["icon_svg_url"]
      ).tap do |merged|
        merged["animation"] = local_icon["animation"] if local_icon["animation"]
        merged.delete("icon_svg_url") if merged["icon_svg_url"].to_s.empty?
      end
    end

    def validate_unique_icon_ids!(icon_plan)
      seen = {}

      icon_plan.each_with_index do |planned_icon, index|
        icon_id = planned_icon["icon_id"].to_s.strip
        next if icon_id.empty? || icon_id.start_with?("local:")

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
      title_indexes = lines.each_index.select do |index|
        normalize_script_header_line(lines[index]).match?(/\ATitle:\s*\S/i)
      end

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
      content_index = lines.find_index { |line| normalize_script_header_line(line).match?(/\AContent:\s*/i) }

      if content_index
        header_lines = lines[0...content_index]
        title, category = extract_script_headers(header_lines)
        first_content = normalize_script_header_line(lines[content_index]).sub(/\AContent:\s*/i, "")
        body_lines = []
        body_lines << first_content unless first_content.empty?
        body_lines.concat(content_body_lines(lines[(content_index + 1)..] || []))
      else
        body_lines = []
        reading_headers = true

        lines.each do |line|
          stripped = normalize_script_header_line(line)
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
        case normalize_script_header_line(line)
        when /\ATitle:\s*(.+)\z/i
          title = Regexp.last_match(1).strip
        when /\ACategory:\s*(.+)\z/i
          category = Regexp.last_match(1).strip
        end
      end

      [title, category]
    end

    def normalize_script_header_line(line)
      line.to_s.strip.sub(/\A\*\*/, "").sub(/\*\*\z/, "").strip
    end

    def content_body_lines(lines)
      lines.take_while do |line|
        !normalize_script_header_line(line).match?(/\A-{3,}\z/)
      end
    end

    def normalize_script_body(text, script_file)
      body = text.gsub(/\A[[:space:]]+/, "").gsub(/[[:space:]]+\z/, "")
      raise ArgumentError, "Script content is empty after parsing headers: #{script_file}" if body.empty?

      "#{body}\n"
    end

    def synchronize_sentence_texts(sentences, script_body)
      source_sentences = source_sentence_texts(script_body)
      sentences = merge_excess_sentence_timings(sentences, source_sentences.length)
      sentences = split_missing_sentence_timings(sentences, source_sentences.length)
      if source_sentences.length != sentences.length
        raise ArgumentError,
              "Script has #{source_sentences.length} sentences, but Whisper produced #{sentences.length} timings. " \
              "Adjust the script sentence breaks before generating the video."
      end

      sentences.each_with_index.map do |sentence, index|
        sentence.merge("index" => index + 1, "text" => source_sentences.fetch(index))
      end
    end

    def merge_excess_sentence_timings(sentences, target_count)
      merged = sentences.map(&:dup)

      while merged.length > target_count && merged.length > 1
        merge_index = (0...(merged.length - 1)).min_by do |index|
          merged[index + 1].fetch("start").to_f - merged[index].fetch("end").to_f
        end
        first = merged.fetch(merge_index)
        second = merged.fetch(merge_index + 1)
        merged[merge_index, 2] = [{
          "index" => first.fetch("index"),
          "start" => first.fetch("start"),
          "end" => second.fetch("end"),
          "text" => [first.fetch("text"), second.fetch("text")].join(" ").strip
        }]
      end

      merged
    end

    def split_missing_sentence_timings(sentences, target_count)
      split = sentences.map(&:dup)

      while split.length < target_count && split.length > 1
        split_index = split.each_index.max_by do |index|
          split[index].fetch("end").to_f - split[index].fetch("start").to_f
        end
        sentence = split.fetch(split_index)
        start_time = sentence.fetch("start").to_f
        end_time = sentence.fetch("end").to_f
        midpoint = ((start_time + end_time) / 2.0).round(3)

        if midpoint <= start_time || midpoint >= end_time
          midpoint = (start_time + 0.001).round(3)
        end

        first = sentence.merge("end" => midpoint)
        second = sentence.merge("start" => midpoint)
        split[split_index, 1] = [first, second]
      end

      split
    end

    def source_sentence_texts(script_body)
      lines = script_body.to_s.lines.map(&:strip).reject(&:empty?)
      lines.flat_map do |line|
        line.scan(/[^.!?]+[.!?]?/).map(&:strip).reject(&:empty?).flat_map do |sentence|
          split_leading_quoted_sentence(sentence)
        end
      end
    end

    def split_leading_quoted_sentence(sentence)
      text = sentence.to_s.strip
      match = text.match(/\A((?:“[^”]+”|"[^"]+"))\s+(.+)\z/)
      return [text] unless match

      [match[1].strip, match[2].strip].reject(&:empty?)
    end

    def write_subtitle_files(project_dir, sentences)
      json_file = write_json(File.join(project_dir, "subtitle_sentences.json"), sentences)
      srt_file = File.join(project_dir, "subtitle_sentences.srt")
      File.write(srt_file, sentences_to_srt(sentences))
      { json: json_file, srt: srt_file }
    end

    def apply_sentence_pause(sentences, audio_file, project_dir, options)
      pause_seconds = options.fetch(:pipeline_sentence_pause, 0).to_f
      return [sentences, audio_file] unless pause_seconds.positive? && sentences.length > 1

      output_file = File.join(project_dir, "audio_voiceover_paused.wav")
      filters = []
      labels = []
      trim_padding = options.fetch(:pipeline_sentence_trim_padding, 0.12).to_f

      sentences.each_with_index do |sentence, index|
        segment_label = "s#{index}"
        segment_start = sentence.fetch("start").to_f
        segment_end = sentence.fetch("end").to_f
        previous_end = index.positive? ? sentences[index - 1].fetch("end").to_f : 0.0
        next_start = sentences[index + 1]&.fetch("start")&.to_f
        padded_start = [segment_start - trim_padding, previous_end, 0.0].max
        padded_end = next_start ? [segment_end + trim_padding, next_start].min : segment_end + trim_padding
        padded_end = [padded_end, padded_start + 0.001].max

        filters << "[0:a]atrim=start=#{padded_start}:end=#{padded_end},asetpts=PTS-STARTPTS[#{segment_label}]"
        labels << segment_label

        next if index == sentences.length - 1

        pause_label = "p#{index}"
        filters << "anullsrc=r=22050:cl=mono,atrim=duration=#{pause_seconds},asetpts=PTS-STARTPTS[#{pause_label}]"
        labels << pause_label
      end

      concat_inputs = labels.map { |label| "[#{label}]" }.join
      filters << "#{concat_inputs}concat=n=#{labels.length}:v=0:a=1[out]"

      command = [
        "ffmpeg", "-y",
        "-i", audio_file,
        "-filter_complex", filters.join(";"),
        "-map", "[out]",
        "-ar", "22050",
        "-ac", "1",
        output_file
      ]
      stdout, stderr, status = Open3.capture3(*command)
      raise "Failed to insert sentence pauses: #{stderr.empty? ? stdout : stderr}" unless status.success?
      raise "Sentence pause audio was not created: #{output_file}" unless File.file?(output_file)

      current_time = 0.0
      paused_sentences = sentences.map.with_index do |sentence, index|
        segment_start = sentence.fetch("start").to_f
        segment_end = sentence.fetch("end").to_f
        previous_end = index.positive? ? sentences[index - 1].fetch("end").to_f : 0.0
        next_start = sentences[index + 1]&.fetch("start")&.to_f
        padded_start = [segment_start - trim_padding, previous_end, 0.0].max
        padded_end = next_start ? [segment_end + trim_padding, next_start].min : segment_end + trim_padding
        duration = [padded_end - padded_start, 0.001].max
        start_time = current_time
        end_time = start_time + duration
        current_time = end_time + (index == sentences.length - 1 ? 0.0 : pause_seconds)

        sentence.merge(
          "start" => start_time.round(3),
          "end" => end_time.round(3)
        )
      end

      [paused_sentences, output_file]
    end

    def sentences_to_srt(sentences)
      sentences.map do |sentence|
        [
          sentence.fetch("index"),
          "#{srt_time(sentence.fetch("start"))} --> #{srt_time(sentence.fetch("end"))}",
          sentence.fetch("text"),
          ""
        ].join("\n")
      end.join("\n")
    end

    def srt_time(seconds)
      milliseconds = (seconds.to_f * 1000).round
      hours = milliseconds / 3_600_000
      milliseconds %= 3_600_000
      minutes = milliseconds / 60_000
      milliseconds %= 60_000
      secs = milliseconds / 1000
      millis = milliseconds % 1000
      format("%<hours>02d:%<minutes>02d:%<seconds>02d,%<millis>03d",
             hours: hours, minutes: minutes, seconds: secs, millis: millis)
    end

    def build_icon_plan(sentences, project_dir, options, local_icon_sentence_indexes: [])
      used_icon_ids = {}

      sentences.map do |sentence|
        index = sentence.fetch("index")
        keywords = icon_keywords(sentence.fetch("text"))
        if local_icon_sentence_indexes.include?(index.to_i)
          keyword = keywords.first
          icon = nil
        else
          icon_dir = File.join(project_dir, "icons", format("%02d", index))
          keyword, icon = first_matching_icon(
            keywords: keywords,
            icon_dir: icon_dir,
            options: options,
            used_icon_ids: used_icon_ids
          )
          used_icon_ids[icon.id] = true if icon
        end

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
      background = background_config(options)
      text_color = options.fetch(:pipeline_text_color, dark_background?(background) ? "white" : "black")
      category_color = options.fetch(:pipeline_category_color, text_color)
      font_family = options[:pipeline_font_family].to_s.strip
      waveform_color = options.fetch(:pipeline_waveform_color, dark_background?(background) ? "0xffffff" : "0x111111")
      visible_icons = icon_plan.select { |planned_icon| planned_icon["icon_file"] }
      icon_width = options.fetch(:pipeline_icon_width, dark_background?(background) ? DEFAULT_DARK_BACKGROUND_ICON_WIDTH : DEFAULT_ICON_WIDTH)
      layout_offset_y = options.fetch(:pipeline_layout_offset_y, 0).to_f
      icon_y = options.key?(:pipeline_icon_y) ? options.fetch(:pipeline_icon_y).to_f : DEFAULT_ICON_Y + layout_offset_y
      text_y = options.key?(:pipeline_text_y) ? options.fetch(:pipeline_text_y).to_f : DEFAULT_TEXT_Y + layout_offset_y
      forced_icon_animation = options[:pipeline_icon_animation].to_s
      first_icon_delayed_animation = options[:pipeline_first_icon_delayed_animation].to_s
      first_icon_animation_delay = options.fetch(:pipeline_first_icon_animation_delay, 0).to_f
      elements = [watermark_element(duration, category_text, color: category_color, font_family: font_family)]
      if options.fetch(:pipeline_waveform, true)
        elements << waveform_element(duration, audio_file, project_dir, color: waveform_color, anchor_y: icon_y)
      end

      icon_plan.each_with_index do |planned_icon, icon_index|
        text_start = visual_start_time(planned_icon)
        text_end = visual_text_end_time(planned_icon, text_start)
        text = planned_icon.fetch("sentence")

        if planned_icon["icon_file"]
          position = visible_icons.index(planned_icon)
          icon_start = icon_index.zero? ? 0.0 : visual_start_time(planned_icon)
          icon_end = icon_end_time(position, visible_icons, duration)
          icon_file = relative_path(planned_icon.fetch("icon_file"), project_dir)
          if icon_index.zero? && ICON_ANIMATIONS.include?(first_icon_delayed_animation) && first_icon_animation_delay.positive?
            split_time = [icon_start + first_icon_animation_delay, icon_end].min.round(3)
            animation_end = first_icon_delayed_animation == "blink" ? [split_time + 0.34, icon_end].min.round(3) : icon_end
            elements << {
              "type" => "image",
              "file" => icon_file,
              "start" => icon_start,
              "end" => split_time,
              "width" => icon_width,
              "x" => DEFAULT_ICON_X,
              "y" => icon_y,
              "animation" => "none",
              "animation_delay" => 0,
              "trim_transparency" => false,
              "hold" => true
            }
            elements << {
              "type" => "image",
              "file" => icon_file,
              "start" => split_time,
              "end" => animation_end,
              "width" => icon_width,
              "x" => DEFAULT_ICON_X,
              "y" => icon_y,
              "animation" => first_icon_delayed_animation,
              "animation_delay" => 0,
              "trim_transparency" => false,
              "hold" => true
            }
            if animation_end < icon_end
              elements << {
                "type" => "image",
                "file" => icon_file,
                "start" => animation_end,
                "end" => icon_end,
                "width" => icon_width,
                "x" => DEFAULT_ICON_X,
                "y" => icon_y,
                "animation" => "none",
                "animation_delay" => 0,
                "trim_transparency" => false,
                "hold" => true
              }
            end
          else
            elements << {
              "type" => "image",
              "file" => icon_file,
              "start" => icon_start,
              "end" => icon_end,
              "width" => icon_width,
              "x" => DEFAULT_ICON_X,
              "y" => icon_y,
              "animation" => icon_animation_for(
                planned_icon,
                icon_index,
                forced: forced_icon_animation,
                first_delayed_animation: first_icon_delayed_animation
              ),
              "animation_delay" => icon_index.zero? ? first_icon_animation_delay : 0,
              "trim_transparency" => false,
              "hold" => true
            }
          end
        end

        subtitle_segments(text, text_start, text_end, planned_icon, title_text).each do |segment|
          subtitle_paragraphs(segment.fetch("text"), segment.fetch("start"), segment.fetch("end")).each do |paragraph|
            elements << {
              "type" => "text",
              "text" => wrap_text(paragraph.fetch("text"), DEFAULT_TEXT_MAX_LINE_LENGTH),
              "start" => paragraph.fetch("start"),
              "end" => paragraph.fetch("end"),
              "paragraph_index" => paragraph.fetch("paragraph_index"),
              "paragraph_count" => paragraph.fetch("paragraph_count"),
              "font_size" => DEFAULT_TEXT_FONT_SIZE,
              "color" => text_color,
              "x" => "center",
              "y" => text_y,
              "text_align" => "left",
              "box" => false,
              "fallback_width" => DEFAULT_TEXT_WIDTH,
              "fallback_canvas_width" => DEFAULT_TEXT_CANVAS_WIDTH,
              "fallback_rasterize_size" => DEFAULT_TEXT_RASTERIZE_SIZE
            }
            elements.last["font_family"] = font_family unless font_family.empty?
          end
        end
      end

      config = {
        "output" => output_filename(project_dir, title_text),
        "width" => options.fetch(:width, DEFAULT_WIDTH),
        "height" => options.fetch(:height, DEFAULT_HEIGHT),
        "fps" => options.fetch(:fps, DEFAULT_FPS),
        "duration" => duration,
        "background" => background,
        "audio" => relative_path(audio_file, project_dir),
        "elements" => elements
      }
      config["font_family"] = font_family unless font_family.empty?
      sound_effects = sentence_sound_effects(sentences, project_dir, options)
      config["sound_effects"] = sound_effects unless sound_effects.empty?
      config
    end

    def background_config(options)
      deep_dup(options.fetch(:background, DEFAULT_BACKGROUND))
    end

    def dark_background?(background)
      background = background.transform_keys(&:to_s)
      color = background["color"].to_s
      return dark_hex_color?(color) unless color.empty?

      path = background["path"].to_s
      basename = File.basename(path).downcase
      basename.include?("black") || basename.include?("grey") || basename.include?("gray")
    end

    def dark_hex_color?(color)
      match = color.match(/\A#?([[:xdigit:]]{6})\z/)
      return false unless match

      hex = match[1]
      red = hex[0, 2].to_i(16)
      green = hex[2, 2].to_i(16)
      blue = hex[4, 2].to_i(16)
      ((red * 0.299) + (green * 0.587) + (blue * 0.114)) < 128
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

    def waveform_element(duration, audio_file, project_dir, color: "0x111111", anchor_y: DEFAULT_ICON_Y)
      {
        "type" => "waveform",
        "audio" => relative_path(audio_file, project_dir),
        "start" => 0,
        "end" => duration,
        "width" => DEFAULT_WAVEFORM_WIDTH,
        "height" => DEFAULT_WAVEFORM_HEIGHT,
        "x" => "center",
        "position" => "bottom",
        "anchor_element_type" => "image",
        "anchor_y" => anchor_y,
        "gap" => 20,
        "color" => color,
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

    def watermark_element(duration, category_text, color: "black", font_family: nil)
      {
        "type" => "text",
        "text" => watermark_text(category_text),
        "start" => 0,
        "end" => duration,
        "font_size" => DEFAULT_WATERMARK_FONT_SIZE,
        "color" => color,
        "x" => "center",
        "y" => DEFAULT_WATERMARK_Y,
        "text_align" => "center",
        "box" => false,
        "fallback_width" => DEFAULT_WATERMARK_WIDTH,
        "fallback_canvas_width" => DEFAULT_WATERMARK_CANVAS_WIDTH,
        "fallback_rasterize_size" => DEFAULT_TEXT_RASTERIZE_SIZE
      }.tap do |element|
        element["font_family"] = font_family unless font_family.to_s.strip.empty?
      end
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

    def icon_animation_for(planned_icon, icon_index, forced: nil, first_delayed_animation: nil)
      first_delayed_animation = first_delayed_animation.to_s
      return first_delayed_animation if icon_index.zero? && ICON_ANIMATIONS.include?(first_delayed_animation)
      return "none" if icon_index.zero?

      safe_icon_animation(planned_icon, forced: forced)
    end

    def safe_icon_animation(planned_icon, forced: nil)
      forced_animation = forced.to_s
      return forced_animation if ICON_ANIMATIONS.include?(forced_animation)

      animation = planned_icon["animation"].to_s
      return animation if ICON_ANIMATIONS.include?(animation)

      ICON_ANIMATIONS[(planned_icon.fetch("sentence_index") - 1) % ICON_ANIMATIONS.length]
    end

    def sentence_sound_effects(sentences, project_dir, options)
      sound_effect = options[:pipeline_sentence_sound_effect].to_s
      first_sound_effect = options[:pipeline_first_sentence_sound_effect].to_s
      return [] if sound_effect.empty? && first_sound_effect.empty?

      volume = options.fetch(:pipeline_sound_effect_volume, 0.55).to_f
      first_delay = options.fetch(:pipeline_first_sentence_sound_effect_delay, 0).to_f
      offset = options.fetch(:pipeline_sound_effect_offset, 0).to_f
      first_offset = options.fetch(:pipeline_first_sentence_sound_effect_offset, offset).to_f
      sentences.filter_map.with_index do |sentence, index|
        file = index.zero? && !first_sound_effect.empty? ? first_sound_effect : sound_effect
        next if file.empty?

        start_time = sentence.fetch("start").to_f
        start_time += first_delay if index.zero? && !first_sound_effect.empty?
        start_time += index.zero? && !first_sound_effect.empty? ? first_offset : offset
        start_time = [start_time, 0.0].max

        {
          "file" => relative_path(file, project_dir),
          "start" => start_time.round(3),
          "volume" => volume
        }
      end
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
      [natural_end, visual_start + frame_gap].max.round(3)
    end

    def subtitle_segments(text, start_time, end_time, planned_icon, title_text)
      start_time = start_time.to_f
      end_time = end_time.to_f
      text = text.to_s
      title_text = title_text.to_s.strip
      return [{ "text" => text, "start" => start_time, "end" => end_time }] unless planned_icon.fetch("sentence_index") == 1
      return [{ "text" => text, "start" => start_time, "end" => end_time }] if title_text.empty?

      title_end = [start_time + DEFAULT_FIRST_SUBTITLE_TITLE_DURATION, end_time].min.round(3)
      segments = [{ "text" => title_text, "start" => start_time.round(3), "end" => title_end }]
      text_start = [title_end + frame_gap, end_time].min.round(3)
      segments << { "text" => text, "start" => text_start, "end" => end_time.round(3) } if end_time > text_start
      segments
    end

    def frame_gap
      0.034
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
