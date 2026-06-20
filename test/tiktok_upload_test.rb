# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/tiktok_upload"

class TikTokUploadTest < Minitest::Test
  def test_inbox_upload_initializes_and_puts_file
    Dir.mktmpdir do |dir|
      file = File.join(dir, "video.mp4")
      File.binwrite(file, "abcdef")
      client = RecordingClient.new

      result = client.upload(file: file, access_token: "token-123")

      assert_equal "publish-123", result.publish_id
      assert_equal "inbox_upload", result.mode
      assert_equal TikTokUpload::INBOX_INIT_PATH, client.init_uri.path
      assert_equal "Bearer token-123", client.init_headers.fetch("Authorization")
      body = JSON.parse(client.init_body)
      assert_equal "FILE_UPLOAD", body.dig("source_info", "source")
      assert_equal 6, body.dig("source_info", "video_size")
      assert_equal 6, body.dig("source_info", "chunk_size")
      assert_equal 1, body.dig("source_info", "total_chunk_count")
      assert_equal ["bytes 0-5/6"], client.upload_ranges
      assert_equal ["abcdef"], client.upload_bodies
    end
  end

  def test_direct_post_adds_post_info
    Dir.mktmpdir do |dir|
      file = File.join(dir, "video.mp4")
      File.binwrite(file, "abcdef")
      client = RecordingClient.new

      client.upload(
        file: file,
        access_token: "token-123",
        direct_post: true,
        title: "Judul #tag",
        privacy_level: "SELF_ONLY",
        disable_comment: true,
        is_aigc: true
      )

      assert_equal TikTokUpload::DIRECT_POST_INIT_PATH, client.init_uri.path
      post_info = JSON.parse(client.init_body).fetch("post_info")
      assert_equal "Judul #tag", post_info.fetch("title")
      assert_equal "SELF_ONLY", post_info.fetch("privacy_level")
      assert_equal true, post_info.fetch("disable_comment")
      assert_equal true, post_info.fetch("is_aigc")
    end
  end

  def test_manifest_output_files_reads_bulk_manifest
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      output = File.join(dir, "video.mp4")
      File.binwrite(output, "fake-video")
      manifest = {
        "videos" => [
          { "project_dir" => File.join(dir, "project"), "output_file" => output }
        ]
      }
      File.write(File.join(workspace, "bulk_manifest.json"), JSON.pretty_generate(manifest))

      files = TikTokUpload::Client.new.manifest_output_files(workspace)

      assert_equal [output], files
    end
  end

  def test_requires_access_token
    error = assert_raises(ArgumentError) do
      TikTokUpload::Client.new.upload(file: __FILE__)
    end

    assert_match(/TikTok access token is required/, error.message)
  end

  class RecordingClient < TikTokUpload::Client
    attr_reader :init_uri, :init_headers, :init_body, :upload_ranges, :upload_bodies

    def initialize
      super
      @upload_ranges = []
      @upload_bodies = []
    end

    private

    def request_json(uri, headers:, body:)
      @init_uri = uri
      @init_headers = headers
      @init_body = body
      {
        "data" => {
          "publish_id" => "publish-123",
          "upload_url" => "https://open-upload.tiktokapis.com/video/?upload_id=123"
        },
        "error" => {
          "code" => "ok",
          "message" => ""
        }
      }
    end

    def request_upload_chunk(_uri, data:, first_byte:, last_byte:, size:)
      @upload_ranges << "bytes #{first_byte}-#{last_byte}/#{size}"
      @upload_bodies << data
      FakeResponse.new("201", "")
    end
  end

  FakeResponse = Struct.new(:code, :body)
end
