#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require 'cgi'
require 'nokogiri'
require 'open-uri'
require 'json'
require 'pp'
require 'progress_bar'


module SVT #:nodoc:
  module Recorder
    VERSION = '1.1.0'

    class Base
      def initialize(url, options)
        @subs       = nil
        @part_base  = ''
        @parts      = []
        @stream_map = {}
        @options    = options

        video = fetch_playlist(url)

        @title      = video[:title] or ''
        @stream     = video[:url]
        @base_url   = File.dirname(video[:url])

        self.part_urls
      end

      attr_reader :subs
      attr_reader :parts
      attr_reader :title
      attr_reader :base_url
      attr_reader :stream_map

      def playlist_config(url)
        {
          /svtplay\.se/ =>
          ['#player', "http://www.svtplay.se/%s?output=json"],

          /oppetarkiv\.se/ =>
          ['#player', "http://www.oppetarkiv.se/%s?output=json"],

          /svt\.se/ =>
          ['.svtplayer', "http://www.svt.se/%s"],
        }.each do |pattern, config|
          if url.match(pattern)
            return config
          end
        end

        raise "Unknown hostname"
      end

      def fetch_playlist_url(url)
        css_path, playlist_format = playlist_config(url)

        doc = Nokogiri::HTML(open(url).read)
        player = doc.at_css(css_path)
        stream = CGI.unescape(player['data-json-href'])
        return playlist_format % stream
      end

      def fetch_playlist(url)
        stream = fetch_playlist_url(url)
        jsinfo = open(stream).read
        open('/tmp/info.json', 'w') {|f| f.write(jsinfo) }

        @jsinfo = JSON.parse(jsinfo)

        if not @jsinfo['video']['availableOnMobile']
          raise ArgumentError, "The passed in URL is not available for mobile"
        end

        title = @jsinfo['context']['title']
        v = @jsinfo['video']['videoReferences'].find({}) do |v|
          v['playerType'] == 'ios'
        end

        @subs = @jsinfo['video']['subtitleReferences'][0]['url'] rescue nil
        if @subs == ''
          @subs = nil
        end

        if not v.empty?
            @title = title
            @url = CGI.unescape(v['url'])
            {:title => title, :url => @url} if not v.empty?
        end
      end

      def choose_stream
        if @options[:resolution]
          url, _ = get_streams().find do |k,v|
            v['RESOLUTION'] == @options[:resolution]
          end
        elsif @options[:bitrate]
          url, _ = get_streams().find do |k,v|
            v['BANDWIDTH'].to_i == @options[:bitrate].to_i
          end
        else
          bitrate = bitrates.max

          url, _ = get_streams().find do |k,v|
            v['BANDWIDTH'].to_i == bitrate
          end
        end

        url
      end

      def part_urls
        return if not @parts.empty?

        url = choose_stream

        open(url).each do |row|
          next if row[0..0] == '#'
          row.strip!

          @part_base = File.dirname(row) if @part_base.empty?
          part = File.basename(row)
          @parts << "#{@part_base}/#{part}"
        end
      end

      # Returns or yields all parts, in order, for this video.
      # If all parts then are downloaded in sequence and concatenated there
      # will be a playable movie.
      #
      # Yield:
      #   A complete part download URL
      #
      # Returns:
      #   All parts in an ordered array, first -> last, full URL
      #def parts
      #  if block_given?
      #    @parts.each {|i| yield "#{@part_base}/#{i}"}
      #  else
      #    @parts.map {|p| "#{@part_base}/#{p}" }
      #  end
      #end

      # Returns the number of parts this recording got
      #
      # Returns:
      #   int the numbers of parts, 0 index
      def parts?
        return @parts.size
      end

      # All available bitrates for this video/playlist.
      # Returns:
      #   An array of bitrates, orderered highest->lowest
      def bitrates
        bitrates = Hash[get_streams().map {|url,v| [v['BANDWIDTH'].to_i, url]}]
        bitrates.keys.sort.reverse
      end

      #--
      # A naïve parser, but until it turns out to be a problem it'll do.
      # 2012=09-09: If a FQDN address is given only return the basename
      #
      # The format is:
      #   EXT-X-.... BANDWIDTH=<bitrate>
      #   playlist-filename
      def get_streams
        return @stream_map if not @stream_map.empty?

        bitrate = nil

        rates = open(@stream).read
        open('/tmp/streaminfo.wtf', 'w') {|f| f.write(rates) }

        @stream_map = {}

        rates.scan(/\n#EXT-X-STREAM-INF:([^\n]*)\n(http:[^\n]*)/) do |kv,url|
          @stream_map[url] = Hash[kv.scan(/([^=,]+)=("[^"]*"|[^,]*)/)]
        end

        @stream_map
      end
    end # /Base

    class HTTPDownload
      def initialize(options, downloader, filename)
        @options = options
        @base_url = URI.parse(downloader.base_url)
        @downloader = downloader
        @headers = {
          'User-Agent' =>
          ('Mozilla/5.0 (Windows; U; Windows NT 5.2; en-US; rv:1.9.2.10) ' +
           'Gecko/20100914 Firefox/3.6.10')
        }
        @filename = filename
        @server = Net::HTTP.start(@base_url.host, @base_url.port)
      end

      def fetch_subs
        if @downloader.subs
          subs_name = @filename + '.srt'
          STDERR.puts "Getting subs..."
          File.open(subs_name, 'wb+') do |fh|
            text = open(@downloader.subs).read
            fixed = text.gsub(/(\d\d:\d\d:\d\d).(\d\d\d)/, '\1,\2')
            fh.write(fixed)
          end
        end
      end

      # Will yield the number of megabytes downloaded every megabyte
      def fetch_video
        downloaded = 0
        megabyte = 1024 * 1024
        mb_down = 0

        STDERR.puts "Starting recording..."

        File.open(@filename + '.mp4', 'wb+') do |fh|
          @downloader.parts.each_index do |i|
            part = @downloader.parts[i]
            begin
              @server.request_get(part, @headers) do |res|
                res.read_body do |body|
                  fh.write body
                end
              end # /@server
            rescue Timeout::Error, EOFError, Errno::ECONNRESET => exception
              yield -1
              @server = Net::HTTP.start(@base_url.host, @base_url.port)
              STDERR.puts "Connection error..."
              retry
            end

            yield i, part
          end
        end

        STDERR.puts "\nFinished recording: #{@filename}"
      end

      def close ; @server.finish ; end
      alias :disconnect :close

      def get

        fetch_subs if @options[:subs]

        if @options[:quiet]
          prog = lambda {|i, part| }
        else
          progress = ProgressBar.new(
              @downloader.parts.size, :bar, :elapsed, :eta, :counter)
          prog = lambda {|i, part| progress.increment! }
        end

        fetch_video &prog if @options[:video]
      end
    end
  end
end
