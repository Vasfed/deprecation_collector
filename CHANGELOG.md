== 0.5.0
- more work on ui
- refactored to separate deprecations storage from other logic
- when redis is not provided - print all messages to stderr
- added `key_prefix` option (default `'deprecations'`, location may change in the future) to allow multiple independent apps to write to one redis
- added `app_name` option to record app name as separate field

== 0.4.0
- a bit better ui
- simple import/export

== 0.3.0
- simple web ui (mountable rack app)

== 0.2.0
- ability to add custom deprecation fingerprint (for example - controller+action), use `config.fingerprinter`

== 0.1.0
- kinda-breaking: ruby 2.4 was in fact not supported, so changed requirement to 2.5
- prevent recursion when deprecation fires in `context_saver` hook
- prevent recursion in most cases if a deprecation fires in collector itself

- changed all `caller` use to `caller_locations` to match rails (and take advantage of it), `#collect` now expects backtrace with an array of `Thread::Backtrace::Location`
- added GitHub Actions CI
- added ability to run without rails

== 0.0.6
- added custom context saving ability

== 0.0.5
- options `print_to_stderr`, `print_recurring`
- fix redis deprecated `pipelined` block arity (support for redis 5)

== 0.0.4
- added first_timestamp to deprecations (unix timestamp of first occurrence, not accurate because a worker with later timestamp may dump its deprecations earlier)

== 0.0.3
- Fixed selective deprecation cleanup (`DeprecationCollector.instance.cleanup { |d| d[:message].include?('foo') }`)

== 0.0.2

- Reorganized code

== 0.0.1

- Initial release