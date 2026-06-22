# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../lib/script_video_pipeline"

class ScriptVideoPipelineTest < Minitest::Test
  def test_merges_the_first_two_audio_timings_for_a_quoted_opening_sentence
    timings = [
      { "index" => 1, "start" => 0.0, "end" => 2.6, "text" => "Memayu hayuning bawono." },
      { "index" => 2, "start" => 3.4, "end" => 9.3, "text" => "Berarti manusia hidup untuk menjaga dunia." },
      { "index" => 3, "start" => 10.4, "end" => 16.3, "text" => "Kalimat kedua." },
      { "index" => 4, "start" => 16.3, "end" => 20.0, "text" => "Kalimat ketiga." }
    ]

    synchronized = ScriptVideoPipeline::Client.new.send(
      :synchronize_sentence_texts,
      timings,
      "“Memayu hayuning bawono” berarti manusia hidup untuk menjaga dunia.\nKalimat kedua.\nKalimat ketiga.\n"
    )

    assert_equal 3, synchronized.length
    assert_equal [0.0, 10.4, 16.3], synchronized.map { |sentence| sentence.fetch("start") }
    assert_equal [9.3, 16.3, 20.0], synchronized.map { |sentence| sentence.fetch("end") }
    assert_equal "“Memayu hayuning bawono” berarti manusia hidup untuk menjaga dunia.", synchronized[0].fetch("text")
  end

  def test_opening_silence_shifts_the_first_voice_group
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pertama." },
      { "index" => 2, "start" => 1.2, "end" => 2.0, "text" => "Kedua." }
    ]

    Dir.mktmpdir do |dir|
      input = File.join(dir, "audio_voiceover.wav")
      output = File.join(dir, "audio_voiceover_paused.wav")
      assert system("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono", "-t", "2.2", input)

      shifted, audio_file = client.send(
        :apply_sentence_pause,
        sentences,
        input,
        dir,
        { pipeline_opening_silence: 1.0, pipeline_sentence_pause: 1.5, pipeline_sentence_trim_padding: 0.0 }
      )

      assert_equal output, audio_file
      assert_equal 1.0, shifted[0].fetch("start")
      assert_equal 3.5, shifted[1].fetch("start")
      assert File.size?(output)
    end
  end

  def test_grouped_timeline_keeps_later_icons_static_and_aligns_group_boundaries
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 2.138, "end" => 3.138, "text" => "Kalimat pertama." },
      { "index" => 2, "start" => 4.638, "end" => 5.638, "text" => "Kalimat kedua." },
      { "index" => 3, "start" => 7.138, "end" => 8.138, "text" => "Kalimat ketiga." }
    ]
    icon_plan = sentences.map do |sentence|
      {
        "sentence_index" => sentence.fetch("index"),
        "sentence" => sentence.fetch("text"),
        "start" => sentence.fetch("start"),
        "end" => sentence.fetch("end"),
        "icon_file" => "/tmp/icon-#{sentence.fetch('index')}.png",
        "animation" => "zoom_out"
      }
    end
    options = {
      background: { "type" => "color", "color" => "#000000" },
      pipeline_icon_animation: "none",
      pipeline_first_icon_delayed_animation: "zoom_out",
      pipeline_first_icon_animation_delay: 1.0,
      pipeline_group_icon_animation: "none",
      pipeline_group_icon_animation_duration: 0.34,
      pipeline_sentence_sound_effect: "/tmp/mouse-click.mp3",
      pipeline_first_sentence_sound_effect: "/tmp/bubble-pop.wav",
      pipeline_sentence_sound_effect_lead: 0.528,
      pipeline_first_sentence_sound_effect_lead: 1.138,
      pipeline_sound_effect_offset: -0.076,
      pipeline_first_sentence_sound_effect_offset: -0.049
    }

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      options,
      title_text: "Judul Video",
      category_text: "Kategori"
    )
    icons = config.fetch("elements").select { |element| element["type"] == "image" }
    subtitles = config.fetch("elements").select { |element| element["type"] == "text" && element.key?("paragraph_index") }
    waveforms = config.fetch("elements").select { |element| element["type"] == "waveform" }
    effects = config.fetch("sound_effects")

    assert_equal ["none", "zoom_out", "none", "none", "none"],
                 icons.map { |icon| icon.fetch("animation") }
    assert_equal 4.11, icons[2].fetch("end")
    assert_equal [4.11, 6.61], icons[3, 2].map { |icon| icon.fetch("start") }
    assert_equal ["Judul Video", "Kalimat pertama.", "Kalimat kedua.", "Kalimat ketiga."],
                 subtitles.map { |subtitle| subtitle.fetch("text") }
    assert_equal [0.0, 2.138, 4.638, 7.138], subtitles.map { |subtitle| subtitle.fetch("start") }
    assert_equal 1, waveforms.length
    assert_equal [{ "start" => 2.138, "end" => 3.138 }, { "start" => 4.638, "end" => 5.638 }, { "start" => 7.138, "end" => 8.138 }],
                 waveforms.first.fetch("intervals")
    assert_equal [1.0, 4.11, 6.61], effects.map { |effect| effect.fetch("start") }
  end

  def test_uses_script_text_with_whisper_timings
    timings = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Salah satu." },
      { "index" => 2, "start" => 1.5, "end" => 2.5, "text" => "Salah dua." }
    ]

    synchronized = ScriptVideoPipeline::Client.new.send(
      :synchronize_sentence_texts,
      timings,
      "Kalimat pertama.\nKalimat kedua.\n"
    )

    assert_equal ["Kalimat pertama.", "Kalimat kedua."], synchronized.map { |sentence| sentence.fetch("text") }
    assert_equal [0.0, 1.5], synchronized.map { |sentence| sentence.fetch("start") }
    assert_equal [1.0, 2.5], synchronized.map { |sentence| sentence.fetch("end") }
  end

  def test_rejects_mismatched_sentence_counts
    timings = [{ "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Salah." }]

    error = assert_raises(ArgumentError) do
      ScriptVideoPipeline::Client.new.send(
        :synchronize_sentence_texts,
        timings,
        "Kalimat pertama.\nKalimat kedua.\n"
      )
    end

    assert_match(/Script has 2 sentences, but Whisper produced 1 timings/, error.message)
  end

  def test_splits_multiple_sentences_on_the_same_script_line
    sentences = ScriptVideoPipeline::Client.new.send(
      :source_sentence_texts,
      "Kalimat pertama. Kalimat kedua.\nKalimat ketiga.\n"
    )

    assert_equal ["Kalimat pertama.", "Kalimat kedua.", "Kalimat ketiga."], sentences
  end

  def test_keeps_leading_quote_with_sentence_tail
    sentences = ScriptVideoPipeline::Client.new.send(
      :source_sentence_texts,
      "“Memayu hayuning bawono” berarti manusia hidup untuk menjaga dunia."
    )

    assert_equal ["“Memayu hayuning bawono” berarti manusia hidup untuk menjaga dunia."], sentences
  end

  def test_content_parser_ignores_bulk_delimiters_and_following_blocks
    script = <<~SCRIPT
      Title: Judul Pertama
      Category: Kategori

      Content:
      Kalimat pertama.
      Kalimat kedua.

      ---

      2

      ---

      Title: Judul Kedua
      Category: Kategori

      Content:
      Tidak boleh masuk.
    SCRIPT

    parsed = ScriptVideoPipeline::Client.new.send(:parse_script_text, script, "inline")

    assert_equal "Judul Pertama", parsed.title
    assert_equal "Kategori", parsed.category
    assert_equal "Kalimat pertama.\nKalimat kedua.\n", parsed.body
  end

  def test_uses_sequential_icon_set_for_each_bulk_video
    sentences = (1..3).map { |index| { "index" => index } }
    icon_config = {
      "icon_sets" => [
        %w[icons/1/1.png icons/1/2.png icons/1/3.png],
        %w[icons/2/1.png icons/2/2.png icons/2/3.png]
      ]
    }

    expanded = ScriptVideoPipeline::Client.new.send(
      :expand_local_icon_pool,
      icon_config,
      sentences,
      { bulk_video_index: 2 }
    )

    assert_equal %w[icons/2/1.png icons/2/2.png icons/2/3.png],
                 expanded.fetch("icons").map { |icon| icon.fetch("file") }
  end

  def test_can_skip_second_icon_when_first_icon_has_delayed_animation
    sentences = (1..4).map { |index| { "index" => index } }
    icon_config = {
      "icon_sets" => [
        %w[icons/1/1.png icons/1/2.png icons/1/3.png icons/1/4.png]
      ]
    }

    expanded = ScriptVideoPipeline::Client.new.send(
      :expand_local_icon_pool,
      icon_config,
      sentences,
      {
        bulk_video_index: 1,
        pipeline_first_icon_delayed_animation: "blink",
        pipeline_first_icon_animation_delay: 1.0,
        pipeline_skip_second_icon_after_first_animation: true
      }
    )

    assert_equal %w[icons/1/1.png icons/1/3.png icons/1/4.png icons/1/4.png],
                 expanded.fetch("icons").map { |icon| icon.fetch("file") }
  end

  def test_delayed_first_icon_keeps_sequential_icons_by_default
    sentences = (1..4).map { |index| { "index" => index } }
    icon_config = {
      "icon_sets" => [
        %w[icons/1/1.png icons/1/2.png icons/1/3.png icons/1/4.png]
      ]
    }

    expanded = ScriptVideoPipeline::Client.new.send(
      :expand_local_icon_pool,
      icon_config,
      sentences,
      {
        bulk_video_index: 1,
        pipeline_first_icon_delayed_animation: "blink",
        pipeline_first_icon_animation_delay: 1.0
      }
    )

    assert_equal %w[icons/1/1.png icons/1/2.png icons/1/3.png icons/1/4.png],
                 expanded.fetch("icons").map { |icon| icon.fetch("file") }
  end

  def test_workspace_named_roots_are_derived_from_workspace_folder
    client = ScriptVideoPipeline::Client.new

    assert_equal "projects/UncoverJogja", client.send(:workspace_project_root, "workspace/UncoverJogja")
    assert_equal "outputs/UncoverJogja", client.send(:workspace_outputs_dir, "workspace/UncoverJogja")
  end

  def test_first_icon_is_visible_from_the_first_frame_without_transition
    client = ScriptVideoPipeline::Client.new
    sentences = [{ "index" => 1, "start" => 0.2, "end" => 1.0, "text" => "Pembuka." }]
    icon_plan = [{
      "sentence_index" => 1,
      "sentence" => "Pembuka.",
      "start" => 0.2,
      "end" => 1.0,
      "icon_file" => "/tmp/icon.png"
    }]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      { background: { "type" => "color", "color" => "#000000" } },
      title_text: "Judul",
      category_text: "Kategori"
    )
    first_icon = config.fetch("elements").find { |element| element["type"] == "image" }

    assert_equal 0.0, first_icon.fetch("start")
    assert_equal "none", first_icon.fetch("animation")
  end

  def test_waveform_position_can_be_decoupled_from_icon_position
    client = ScriptVideoPipeline::Client.new
    sentences = [{ "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pembuka." }]
    icon_plan = [{
      "sentence_index" => 1,
      "sentence" => "Pembuka.",
      "start" => 0.0,
      "end" => 1.0,
      "icon_file" => "/tmp/icon.png"
    }]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      {
        background: { "type" => "color", "color" => "#000000" },
        pipeline_icon_y: 470,
        pipeline_waveform_y: 520,
        pipeline_icon_width: 420,
        pipeline_waveform_width: 420,
        pipeline_waveform_height: 64,
        pipeline_waveform_gap: 10
      },
      title_text: "Judul",
      category_text: "Kategori"
    )
    waveform = config.fetch("elements").find { |element| element["type"] == "waveform" }
    first_icon = config.fetch("elements").find { |element| element["type"] == "image" }

    assert_equal 470, first_icon.fetch("y")
    assert_equal 420, first_icon.fetch("width")
    assert_equal 520, waveform.fetch("anchor_y")
    assert_equal 420, waveform.fetch("width")
    assert_equal 64, waveform.fetch("height")
    assert_equal 20.0, waveform.fetch("gap")
  end

  def test_first_icon_can_render_static_then_blink_after_delay
    client = ScriptVideoPipeline::Client.new
    sentences = [{ "index" => 1, "start" => 0.0, "end" => 2.0, "text" => "Pembuka." }]
    icon_plan = [{
      "sentence_index" => 1,
      "sentence" => "Pembuka.",
      "start" => 0.0,
      "end" => 2.0,
      "icon_file" => "/tmp/icon.png"
    }]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      {
        background: { "type" => "color", "color" => "#000000" },
        pipeline_first_icon_delayed_animation: "blink",
        pipeline_first_icon_animation_delay: 1.0
      },
      title_text: "Judul",
      category_text: "Kategori"
    )
    icons = config.fetch("elements").select { |element| element["type"] == "image" }

    assert_equal 3, icons.length
    assert_equal ["/tmp/icon.png", "/tmp/icon.png", "/tmp/icon.png"], icons.map { |icon| File.expand_path(icon.fetch("file"), "/tmp") }
    assert_equal [0.0, 1.0, 1.34], icons.map { |icon| icon.fetch("start") }
    assert_equal [1.0, 1.34, 2.35], icons.map { |icon| icon.fetch("end") }
    assert_equal ["none", "blink", "none"], icons.map { |icon| icon.fetch("animation") }
    assert_equal [0, 0, 0], icons.map { |icon| icon.fetch("animation_delay") }
  end

  def test_first_icon_can_render_static_then_zoom_out_then_static_after_delay
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 2.0, "text" => "Pembuka." },
      { "index" => 2, "start" => 4.0, "end" => 5.0, "text" => "Lanjut." }
    ]
    icon_plan = sentences.map do |sentence|
      {
        "sentence_index" => sentence.fetch("index"),
        "sentence" => sentence.fetch("text"),
        "start" => sentence.fetch("start"),
        "end" => sentence.fetch("end"),
        "icon_file" => "/tmp/icon-#{sentence.fetch('index')}.png"
      }
    end

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      {
        background: { "type" => "color", "color" => "#000000" },
        pipeline_first_icon_delayed_animation: "zoom_out",
        pipeline_first_icon_animation_delay: 1.0,
        pipeline_icon_animation: "zoom_out"
      },
      title_text: "Judul",
      category_text: "Kategori"
    )
    icons = config.fetch("elements").select { |element| element["type"] == "image" }

    assert_equal ["/tmp/icon-1.png", "/tmp/icon-1.png", "/tmp/icon-1.png", "/tmp/icon-2.png"],
                 icons.map { |icon| File.expand_path(icon.fetch("file"), "/tmp") }
    assert_equal [0.0, 1.0, 1.45, 4.0], icons.map { |icon| icon.fetch("start") }
    assert_equal [1.0, 1.45, 4.0, 5.35], icons.map { |icon| icon.fetch("end") }
    assert_equal ["none", "zoom_out", "none", "zoom_out"], icons.map { |icon| icon.fetch("animation") }
  end

  def test_first_subtitle_shows_title_for_one_second_then_sentence_text
    client = ScriptVideoPipeline::Client.new
    sentences = [{ "index" => 1, "start" => 0.0, "end" => 3.0, "text" => "Kalimat pertama." }]
    icon_plan = [{
      "sentence_index" => 1,
      "sentence" => "Kalimat pertama.",
      "start" => 0.0,
      "end" => 3.0,
      "icon_file" => "/tmp/icon.png"
    }]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      { background: { "type" => "color", "color" => "#000000" } },
      title_text: "Judul Video",
      category_text: "Kategori"
    )
    subtitles = config.fetch("elements").select { |element| element["type"] == "text" && element.key?("paragraph_index") }

    assert_equal ["Judul Video", "Kalimat pertama."], subtitles.map { |element| element.fetch("text") }
    assert_equal [0.0, 1.034], subtitles.map { |element| element.fetch("start") }
    assert_equal [1.0, 3.0], subtitles.map { |element| element.fetch("end") }
  end

  def test_subtitle_ends_at_sentence_audio_end
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 2.0, "text" => "Kalimat pertama cukup panjang." },
      { "index" => 2, "start" => 4.0, "end" => 5.0, "text" => "Kalimat kedua." }
    ]
    icon_plan = sentences.map do |sentence|
      {
        "sentence_index" => sentence.fetch("index"),
        "sentence" => sentence.fetch("text"),
        "start" => sentence.fetch("start"),
        "end" => sentence.fetch("end"),
        "icon_file" => "/tmp/icon-#{sentence.fetch('index')}.png"
      }
    end

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      { background: { "type" => "color", "color" => "#000000" } },
      title_text: "Judul",
      category_text: "Kategori"
    )
    subtitles = config.fetch("elements").select { |element| element["type"] == "text" && element.key?("paragraph_index") }

    assert_equal "Kalimat pertama\ncukup panjang.", subtitles[1].fetch("text")
    assert_equal 1.034, subtitles[1].fetch("start")
    assert_equal 2.0, subtitles[1].fetch("end")
    assert_equal 4.0, subtitles[2].fetch("start")
  end

  def test_pipeline_font_family_is_applied_to_text_elements
    client = ScriptVideoPipeline::Client.new
    sentences = [{ "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Kalimat pertama." }]
    icon_plan = [{
      "sentence_index" => 1,
      "sentence" => "Kalimat pertama.",
      "start" => 0.0,
      "end" => 1.0,
      "icon_file" => "/tmp/icon.png"
    }]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      {
        background: { "type" => "color", "color" => "#000000" },
        pipeline_font_family: "Noto Sans CJK JP"
      },
      title_text: "Judul Video",
      category_text: "Kategori"
    )
    text_elements = config.fetch("elements").select { |element| element["type"] == "text" }

    assert_equal "Noto Sans CJK JP", config.fetch("font_family")
    assert text_elements.all? { |element| element.fetch("font_family") == "Noto Sans CJK JP" }
  end

  def test_icon_plan_animation_is_used_after_first_icon
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pembuka." },
      { "index" => 2, "start" => 1.1, "end" => 2.0, "text" => "Isi." }
    ]
    icon_plan = [
      {
        "sentence_index" => 1,
        "sentence" => "Pembuka.",
        "start" => 0.0,
        "end" => 1.0,
        "icon_file" => "/tmp/icon-1.png",
        "animation" => "fade"
      },
      {
        "sentence_index" => 2,
        "sentence" => "Isi.",
        "start" => 1.1,
        "end" => 2.0,
        "icon_file" => "/tmp/icon-2.png",
        "animation" => "pop"
      }
    ]

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      { background: { "type" => "color", "color" => "#000000" } },
      title_text: "Judul",
      category_text: "Kategori"
    )
    icons = config.fetch("elements").select { |element| element["type"] == "image" }

    assert_equal "none", icons[0].fetch("animation")
    assert_equal "pop", icons[1].fetch("animation")
  end

  def test_sound_effects_are_not_added_for_icon_transitions
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pembuka." },
      { "index" => 2, "start" => 3.3, "end" => 4.0, "text" => "Isi." },
      { "index" => 3, "start" => 4.4, "end" => 5.0, "text" => "Penutup." }
    ]
    icon_plan = sentences.map do |sentence|
      {
        "sentence_index" => sentence.fetch("index"),
        "sentence" => sentence.fetch("text"),
        "start" => sentence.fetch("start"),
        "end" => sentence.fetch("end"),
        "icon_file" => "/tmp/icon-#{sentence.fetch('index')}.png",
        "animation" => "pop"
      }
    end

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      { background: { "type" => "color", "color" => "#000000" } },
      title_text: "Judul",
      category_text: "Kategori"
    )

    refute config.key?("sound_effects")
  end

  def test_first_sentence_sound_effect_can_be_replaced_and_delayed
    client = ScriptVideoPipeline::Client.new
    sentences = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pembuka." },
      { "index" => 2, "start" => 3.3, "end" => 4.0, "text" => "Isi." }
    ]
    icon_plan = sentences.map do |sentence|
      {
        "sentence_index" => sentence.fetch("index"),
        "sentence" => sentence.fetch("text"),
        "start" => sentence.fetch("start"),
        "end" => sentence.fetch("end"),
        "icon_file" => "/tmp/icon-#{sentence.fetch('index')}.png"
      }
    end

    config = client.send(
      :build_ffmpeg_config,
      sentences,
      icon_plan,
      "/tmp/audio.wav",
      "/tmp",
      {
        background: { "type" => "color", "color" => "#000000" },
        pipeline_sentence_sound_effect: "/tmp/mouse-click.mp3",
        pipeline_first_sentence_sound_effect: "/tmp/bubble-pop.wav",
        pipeline_first_sentence_sound_effect_delay: 1.0,
        pipeline_sound_effect_offset: -0.08,
        pipeline_first_sentence_sound_effect_offset: -0.05
      },
      title_text: "Judul",
      category_text: "Kategori"
    )
    sound_effects = config.fetch("sound_effects")

    assert_equal "bubble-pop.wav", File.basename(sound_effects[0].fetch("file"))
    assert_equal 0.95, sound_effects[0].fetch("start")
    assert_equal "mouse-click.mp3", File.basename(sound_effects[1].fetch("file"))
    assert_equal 3.22, sound_effects[1].fetch("start")
  end

  def test_merges_extra_whisper_timing_at_the_shortest_pause
    timings = [
      { "index" => 1, "start" => 0.0, "end" => 1.0, "text" => "Pertama." },
      { "index" => 2, "start" => 2.0, "end" => 3.0, "text" => "Bagian satu," },
      { "index" => 3, "start" => 3.2, "end" => 4.0, "text" => "bagian dua." }
    ]

    synchronized = ScriptVideoPipeline::Client.new.send(
      :synchronize_sentence_texts,
      timings,
      "Kalimat pertama.\nKalimat kedua tetap utuh.\n"
    )

    assert_equal 2, synchronized.length
    assert_equal 2.0, synchronized[1].fetch("start")
    assert_equal 4.0, synchronized[1].fetch("end")
    assert_equal "Kalimat kedua tetap utuh.", synchronized[1].fetch("text")
  end
end
