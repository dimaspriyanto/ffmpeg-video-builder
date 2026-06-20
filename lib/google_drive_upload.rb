# frozen_string_literal: true

require "base64"
require "json"
begin
  require "mime/types"
rescue LoadError
  # mime-types is optional; the fallback map below covers project outputs.
end

require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"

module GoogleDriveUpload
  DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
  DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
  DEFAULT_UPLOAD_URI = "https://www.googleapis.com/upload/drive/v3/files"
  DEFAULT_FIELDS = "id,name,mimeType,webViewLink,webContentLink"
  MIME_TYPES = {
    ".mp4" => "video/mp4",
    ".mov" => "video/quicktime",
    ".webm" => "video/webm",
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".json" => "application/json",
    ".txt" => "text/plain"
  }.freeze

  Result = Struct.new(:file, :id, :name, :mime_type, :web_view_link, :web_content_link, :response, keyword_init: true) do
    def to_h
      {
        file: file,
        id: id,
        name: name,
        mime_type: mime_type,
        web_view_link: web_view_link,
        web_content_link: web_content_link,
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
    def upload(file:, name: nil, folder_id: nil, mime_type: nil, access_token: nil,
               credentials_file: nil, supports_all_drives: true)
      file = validate_file!(file)
      token = resolve_access_token(access_token: access_token, credentials_file: credentials_file)
      metadata = { "name" => presence(name) || File.basename(file) }
      metadata["parents"] = [folder_id.to_s] if presence(folder_id)
      mime_type ||= detect_mime_type(file)

      response = upload_multipart(
        token: token,
        metadata: metadata,
        file: file,
        mime_type: mime_type,
        supports_all_drives: supports_all_drives
      )

      Result.new(
        file: file,
        id: response["id"],
        name: response["name"],
        mime_type: response["mimeType"],
        web_view_link: response["webViewLink"],
        web_content_link: response["webContentLink"],
        response: response
      )
    end

    def upload_many(files:, folder_id: nil, access_token: nil, credentials_file: nil, supports_all_drives: true)
      token = resolve_access_token(access_token: access_token, credentials_file: credentials_file)
      files.map do |file|
        upload(
          file: file,
          folder_id: folder_id,
          access_token: token,
          credentials_file: nil,
          supports_all_drives: supports_all_drives
        )
      end
    end

    def upload_manifest(workspace_dir:, folder_id: nil, access_token: nil, credentials_file: nil, supports_all_drives: true)
      files = manifest_output_files(workspace_dir)
      upload_many(
        files: files,
        folder_id: folder_id,
        access_token: access_token,
        credentials_file: credentials_file,
        supports_all_drives: supports_all_drives
      )
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

    def upload_multipart(token:, metadata:, file:, mime_type:, supports_all_drives:)
      boundary = "ruby-drive-upload-#{SecureRandom.hex(12)}"
      body = [
        "--#{boundary}\r\n",
        "Content-Type: application/json; charset=UTF-8\r\n\r\n",
        JSON.generate(metadata),
        "\r\n--#{boundary}\r\n",
        "Content-Type: #{mime_type}\r\n\r\n",
        File.binread(file),
        "\r\n--#{boundary}--\r\n"
      ].join
      uri = URI(DEFAULT_UPLOAD_URI)
      uri.query = URI.encode_www_form(
        uploadType: "multipart",
        fields: DEFAULT_FIELDS,
        supportsAllDrives: supports_all_drives ? "true" : "false"
      )
      headers = {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "multipart/related; boundary=#{boundary}"
      }

      request_json(uri, headers: headers, body: body)
    end

    def resolve_access_token(access_token:, credentials_file:)
      token = presence(access_token) || presence(ENV["GOOGLE_DRIVE_ACCESS_TOKEN"])
      return token if token

      credentials_file = presence(credentials_file) ||
                         presence(ENV["GOOGLE_DRIVE_CREDENTIALS"]) ||
                         presence(ENV["GOOGLE_APPLICATION_CREDENTIALS"])
      raise ArgumentError, "Google Drive access token or service account credentials file is required" unless credentials_file

      service_account_access_token(credentials_file)
    end

    def service_account_access_token(credentials_file)
      credentials_file = File.expand_path(credentials_file.to_s)
      raise ArgumentError, "Google credentials file not found: #{credentials_file}" unless File.file?(credentials_file)

      credentials = JSON.parse(File.read(credentials_file))
      assertion = service_account_assertion(credentials)
      uri = URI(credentials["token_uri"] || DEFAULT_TOKEN_URI)
      response = request_json(
        uri,
        headers: { "Content-Type" => "application/x-www-form-urlencoded" },
        body: URI.encode_www_form(
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion: assertion
        )
      )
      response.fetch("access_token")
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid Google credentials JSON: #{credentials_file}: #{e.message}"
    end

    def service_account_assertion(credentials)
      now = Time.now.to_i
      header = { alg: "RS256", typ: "JWT" }
      payload = {
        iss: credentials.fetch("client_email"),
        scope: DRIVE_SCOPE,
        aud: credentials["token_uri"] || DEFAULT_TOKEN_URI,
        exp: now + 3600,
        iat: now
      }
      signing_input = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
      private_key = OpenSSL::PKey::RSA.new(credentials.fetch("private_key"))
      signature = private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
      "#{signing_input}.#{base64url(signature)}"
    end

    def request_json(uri, headers:, body:)
      request = Net::HTTP::Post.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      parsed = parse_json_response(response)
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed["error_description"] || parsed.dig("error", "message") || response.body
      raise "Google Drive request failed with status #{response.code}: #{message}"
    end

    def parse_json_response(response)
      JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    rescue JSON::ParserError
      { "raw" => response.body.to_s }
    end

    def detect_mime_type(file)
      mapped = MIME_TYPES[File.extname(file).downcase]
      return mapped if mapped

      if defined?(MIME::Types)
        detected = MIME::Types.type_for(file).first
        return detected.content_type if detected
      end

      "application/octet-stream"
    end

    def validate_file!(file)
      path = File.expand_path(file.to_s)
      raise ArgumentError, "Upload file not found: #{path}" unless File.file?(path)

      path
    end

    def base64url(value)
      Base64.urlsafe_encode64(value).delete("=")
    end

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
