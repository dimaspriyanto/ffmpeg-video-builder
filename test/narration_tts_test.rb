# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/narration_tts"

class NarrationTTSTest < Minitest::Test
  def test_supported_engines_are_only_kokoro_and_google_ai
    assert_equal %w[kokoro google_ai], NarrationTTS::ENGINES
    assert_equal "kokoro", NarrationTTS.engine
    assert_equal "google_ai", NarrationTTS.engine(tts_engine: "GOOGLE_AI")
  end

  def test_rejects_unsupported_tts_engine
    error = assert_raises(ArgumentError) { NarrationTTS.engine(tts_engine: "unsupported") }
    assert_match(/Unsupported TTS engine/, error.message)
  end
end
