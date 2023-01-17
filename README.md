# DeprecationCollector
[![Gem Version](https://badge.fury.io/rb/deprecation_collector.svg)](https://badge.fury.io/rb/deprecation_collector)

Collects ruby and rails deprecation warnings.
Designed to be suitable for use in production under load.

(gem is a work-in-process, documentation will come later)

## Installation

Install the gem and add to the application's Gemfile by executing:

```sh
bundle add deprecation_collector
```

## Usage

Add an initializer with configuration, like

```ruby
  Rails.application.config.to_prepare do
    DeprecationCollector.install do |instance|
      instance.redis = Redis.new # default is $redis
      instance.app_revision = ::GIT_REVISION
      instance.count = false
      instance.save_full_backtrace = true
      instance.raise_on_deprecation = false
      instance.write_interval = (::Rails.env.production? && 15.minutes) || 1.minute
      instance.exclude_realms = %i[kernel] if Rails.env.production?
      instance.print_to_stderr = true if Rails.env.development?
      instance.print_recurring = false
      instance.ignored_messages = [
        "Ignoring db/schema_cache.yml because it has expired"
      ]
      instance.context_saver do
        # this will only be called for new deprecations, return value must be json-compatible
        { some: "custom", context: "for example request.id" }
      end
      instance.fingerprinter do |deprecation|
        # this will be added to fingerprint; this will be ignored for recursive deprecations
        "return_string_here"
      end
    end
  end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Vasfed/deprecation_collector.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
