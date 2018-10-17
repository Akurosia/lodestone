require 'sinatra'
require 'sinatra/json'
require 'sinatra/custom_logger'
require 'logger'

require 'open-uri'
require 'ostruct'
require 'time'
require 'thwait'
require 'yaml'

configure do
  require_relative 'lib/logger.rb'
  require_relative 'lib/news.rb'
  require_relative 'lib/scheduler.rb'
  require_relative 'lib/webhooks.rb'

  LOCALES = %w(na eu fr de jp).freeze
  HOSTS = YAML.load_file('config/hosts.yml').freeze

  use Rack::CommonLogger, LodestoneLogger.logger
  set :logger, LodestoneLogger.logger

  # Do not log requests to STDERR in production
  set :logging, nil if settings.production?

  # Cache static assets for one week
  set :static_cache_control, [:public, max_age: 604_800]

  redis = Redis.current = Redis::Namespace.new(:lodestone)
  Scheduler.run

  if message = redis.get(:announcement)
    Thread.new do
      Webhooks.send_announcement(message)
      redis.del(:announcement)
    end
  end
end

get '/' do
  @categories = { topics: '1', notices: '0', maintenance: '1', updates: '1', status: '0', developers: '1' }
  @state = @categories.values.join
  @code = params['code']
  @redirect_uri = "#{HOSTS[request_locale]}/authorize"
  erb :index
end

get '/authorize' do
  @state = params['state']
  @categories = News.categories.to_h.keys.map(&:to_s).zip(@state.chars).to_h
  @redirect_uri = "#{HOSTS[request_locale]}/authorize"

  begin
    url = Webhooks.url(params['code'], @redirect_uri)
    News.subscribe(@categories.merge('url' => url), request_locale)
    @flash = { success: 'You are now subscribed to Lodestone updates.' }
  rescue Exception => e
    logger.error "Failed to subscribe - #{e.message}"
    logger.error e.backtrace.join("\n") unless settings.production?
    @flash = { danger: 'Sorry, something went wrong. Please try again.' }
  end

  erb :index
end

# Check subscription status
get '/news/subscribe' do
  cache_control :no_cache

  begin
    json News.subscribe(params, request_locale, true)
  rescue ArgumentError
    halt 400, json(error: 'Invalid webhook URL.')
  end
end

# Subscribe/update subscription
post '/news/subscribe' do
  cache_control :no_cache

  begin
    data = JSON.parse(request.body.read)
    json News.subscribe(data, request_locale, true)
  rescue ArgumentError
    halt 400, json(error: 'Invalid webhook URL.')
  rescue JSON::ParserError
    halt 400, json(error: 'Invalid JSON body.')
  end
end

get '/news/feed' do
  feed = News.feed(request_locale)
  headers = NewsCache.headers(:topics, request_locale)
  last_modified headers[:last_modified]
  expires headers[:expires], :must_revalidate
  json feed
end

get '/news/:category' do
  category = params[:category].downcase

  begin
    news = News.fetch(category, request_locale)
    headers = NewsCache.headers(category, request_locale)
    last_modified headers[:last_modified]
    expires headers[:expires], :must_revalidate
    json news
  rescue ArgumentError
    halt 400, json(error: 'Invalid news category.')
  end
end

not_found do
  erb 'errors/not_found'.to_sym
end

error do
  erb 'errors/error'.to_sym
end

def request_locale
  locale = request.host[0, 2]
  LOCALES.include?(locale) ? locale : 'na'
end
