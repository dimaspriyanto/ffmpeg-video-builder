# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module FacebookUpload
  DEFAULT_GRAPH_VERSION = "v20.0"
  DEFAULT_GRAPH_VIDEO_BASE = "https://graph-video.facebook.com"

  Result = Struct.new(:file, :id, :response, keyword_init: true) do
    def to_h
      {
        file: file,
        id: id,
        response: response
      }
    end
  end

  def self.upload(**kwargs)
    Client.new.upload(**kwargs)
  end

  def self.upload_many(**kwargs)
    Client.new.upload_many(**kwargs)
  end

  def self.upload_manifest(**kwargs)
    Client.new.upload_manifest(**kwargs)
  end

  class Client
    def upload(file:, page_id: nil, access_token: nil, title: nil, description: nil,
               published: true, graph_version: DEFAULT_GRAPH_VERSION)
      file = validate_file!(file)
      page_id = required_value(page_id || ENV["FACEBOOK_PAGE_ID"], "Facebook page ID")
      token = required_value(access_token || ENV["FACEBOOK_ACCESS_TOKEN"], "Facebook access token")
      response = upload_video(
        file: file,
        page_id: page_id,
        access_token: token,
        title: title,
        description: description,
        published: published,
        graph_version: graph_version
      )

      Result.new(file: file, id: response["id"], response: response)
    end

    def upload_many(files:, page_id: nil, access_token: nil, **options)
      token = required_value(access_token || ENV["FACEBOOK_ACCESS_TOKEN"], "Facebook access token")
      files.map { |file| upload(file: file, page_id: page_id, access_token: token, **options) }
    end

    def upload_manifest(workspace_dir:, page_id: nil, access_token: nil, **options)
      files = manifest_output_files(workspace_dir)
      upload_many(files: files, page_id: page_id, access_token: access_token, **options)
    end

    def manifest_output_files(workspace_dir)
      workspace_dir = File.expand_path(workspace_dir.to_s)
      manifest_file = File.join(workspace_dir, "bulk_manifest.json")
      raise ArgumentError, "Bulk manifest not found: #{manifest_file}" unless File.file?(manifest_file)

      manifest = JSON.parse(File.read(manifest_file))
      manifest.fetch("videos").map do |video|
        output_file = video.fetch("output_file").to_s
        candidates = [output_file, File.join("outputs", File.basename(output_file))]
        candidates.find { |candidate| File.file?(candidate) }
      end.compact.map { |file| File.expand_path(file) }.uniq
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid bulk manifest JSON: #{manifest_file}: #{e.message}"
    end

    private

    def upload_video(file:, page_id:, access_token:, title:, description:, published:, graph_version:)
      uri = URI("#{DEFAULT_GRAPH_VIDEO_BASE}/#{graph_version}/#{page_id}/videos")
      fields = {
        access_token: access_token,
        published: published ? "true" : "false"
      }
      fields[:title] = title.to_s unless blank?(title)
      fields[:description] = description.to_s unless blank?(description)
      request_multipart(uri, fields: fields, file: file)
    end

    def request_multipart(uri, fields:, file:)
      boundary = "ruby-facebook-upload-#{SecureRandom.hex(12)}"
      body = multipart_body(boundary: boundary, fields: fields, file: file)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      parsed = parse_json_response(response)
      return parsed if response.is_a?(Net::HTTPSuccess) && parsed["error"].nil?

      message = parsed.dig("error", "message") || response.body
      raise "Facebook upload failed with status #{response.code}: #{message}"
    end

    def multipart_body(boundary:, fields:, file:)
      parts = fields.flat_map do |key, value|
        [
          "--#{boundary}\r\n",
          "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n",
          value.to_s,
          "\r\n"
        ]
      end
      parts += [
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"source\"; filename=\"#{File.basename(file)}\"\r\n",
        "Content-Type: video/mp4\r\n\r\n",
        File.binread(file),
        "\r\n--#{boundary}--\r\n"
      ]
      parts.join
    end

    def parse_json_response(response)
      JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    rescue JSON::ParserError
      { "raw" => response.body.to_s }
    end

    def validate_file!(file)
      path = File.expand_path(file.to_s)
      raise ArgumentError, "Facebook upload file not found: #{path}" unless File.file?(path)

      path
    end

    def required_value(value, label)
      normalized = value.to_s.strip
      raise ArgumentError, "#{label} is required" if normalized.empty?

      normalized
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
