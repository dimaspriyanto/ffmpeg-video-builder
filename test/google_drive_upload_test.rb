# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/google_drive_upload"

class GoogleDriveUploadTest < Minitest::Test
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

      files = GoogleDriveUpload::Client.new.manifest_output_files(workspace)

      assert_equal [output], files
    end
  end

  def test_upload_sends_multipart_metadata
    Dir.mktmpdir do |dir|
      file = File.join(dir, "sample.mp4")
      File.binwrite(file, "fake-video")
      client = RecordingClient.new

      result = client.upload(
        file: file,
        name: "custom.mp4",
        folder_id: "folder-123",
        access_token: "token-123"
      )

      assert_equal "drive-file-id", result.id
      assert_equal "Bearer token-123", client.last_headers.fetch("Authorization")
      assert_includes client.last_uri.query, "uploadType=multipart"
      assert_includes client.last_body, '"name":"custom.mp4"'
      assert_includes client.last_body, '"parents":["folder-123"]'
      assert_includes client.last_body, "Content-Type: video/mp4"
      assert_includes client.last_body, "fake-video"
    end
  end

  def test_requires_token_or_credentials
    error = assert_raises(ArgumentError) do
      GoogleDriveUpload::Client.new.upload(file: __FILE__)
    end

    assert_match(/access token or service account credentials/, error.message)
  end

  class RecordingClient < GoogleDriveUpload::Client
    attr_reader :last_uri, :last_headers, :last_body

    private

    def request_json(uri, headers:, body:)
      @last_uri = uri
      @last_headers = headers
      @last_body = body
      {
        "id" => "drive-file-id",
        "name" => "custom.mp4",
        "mimeType" => "video/mp4",
        "webViewLink" => "https://drive.google.com/file/d/drive-file-id/view"
      }
    end
  end
end
