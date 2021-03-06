#!/usr/bin/env ruby
require 'rubygems'
require 'sinatra'
require 'tempfile'
require 'yaml'
require 'memcachier'
require 'dalli'
require 'uri'
require 'open-uri'
require 'open_uri_redirections'
require 'rack-cache'
require 'timeout'
require 'shellwords'

AVAILABLE_MEMES = YAML.load_file('memes.yml')

ALIASED_MEMES = AVAILABLE_MEMES.each_with_object({}) { |e, h| h[e[1][:alias].to_s] = e[0]; }

ERROR_MESSAGES = {
  'invalid' => 'Y U NO PICK A VALID MEME?! But seriously, the meme name you provided is not valid.',
  'tokens' => 'Yo dawg, you are missing some url parameters, try harder.',
  'url' => "WAT. That url wasn't an image"
}.freeze

MC = ENV['MEMCACHIER_SERVERS'] || 'localhost:11211'

use Rack::Cache, {
  verbose: true,
  metastore: "memcached://#{MC}",
  entitystore: "memcached://#{MC}"
}

class NotAnImageException < StandardError; end

get '/' do
  expires 300, :public

  @error = params[:error]
  erb :index
end

get '/*' do
  content_type 'image/jpeg'
  expires 31_104_000, :public # cache for a year

  # expects a meme in the format /TOP_STRING/BOTTOM_STRING/MEME_NAME.jpg
  path = CGI.unescape(request.fullpath.encode('UTF-8', invalid: :replace, undef: :replace))
  # replace spaces with underscores to make urls more readable
  redirect path.gsub(' ', '_') if path.include?(' ')

  tokens = path.split('/')

  tokens.shift if tokens.length > 3 && tokens[0] == ''

  url_match = path.match('/(https?:/.*)$')
  if url_match
    # we got a remote url, its go time
    image_url = url_match[1]
    # some browsers seem to collapse // into a single slash. Hackily normalize it so its always http://
    image_url = image_url.gsub(':/', '://').gsub(':///', '://')

    redirect '/i_see/what_you_did_there/trollface.jpg' if image_url.include? request.host

    # grab the remote image
    begin
      tempfile = Tempfile.new(['imagegrabber', '.jpg'])
      Timeout.timeout 3 do
        open(image_url, allow_redirections: :all) do |url|
          tempfile.write(url.read)
        end
      end
      tempfile.flush

      meme_path = normalize_image tempfile.path
      width = 550
    rescue OpenURI::HTTPError, NotAnImageException, Timeout::Error => e
      puts "EXCEPTION: #{e.inspect} -- #{path}"
      redirect '/?error=url'
    end
  else
    # its using one of the builtin memes
    redirect '/?error=tokens' unless tokens.length == 3

    meme_name = tokens[-1].split('.')[0].downcase
    meme_name = ALIASED_MEMES[meme_name] if ALIASED_MEMES.include?(meme_name)
    redirect '/?error=invalid' unless AVAILABLE_MEMES.include?(meme_name)

    meme_path = File.dirname(__FILE__) + "/public/images/meme/#{meme_name}.jpg"
    width = AVAILABLE_MEMES[meme_name][:width]
  end

  # memeify the text
  top = tokens[0].upcase.gsub('_', ' ')
  bottom = tokens[1].upcase.gsub('_', ' ')

  # default to a space so that memeify works correctly
  top = ' ' if top.nil? || top.empty?

  meme = memeify meme_path, top, bottom, width
  meme.read
end

def memeify(memepath, top, bottom, width)
  tempfile = Tempfile.new('memeifier', '/tmp/')

  # use imagemagick commands to generate the images
  # commands were largely stolen from https://github.com/vquaiato/memish
  convert top, memepath, tempfile.path, 'north', width
  convert bottom, tempfile.path, tempfile.path, 'south', width

  tempfile
end

def normalize_image(path)
  tempfile = Tempfile.new(['normalized', '.jpg'])
  cmd = "convert -resize 600x #{Shellwords.escape(path)} #{tempfile.path}"
  `#{cmd}`
  raise NotAnImageException if $?.to_i > 0

  tempfile.path
end

def convert(text, source, destination, location, width)
  fontpath = File.dirname(__FILE__) + '/lib/impact.ttf'
  text = Shellwords.escape(text)
  cmd = "convert -fill white -stroke black -strokewidth 2 -background transparent -gravity center -size #{width}x120 -font #{fontpath} -weight Bold caption:#{text} #{source} +swap -gravity #{location} -composite #{destination}"
  `#{cmd}`
end
