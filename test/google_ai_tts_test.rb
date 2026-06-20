# frozen_string_literal: true

require "base64"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/google_ai_tts"

class GoogleAITTSTest < Minitest::Test
  def test_generates_wave_file_and_metadata
    Dir.mktmpdir do |dir|
      output = File.join(dir, "speech.wav")
      client = RecordingClient.new

      result = client.speak(
        text: "Halo dunia.",
        output_file: output,
        api_key: "key-123",
        model: "gemini-3.1-flash-tts-preview",
        voice: "Kore",
        style: "Say calmly"
      )

      assert_equal output, result.audio_file
      assert File.file?(output)
      assert_equal "RIFF", File.binread(output, 4)
      assert File.file?(result.metadata_file)
      metadata = JSON.parse(File.read(result.metadata_file))
      assert_equal "Kore", metadata.fetch("voice")
      assert_equal "gemini-3.1-flash-tts-preview", metadata.fetch("model")
      body = JSON.parse(client.last_body)
      assert_equal "Say calmly:\nHalo dunia.", body.dig("contents", 0, "parts", 0, "text")
      assert_equal ["AUDIO"], body.dig("generationConfig", "responseModalities")
      assert_equal "Kore", body.dig("generationConfig", "speechConfig", "voiceConfig", "prebuiltVoiceConfig", "voiceName")
      assert_equal "key=key-123", client.last_uri.query
    end
  end

  def test_uses_project_download_dir_when_output_file_is_not_given
    Dir.mktmpdir do |dir|
      text_file = File.join(dir, "script.txt")
      File.write(text_file, "Halo dari project.")
      client = RecordingClient.new

      result = client.speak(
        text_file: text_file,
        download_dir: dir,
        api_key: "key-123",
        voice: "Zephyr"
      )

      assert_equal File.join(dir, "audio_voiceover.wav"), result.audio_file
      assert_equal dir, result.download_dir
      assert File.file?(result.audio_file)
      assert_equal "audio_voiceover.google_ai_tts.json", File.basename(result.metadata_file)
    end
  end

  def test_requires_input_text
    error = assert_raises(ArgumentError) do
      GoogleAITTS::Client.new.speak(output_file: "out.wav", api_key: "key-123")
    end

    assert_match(/text or text_file is required/, error.message)
  end

  class RecordingClient < GoogleAITTS::Client
    attr_reader :last_uri, :last_body

    private

    def request_json(uri, body:)
      @last_uri = uri
      @last_body = body
      {
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {
                  "inlineData" => {
                    "data" => Base64.strict_encode64("fake-pcm")
                  }
                }
              ]
            }
          }
        ]
      }
    end
  end
end
