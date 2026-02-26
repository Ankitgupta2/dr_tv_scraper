#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# DR.dk TV Guide Scraper
# =============================================================================
# Scrapes the TV program schedule from https://www.dr.dk/drtv/tv-guide
# by calling the underlying Massive/Accedo CDN API that powers the page.
#
# Discovered endpoint (via browser DevTools network inspection):
#   https://prod95-cdn.dr-massive.com/api/schedules
#

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'date'
require 'csv'

# =============================================================================
# Program – immutable value object for a single broadcast slot
# =============================================================================
class Program
  attr_reader :channel_name, :title, :start_time, :end_time

  # @param channel_name [String] e.g. "DR1"
  # @param title        [String] program title
  # @param start_time   [Time]   scheduled start
  # @param end_time     [Time]   scheduled end
  def initialize(channel_name:, title:, start_time:, end_time:)
    @channel_name = channel_name
    @title        = title
    @start_time   = start_time
    @end_time     = end_time
  end

  # Human-readable line for console output
  def to_s
    "%-16s | %-8s - %-8s | %s" % [
      channel_name,
      start_time.strftime('%H:%M'),
      end_time.strftime('%H:%M'),
      title
    ]
  end

  # Plain-hash for JSON / CSV serialisation
  def to_h
    {
      channel_name: channel_name,
      title:        title,
      start_time:   start_time.strftime('%Y-%m-%d %H:%M'),
      end_time:     end_time.strftime('%Y-%m-%d %H:%M')
    }
  end
end

# =============================================================================
# DRApiClient – wraps the Massive CDN schedule API
# =============================================================================
class DRApiClient
  # The CDN endpoint discovered from browser network traffic on
  # https://www.dr.dk/drtv/tv-guide
  BASE_URL = 'https://prod95-cdn.dr-massive.com/api/schedules'

  # All DR linear channel IDs (taken directly from the browser request).
  # Covers: DR1, DR2, DR3, DR Ramasjang, DR Ultra, DR K,
  #         DR Nyheder, DR Ramaskrig, DR1 HD
  CHANNEL_IDS = %w[
    20875 20876 20892 20966 21546
    22221 22463 192099 237449
  ].freeze

  # Static query parameters – identical to what the browser sends
  STATIC_PARAMS = {
    'device'         => 'web_browser',
    'duration'       => '24',        # 24-hour window in one request
    'ff'             => 'idp,ldp,rpt',
    'geoLocation'    => 'abroad',
    'hour'           => '0',         # midnight start
    'isDeviceAbroad' => 'true',
    'lang'           => 'da',
    'segments'       => 'drtv,optedout',
    'sub'            => 'Anonymous2'
  }.freeze

  # Browser-like User-Agent to avoid CDN 403 rejections
  USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
               'AppleWebKit/537.36 (KHTML, like Gecko) ' \
               'Chrome/123.0.0.0 Safari/537.36'

  # Fetch the full schedule JSON for the given date.
  #
  # @param date [String] ISO date string "YYYY-MM-DD"
  # @return [Array<Hash>] parsed JSON array – one entry per channel
  # @raise [RuntimeError] on network / HTTP / JSON errors
  def fetch_schedule(date)
    uri = build_uri(date)
    perform_request(uri)
  end

  private

  # Assemble the request URI with all query parameters
  def build_uri(date)
    uri = URI(BASE_URL)
    uri.query = URI.encode_www_form(
      STATIC_PARAMS.merge(
        'channels' => CHANNEL_IDS.join(','),
        'date'     => date
      )
    )
    uri
  end

  # Execute the GET request and return the parsed response body
  def perform_request(uri)
    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.open_timeout = 10
    http.read_timeout = 30

    req                 = Net::HTTP::Get.new(uri)
    req['User-Agent']   = USER_AGENT
    req['Accept']       = 'application/json, */*'
    req['Referer']      = 'https://www.dr.dk/'
    req['Origin']       = 'https://www.dr.dk'

    response = http.request(req)

    unless response.code == '200'
      raise "HTTP #{response.code} #{response.message} fetching: #{uri}"
    end

    JSON.parse(response.body)
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError => e
    raise "Network error: #{e.message}"
  rescue JSON::ParserError => e
    raise "Could not parse API JSON: #{e.message}"
  end
end

# =============================================================================
# DRChannelRegistry – resolves numeric channel IDs to display names
# =============================================================================
class DRChannelRegistry
  # Static fallback map (used when the API omits or blanks the name field)
  KNOWN_CHANNELS = {
    '20875'  => 'DR1',
    '20876'  => 'DR2',
    '20892'  => 'DR3',
    '20966'  => 'DR Ramasjang',
    '21546'  => 'DR Ultra',
    '22221'  => 'DR K',
    '22463'  => 'DR Nyheder',
    '192099' => 'DR Ramaskrig',
    '237449' => 'DR1 HD'
  }.freeze

  # Return the best available name for a channel.
  # Priority: API-provided name > static map > raw ID string.
  #
  # @param channel_id [String, Integer]
  # @param api_name   [String, nil]
  # @return [String]
  def self.resolve(channel_id, api_name = nil)
    return api_name.strip if api_name && !api_name.strip.empty?

    KNOWN_CHANNELS.fetch(channel_id.to_s, "Channel-#{channel_id}")
  end
