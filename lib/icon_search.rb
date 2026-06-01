# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module IconSearch
  DEFAULT_STYLE = "regular"
  DEFAULT_SOURCE = "fluent"
  DEFAULT_LICENSE_TYPE = "permissive"
  DEFAULT_SIZE = 512
  DEFAULT_LIMIT = 10

  SUPPORTED_SOURCES = {
    "fluent" => {
      name: "Fluent UI System Icons",
      license: "MIT",
      license_type: "permissive"
    },
    "material-symbols-light" => {
      name: "Material Symbols Light",
      license: "Apache 2.0",
      license_type: "permissive"
    },
    "material-symbols" => {
      name: "Material Symbols",
      license: "Apache 2.0",
      license_type: "permissive"
    },
    "arcticons" => {
      name: "Arcticons",
      license: "CC BY-SA 4.0",
      license_type: "attribution"
    }
  }.freeze

  SUPPORTED_LICENSE_TYPES = %w[
    permissive
    attribution
    any
  ].freeze

  STYLE_ALIASES = {
    "bold" => %w[bold filled],
    "filled" => %w[filled],
    "regular" => %w[regular],
    "light" => %w[light],
    "outline" => %w[outline outlined],
    "rounded" => %w[rounded],
    "sharp" => %w[sharp]
  }.freeze

  Result = Struct.new(
    :id,
    :name,
    :source,
    :source_name,
    :license,
    :license_type,
    :style,
    :svg_url,
    :png_url,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        name: name,
        source: source,
        source_name: source_name,
        license: license,
        license_type: license_type,
        style: style,
        svg_url: svg_url,
        png_url: png_url
      }
    end
  end

  def self.search(keyword:, style: DEFAULT_STYLE, source: DEFAULT_SOURCE, license_type: DEFAULT_LICENSE_TYPE, size: DEFAULT_SIZE, limit: DEFAULT_LIMIT)
    Client.new.search(
      keyword: keyword,
      style: style,
      source: source,
      license_type: license_type,
      size: size,
      limit: limit
    )
  end

  class Client
    API_BASE = "https://api.iconify.design"

    def search(keyword:, style: DEFAULT_STYLE, source: DEFAULT_SOURCE, license_type: DEFAULT_LICENSE_TYPE, size: DEFAULT_SIZE, limit: DEFAULT_LIMIT)
      keyword = clean_keyword(keyword)
      source = clean_source(source)
      license_type = clean_license_type(license_type)
      validate_source_license_type!(source, license_type)
      size = clean_size(size)
      limit = clean_limit(limit)
      style_tokens = style_tokens_for(style)

      response = fetch_json(search_uri(keyword: keyword, source: source, limit: limit * 3))
      icons = response.fetch("icons", [])
      ranked_icons(icons, keyword, style_tokens).first(limit).map do |icon_id|
        build_result(icon_id, source, style, size)
      end
    end

    private

    def clean_keyword(keyword)
      value = keyword.to_s.strip
      raise ArgumentError, "Icon search keyword is required" if value.empty?

      value
    end

    def clean_source(source)
      value = source.to_s.strip
      return DEFAULT_SOURCE if value.empty?
      return value if SUPPORTED_SOURCES.key?(value)

      allowed = SUPPORTED_SOURCES.keys.join(", ")
      raise ArgumentError, "Unsupported icon source: #{value.inspect}. Supported sources: #{allowed}"
    end

    def clean_license_type(license_type)
      value = license_type.to_s.strip.downcase
      return DEFAULT_LICENSE_TYPE if value.empty?
      return value if SUPPORTED_LICENSE_TYPES.include?(value)

      allowed = SUPPORTED_LICENSE_TYPES.join(", ")
      raise ArgumentError, "Unsupported icon license type: #{value.inspect}. Supported license types: #{allowed}"
    end

    def validate_source_license_type!(source, license_type)
      return if license_type == "any"

      source_license_type = SUPPORTED_SOURCES.fetch(source).fetch(:license_type)
      return if source_license_type == license_type

      raise ArgumentError, "Icon source #{source.inspect} has #{source_license_type.inspect} license type, not #{license_type.inspect}"
    end

    def clean_size(size)
      value = Integer(size)
      raise ArgumentError, "Icon size must be greater than 0" unless value.positive?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "Expected icon size in pixels, got #{size.inspect}"
    end

    def clean_limit(limit)
      value = Integer(limit)
      raise ArgumentError, "Icon search limit must be greater than 0" unless value.positive?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "Expected icon search limit, got #{limit.inspect}"
    end

    def style_tokens_for(style)
      value = style.to_s.strip.downcase
      value = DEFAULT_STYLE if value.empty?

      STYLE_ALIASES.fetch(value, [value])
    end

    def search_uri(keyword:, source:, limit:)
      uri = URI("#{API_BASE}/search")
      uri.query = URI.encode_www_form(
        query: keyword,
        prefixes: source,
        limit: limit
      )
      uri
    end

    def fetch_json(uri)
      response = Net::HTTP.get_response(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise "Iconify search failed with HTTP #{response.code}: #{response.message}"
      end

      JSON.parse(response.body)
    rescue SocketError, SystemCallError => e
      raise "Iconify search request failed: #{e.message}"
    rescue JSON::ParserError => e
      raise "Iconify returned invalid JSON: #{e.message}"
    end

    def ranked_icons(icon_ids, keyword, style_tokens)
      tokens = keyword.downcase.split(/\s+/)

      icon_ids.sort_by do |icon_id|
        name = icon_name(icon_id)
        [
          style_score(name, style_tokens),
          title_score(name, tokens),
          name.length,
          name
        ]
      end
    end

    def style_score(name, style_tokens)
      return 0 if style_tokens.empty?

      style_tokens.any? { |token| name.include?(token) } ? 0 : 1
    end

    def title_score(name, tokens)
      tokens.all? { |token| name.include?(token) } ? 0 : 1
    end

    def build_result(icon_id, source, style, size)
      source_metadata = SUPPORTED_SOURCES.fetch(source)
      name = icon_name(icon_id)

      Result.new(
        id: icon_id,
        name: name,
        source: source,
        source_name: source_metadata.fetch(:name),
        license: source_metadata.fetch(:license),
        license_type: source_metadata.fetch(:license_type),
        style: style.to_s.empty? ? DEFAULT_STYLE : style,
        svg_url: asset_url(icon_id, "svg", size),
        png_url: asset_url(icon_id, "png", size)
      )
    end

    def icon_name(icon_id)
      icon_id.to_s.split(":", 2).last
    end

    def asset_url(icon_id, format, size)
      prefix, name = icon_id.split(":", 2)
      uri = URI("#{API_BASE}/#{prefix}/#{name}.#{format}")
      uri.query = URI.encode_www_form(width: size, height: size)
      uri.to_s
    end
  end
end
