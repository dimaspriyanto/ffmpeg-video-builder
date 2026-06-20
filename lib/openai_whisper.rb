# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "project_directory"

module OpenAIWhisper
  DEFAULT_COMMAND = "whisper"
  DEFAULT_MODEL = "turbo"
  DEFAULT_OUTPUT_FORMAT = "json"
  DEFAULT_TASK = "transcribe"
  DEFAULT_WORD_TIMESTAMPS = true
  SENTENCE_PAUSE_THRESHOLD = 0.3
  SUPPORTED_EXTENSIONS = %w[flac mp3 mp4 mpeg mpga m4a ogg wav webm].freeze

  Result = Struct.new(:download_dir, :output_files, :sentence_files, :response, :sentences, :stdout, :stderr, keyword_init: true) do
    def to_h
      {
        download_dir: download_dir,
        output_files: output_files,
        sentence_files: sentence_files,
        response: response,
        sentences: sentences,
        stdout: stdout,
        stderr: stderr
      }
    end
  end

  def self.transcribe(file:, model: DEFAULT_MODEL, output_format: DEFAULT_OUTPUT_FORMAT, task: DEFAULT_TASK, word_timestamps: DEFAULT_WORD_TIMESTAMPS, language: nil, prompt: nil, downloads_root: ProjectDirectory::DEFAULT_ROOT, download_dir: nil, command: ENV.fetch("WHISPER_COMMAND", DEFAULT_COMMAND))
    Client.new.transcribe(
      file: file,
      model: model,
      output_format: output_format,
      task: task,
      word_timestamps: word_timestamps,
      language: language,
      prompt: prompt,
      downloads_root: downloads_root,
      download_dir: download_dir,
      command: command
    )
  end

  class Client
    def transcribe(file:, model: DEFAULT_MODEL, output_format: DEFAULT_OUTPUT_FORMAT, task: DEFAULT_TASK, word_timestamps: DEFAULT_WORD_TIMESTAMPS, language: nil, prompt: nil, downloads_root: ProjectDirectory::DEFAULT_ROOT, download_dir: nil, command: DEFAULT_COMMAND)
      file = validate_audio_file!(file)
      command = command.to_s.strip
      command = DEFAULT_COMMAND if command.empty?
      validate_command!(command)
      download_dir = download_dir ? ensure_download_dir(download_dir) : create_download_dir(downloads_root)

      before_files = Dir[File.join(download_dir, "*")]
      stdout, stderr = run_whisper(
        command: command,
        file: file,
        model: model,
        output_format: output_format,
        task: task,
        word_timestamps: word_timestamps,
        language: language,
        prompt: prompt,
        download_dir: download_dir
      )

      normalize_whisper_outputs(download_dir, before_files)
      output_files = Dir[File.join(download_dir, "*")].sort
      response = parse_json_output(output_files)
      sentences = response ? sentence_timings(response) : []
      sentence_files = write_sentence_files(download_dir, sentences) unless sentences.empty?
      output_files = Dir[File.join(download_dir, "*")].sort

      Result.new(
        download_dir: download_dir,
        output_files: output_files,
        sentence_files: sentence_files || {},
        response: response,
        sentences: sentences,
        stdout: stdout,
        stderr: stderr
      )
    end

    private

    def validate_audio_file!(file)
      path = File.expand_path(file.to_s)
      raise ArgumentError, "Audio file not found: #{path}" unless File.file?(path)

      extension = File.extname(path).delete_prefix(".").downcase
      return path if SUPPORTED_EXTENSIONS.include?(extension)

      allowed = SUPPORTED_EXTENSIONS.join(", ")
      raise ArgumentError, "Unsupported audio file type: .#{extension}. Supported types: #{allowed}"
    end

    def validate_command!(command)
      return if command.include?(File::SEPARATOR) && File.executable?(command)
      return if ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, command))
      end

      raise "Whisper command not found: #{command.inspect}. Set WHISPER_COMMAND=/full/path/to/whisper or add whisper to PATH."
    end

    def run_whisper(command:, file:, model:, output_format:, task:, word_timestamps:, language:, prompt:, download_dir:)
      args = [
        command,
        file,
        "--model", model.to_s,
        "--output_dir", download_dir,
        "--output_format", output_format.to_s,
        "--task", task.to_s
      ]
      args += ["--word_timestamps", word_timestamps ? "True" : "False"]
      args += ["--language", language.to_s] unless blank?(language)
      args += ["--initial_prompt", prompt.to_s] unless blank?(prompt)

      stdout, stderr, status = Open3.capture3(*args)
      unless status.success?
        raise "Whisper failed with status #{status.exitstatus}: #{stderr.empty? ? stdout : stderr}"
      end

      [stdout, stderr]
    end

    def create_download_dir(downloads_root)
      ProjectDirectory.create(root: downloads_root)
    end

    def ensure_download_dir(download_dir)
      ProjectDirectory.ensure(download_dir)
    end

    def parse_json_output(output_files)
      json_file = output_files.find { |file| File.basename(file) == "subtitle_whisper.json" }
      json_file ||= output_files.find { |file| File.extname(file) == ".json" && File.basename(file).start_with?("subtitle_") }
      json_file ||= output_files.find { |file| File.extname(file) == ".json" }
      return nil unless json_file

      JSON.parse(File.read(json_file))
    rescue JSON::ParserError => e
      raise "Whisper wrote invalid JSON: #{e.message}"
    end

    def normalize_whisper_outputs(download_dir, before_files)
      before = before_files.map { |file| File.expand_path(file) }
      created = Dir[File.join(download_dir, "*")].reject do |file|
        before.include?(File.expand_path(file))
      end

      created.each do |file|
        extension = File.extname(file)
        next if extension.empty?

        target = File.join(download_dir, "subtitle_whisper#{extension}")
        next if File.expand_path(file) == File.expand_path(target)

        FileUtils.mv(file, target)
      end
    end

    def sentence_timings(response)
      word_sentences = sentence_timings_from_words(response)
      return word_sentences unless word_sentences.empty?

      sentence_timings_from_segments(response)
    end

    def sentence_timings_from_words(response)
      segments = response.fetch("segments", [])
      sentences = []
      current_words = []

      segments.each_with_index do |segment, segment_index|
        segment.fetch("words", []).each do |word|
          text = word.fetch("word", "").to_s.strip
          next if text.empty?

          current_words << word
          next unless sentence_end?(text)

          sentences << sentence_from_words(current_words)
          current_words = []
        end

        next if current_words.empty?

        next_segment = segments[segment_index + 1]
        next unless next_segment

        pause = next_segment.fetch("start").to_f - current_words.last.fetch("end").to_f
        next if pause < SENTENCE_PAUSE_THRESHOLD

        sentences << sentence_from_words(current_words)
        current_words = []
      end

      sentences << sentence_from_words(current_words) unless current_words.empty?
      compact_sentence_timings(sentences)
    end

    def sentence_from_words(words)
      {
        "start" => words.first.fetch("start"),
        "end" => words.last.fetch("end"),
        "text" => words.map { |word| word.fetch("word", "").to_s }.join.strip
      }
    end

    def sentence_timings_from_segments(response)
      response.fetch("segments", []).flat_map do |segment|
        split_segment_into_sentences(segment)
      end.then { |sentences| compact_sentence_timings(sentences) }
    end

    def split_segment_into_sentences(segment)
      text = segment.fetch("text", "").to_s.strip
      return [] if text.empty?

      pieces = text.scan(/[^.!?]+[.!?]?/).map(&:strip).reject(&:empty?)
      return [segment_sentence(segment, text, segment.fetch("start"), segment.fetch("end"))] if pieces.length <= 1

      total_chars = pieces.sum(&:length).to_f
      segment_start = segment.fetch("start").to_f
      segment_end = segment.fetch("end").to_f
      duration = segment_end - segment_start
      cursor = segment_start

      pieces.map do |piece|
        piece_duration = duration * (piece.length / total_chars)
        start_time = cursor
        cursor += piece_duration
        segment_sentence(segment, piece, start_time, cursor)
      end
    end

    def segment_sentence(segment, text, start_time, end_time)
      {
        "start" => start_time,
        "end" => end_time,
        "text" => text,
        "source_segment_id" => segment["id"]
      }
    end

    def compact_sentence_timings(sentences)
      sentences.each_with_index.map do |sentence, index|
        {
          "index" => index + 1,
          "start" => round_time(sentence.fetch("start")),
          "end" => round_time(sentence.fetch("end")),
          "text" => sentence.fetch("text").to_s.strip
        }.merge(sentence.key?("source_segment_id") ? { "source_segment_id" => sentence["source_segment_id"] } : {})
      end
    end

    def write_sentence_files(download_dir, sentences)
      json_file = File.join(download_dir, "subtitle_sentences.json")
      srt_file = File.join(download_dir, "subtitle_sentences.srt")

      File.write(json_file, "#{JSON.pretty_generate(sentences)}\n")
      File.write(srt_file, sentences_to_srt(sentences))

      {
        json: json_file,
        srt: srt_file
      }
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
      format("%<hours>02d:%<minutes>02d:%<seconds>02d,%<millis>03d", hours: hours, minutes: minutes, seconds: secs, millis: millis)
    end

    def round_time(value)
      value.to_f.round(3)
    end

    def sentence_end?(text)
      text.end_with?(".", "!", "?")
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
