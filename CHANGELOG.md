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