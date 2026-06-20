# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/script_video_pipeline"

class ScriptVideoPipelineTest < Minitest::Test
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
