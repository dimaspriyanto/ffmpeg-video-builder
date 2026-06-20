# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/facebook_upload"

class FacebookUploadTest < Minitest::Test
  def test_upload_sends_page_video_multipart
    Dir.mktmpdir do |dir|
      file = File.join(dir, "video.mp4")
      File.binwrite(file, "fake-video")
      client = RecordingClient.new

      result = client.upload(
        file: file,
        page_id: "page-123",
        access_token: "token-123",
        title: "Judul",
        description: "Deskripsi",
        published: false
      )

      assert_equal "video-id", result.id
      assert_equal "/v20.0/page-123/videos", client.last_uri.path
      assert_includes client.last_body, 'name="access_token"'
      assert_includes client.last_body, "token-123"
      assert_includes client.last_body, 'name="published"'
      assert_includes client.last_body, "false"
      assert_includes client.last_body, 'name="source"; filename="video.mp4"'
      assert_includes client.last_body, "fake-video"
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

      files = FacebookUpload::Client.new.manifest_output_files(workspace)

      assert_equal [output], files
    end
  end

  def test_requires_page_id_and_access_token
    error = assert_raises(ArgumentError) do
      FacebookUpload::Client.new.upload(file: __FILE__)
    end

    assert_match(/Facebook page ID is required/, error.message)
  end

  class RecordingClient < FacebookUpload::Client
    attr_reader :last_uri, :last_body

    private

    def request_multipart(uri, fields:, file:)
      @last_uri = uri
      @last_body = multipart_body(boundary: "test-boundary", fields: fields, file: file)
      { "id" => "video-id" }
    end
  end
end
