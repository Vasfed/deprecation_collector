== 0.0.5 (unreleased)
- options `print_to_stderr`, `print_recurring`

== 0.0.4
- added first_timestamp to deprecations (unix timestamp of first occurrence, not accurate because a worker with later timestamp may dump its deprecations earlier)

== 0.0.3
- Fixed selective deprecation cleanup (`DeprecationCollector.instance.cleanup { |d| d[:message].include?('foo') }`)

== 0.0.2

- Reorganized code

== 0.0.1

- Initial release