end

# =============================================================================
# DRTVScheduleParser – transforms raw API JSON into Program objects
# =============================================================================
class DRTVScheduleParser
  # The Massive/Accedo API returns an array structured as:
  #
  #   [
  #     {
  #       "channelId":   20875,
  #       "channelName": "DR1",          # sometimes present
  #       "schedules": [                 # or "items" / "schedule"
  #         {
  #           "title":     "Nyhederne",
  #           "startDate": "2026-02-26T19:00:00+01:00",  # or "start"
  #           "endDate":   "2026-02-26T19:30:00+01:00"   # or "end"
  #         }
  #       ]
  #     }
  #   ]
  #
  # Field aliases observed across different API response versions are
  # handled via ordered fallback lookups in the helper methods below.

  # Parse the API array into a Hash of channel_name => [Program, ...]
  #
  # @param raw_data [Array<Hash>]
  # @return [Hash<String, Array<Program>>]
  def parse(raw_data)
    schedule = {}

    Array(raw_data).each do |channel_data|
      channel_name = DRChannelRegistry.resolve(
        channel_data['channelId'],
        channel_data['channelName']
      )

      # Broadcast list may appear under several key names
      broadcasts = channel_data['schedules'] ||
                   channel_data['items']     ||
                   channel_data['schedule']  ||
                   []

      programs = broadcasts.filter_map do |b|
        build_program(b, channel_name)
      end

      # Sort chronologically within each channel
      schedule[channel_name] = programs.sort_by(&:start_time)
    end

    schedule
  end

  private

  # Build a Program from a single broadcast hash.
  # Returns nil (so filter_map skips it) if any required field is missing.
  def build_program(broadcast, channel_name)
    title = extract_title(broadcast).strip
    return nil if title.empty?

    start_time = parse_time(
      broadcast['startDate'] || broadcast['start'] || broadcast['scheduleStart']
    )
    end_time = parse_time(
      broadcast['endDate'] || broadcast['end'] || broadcast['scheduleEnd']
    )
    return nil if start_time.nil? || end_time.nil?

    Program.new(
      channel_name: channel_name,
      title:        title,
      start_time:   start_time,
      end_time:     end_time
    )
  end

  # Try multiple title keys used across API versions
  def extract_title(broadcast)
    broadcast['item']['title']       ||
      broadcast['customTitle'] ||
      broadcast['showTitle']   ||
      ''
  end

  # Safely parse an ISO-8601 datetime string; returns nil on failure
  def parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end

# =============================================================================
# DRTVScraper – public facade: orchestrates fetch → parse → output
# =============================================================================
class DRTVScraper
  # @param date [String] "YYYY-MM-DD"; defaults to today
  def initialize(date: Date.today.to_s)
    @date     = date
    @client   = DRApiClient.new
    @parser   = DRTVScheduleParser.new
    @schedule = {}
  end

  # Fetch and parse the schedule. Returns self to allow method chaining.
  def scrape
    puts "[INFO] Fetching DR TV schedule for #{@date} …"
    raw   = @client.fetch_schedule(@date)
    @schedule = @parser.parse(raw)
    puts "[INFO] Done — #{total_programs} programs across #{@schedule.size} channels."
    self
  end

  # ── Output helpers ────────────────────────────────────────────────────────

  # Print a formatted table to STDOUT
  def print_schedule
    puts "\n#{'=' * 74}"
    puts " DR TV Schedule — #{@date}"
    puts '=' * 74
    puts "%-16s | %-8s - %-8s | %s" % %w[Channel Start End Title]
    puts '-' * 74

    @schedule.each do |_channel, programs|
      programs.each { |p| puts p }
      puts '-' * 74
    end
  end

  # Write a pretty-printed JSON file. Returns the path written.
  def export_json(path: "dr_tv_schedule_#{@date}.json")
    payload = {
      date:           @date,
      scraped_at:     Time.now.utc.iso8601,
      total_channels: @schedule.size,
      total_programs: total_programs,
      schedule:       @schedule.transform_values { |progs| progs.map(&:to_h) }
    }
    File.write(path, JSON.pretty_generate(payload))
    puts "[INFO] JSON written → #{path}"
    path
  end

  # Write a CSV file with headers. Returns the path written.
  def export_csv(path: "dr_tv_schedule_#{@date}.csv")
    CSV.open(path, 'w',
             write_headers: true,
             headers: %w[channel_name start_time end_time title]) do |csv|
      @schedule.each_value do |programs|
        programs.each { |p| csv << p.to_h.values }
      end
    end
    puts "[INFO] CSV  written → #{path}"
    path
  end

  private

  def total_programs
    @schedule.values.sum(&:size)
  end
end

# =============================================================================
# CLI entry point
# =============================================================================
if __FILE__ == $PROGRAM_NAME
  date = ARGV[0] || Date.today.to_s

  unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    warn "Usage: ruby dr_tv_scraper.rb [YYYY-MM-DD]"
    warn "Example: ruby dr_tv_scraper.rb 2026-02-26"
    exit 1
  end

  begin
    scraper = DRTVScraper.new(date: date)
    scraper.scrape
    scraper.print_schedule
    scraper.export_json
    scraper.export_csv
  rescue RuntimeError => e
    warn "[ERROR] #{e.message}"
    exit 1
  end
end