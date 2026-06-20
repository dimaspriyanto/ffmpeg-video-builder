# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/openai_whisper"

class OpenAIWhisperTest < Minitest::Test
  def test_splits_sentences_at_a_clear_pause_without_terminal_punctuation
    response = {
      "segments" => [
        {
          "start" => 0.0,
          "end" => 1.0,
          "words" => [
            { "word" => " Kalimat", "start" => 0.0, "end" => 0.5 },
            { "word" => " pertama,", "start" => 0.5, "end" => 1.0 }
          ]
        },
        {
          "start" => 1.4,
          "end" => 2.5,
          "words" => [
            { "word" => " kalimat", "start" => 1.4, "end" => 1.9 },
            { "word" => " kedua.", "start" => 1.9, "end" => 2.5 }
          ]
        }
      ]
    }

    sentences = OpenAIWhisper::Client.new.send(:sentence_timings, response)

    assert_equal 2, sentences.length
    assert_equal "Kalimat pertama,", sentences[0].fetch("text")
    assert_equal "kalimat kedua.", sentences[1].fetch("text")
  end

  def test_keeps_segments_together_when_pause_is_short
    response = {
      "segments" => [
        {
          "start" => 0.0,
          "end" => 1.0,
          "words" => [
            { "word" => " Satu,", "start" => 0.0, "end" => 1.0 }
          ]
        },
        {
          "start" => 1.1,
          "end" => 2.0,
          "words" => [
            { "word" => " dua.", "start" => 1.1, "end" => 2.0 }
          ]
        }
      ]
    }

    sentences = OpenAIWhisper::Client.new.send(:sentence_timings, response)

    assert_equal 1, sentences.length
    assert_equal "Satu, dua.", sentences[0].fetch("text")
  end
end
