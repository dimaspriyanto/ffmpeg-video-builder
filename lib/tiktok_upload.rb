# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TikTokUpload
  API_BASE = "https://open.tiktokapis.com"
  INBOX_INIT_PATH = "/v2/post/publish/inbox/video/init/"
  DIRECT_POST_INIT_PATH = "/v2/post/publish/video/init/"
  DEFAULT_PRIVACY_LEVEL = "SELF_ONLY"
  DEFAULT_CHUNK_SIZE = 10 * 1024 * 1024
  WHOLE_UPLOAD_LIMIT = 64 * 1024 * 1024

  Result = Struct.new(:file, :publish_id, :upload_url, :mode, :response, keyword_init: true) do
    def to_h
      {
        file: file,
        publish_id: publish_id,
        upload_url: upload_url,
        mode: mode,
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
    def upload(file:, access_token: nil, title: nil, privacy_level: DEFAULT_PRIVACY_LEVEL,
               direct_post: false, disable_duet: false, disable_comment: false,
               disable_stitch: false, video_cover_timestamp_ms: nil,
               brand_content_toggle: false, brand_organic_toggle: false,
               is_aigc: nil, chunk_size: nil)
      file = validate_file!(file)
      token = resolve_access_token(access_token)
      size = File.size(file)
      chunk_size ||= default_chunk_size(size)
      total_chunk_count = total_chunk_count(size, chunk_size)
      init_response = initialize_upload(
        token: token,
        size: size,
        chunk_size: chunk_size,
        total_chunk_count: total_chunk_count,
        title: title,
        privacy_level: privacy_level,
        direct_post: direct_post,
        disable_duet: disable_duet,
        disable_comment: disable_comment,
        disable_stitch: disable_stitch,
        video_cover_timestamp_ms: video_cover_timestamp_ms,
        brand_content_toggle: brand_content_toggle,
        brand_organic_toggle: brand_organic_toggle,
        is_aigc: is_aigc
      )
      data = init_response.fetch("data")
      upload_file(
        upload_url: data.fetch("upload_url"),
        file: file,
        size: size,
        chunk_size: chunk_size,
        total_chunk_count: total_chunk_count
      )

      Result.new(
        file: file,
        publish_id: data["publish_id"],
        upload_url: data["upload_url"],
        mode: direct_post ? "direct_post" : "inbox_upload",
        response: init_response
      )
    end

    def upload_many(files:, access_token: nil, **options)
      token = resolve_access_token(access_token)
      files.map { |file| upload(file: file, access_token: token, **options) }
    end

    def upload_manifest(workspace_dir:, access_token: nil, **options)
      files = manifest_output_files(workspace_dir)
      upload_many(files: files, access_token: access_token, **options)
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

    def initialize_upload(token:, size:, chunk_size:, total_chunk_count:, title:, privacy_level:,
                          direct_post:, disable_duet:, disable_comment:, disable_stitch:,
                          video_cover_timestamp_ms:, brand_content_toggle:, brand_organic_toggle:,
                          is_aigc:)
      body = {
        source_info: {
          source: "FILE_UPLOAD",
          video_size: size,
          chunk_size: chunk_size,
          total_chunk_count: total_chunk_count
        }
      }
      if direct_post
        post_info = {
          privacy_level: privacy_level,
          disable_duet: disable_duet,
          disable_comment: disable_comment,
          disable_stitch: disable_stitch,
          brand_content_toggle: brand_content_toggle,
          brand_organic_toggle: brand_organic_toggle
        }
        post_info[:title] = title.to_s if presence(title)
        post_info[:video_cover_timestamp_ms] = Integer(video_cover_timestamp_ms) if presence(video_cover_timestamp_ms)
        post_info[:is_aigc] = truthy?(is_aigc) unless is_aigc.nil?
        body[:post_info] = post_info
      end

      request_json(
        URI("#{API_BASE}#{direct_post ? DIRECT_POST_INIT_PATH : INBOX_INIT_PATH}"),
        headers: {
          "Authorization" => "Bearer #{token}",
          "Content-Type" => "application/json; charset=UTF-8"
        },
        body: JSON.generate(body)
      )
    end

    def upload_file(upload_url:, file:, size:, chunk_size:, total_chunk_count:)
      File.open(file, "rb") do |io|
        total_chunk_count.times do |index|
          first_byte = index * chunk_size
          remaining = size - first_byte
          bytes_to_read = index == total_chunk_count - 1 ? remaining : [chunk_size, remaining].min
          last_byte = first_byte + bytes_to_read - 1
          io.seek(first_byte)
          data = io.read(bytes_to_read)
          response = request_upload_chunk(
            URI(upload_url),
            data: data,
            first_byte: first_byte,
            last_byte: last_byte,
            size: size
          )
          expected_status = index == total_chunk_count - 1 ? "201" : "206"
          next if response.code == expected_status

          raise "TikTok upload failed with status #{response.code}: #{response.body}"
        end
      end
    end

    def request_upload_chunk(uri, data:, first_byte:, last_byte:, size:)
      request = Net::HTTP::Put.new(uri)
      request["Content-Type"] = "video/mp4"
      request["Content-Length"] = data.bytesize.to_s
      request["Content-Range"] = "bytes #{first_byte}-#{last_byte}/#{size}"
      request.body = data
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    end

    def request_json(uri, headers:, body:)
      request = Net::HTTP::Post.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      parsed = parse_json_response(response)
      return parsed if response.is_a?(Net::HTTPSuccess) && parsed.dig("error", "code").to_s == "ok"

      message = parsed.dig("error", "message") || response.body
      code = parsed.dig("error", "code") || response.code
      raise "TikTok request failed with status #{response.code} (#{code}): #{message}"
    end

    def parse_json_response(response)
      JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    rescue JSON::ParserError
      { "raw" => response.body.to_s }
    end

    def default_chunk_size(size)
      size <= WHOLE_UPLOAD_LIMIT ? size : DEFAULT_CHUNK_SIZE
    end

    def total_chunk_count(size, chunk_size)
      raise ArgumentError, "TikTok upload file must not be empty" unless size.positive?
      raise ArgumentError, "TikTok chunk size must be positive" unless chunk_size.to_i.positive?

      return 1 if size <= chunk_size

      count = size / chunk_size
      (size % chunk_size).positive? ? count + 1 : count
    end

    def resolve_access_token(access_token)
      token = presence(access_token) || presence(ENV["TIKTOK_ACCESS_TOKEN"])
      raise ArgumentError, "TikTok access token is required" unless token

      token
    end

    def validate_file!(file)
      path = File.expand_path(file.to_s)
      raise ArgumentError, "TikTok upload file not found: #{path}" unless File.file?(path)

      path
    end

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end

    def truthy?(value)
      case value
      when true then true
      when false, nil then false
      else %w[1 true yes on].include?(value.to_s.strip.downcase)
      end
    end
  end
end
