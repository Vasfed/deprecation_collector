# frozen_string_literal: true

# :nodoc:
class DeprecationCollector
  class << self
    protected

    def install_collectors
      tap_activesupport if defined?(ActiveSupport::Deprecation)
      tap_kernel
      tap_warning_class
    end

    def tap_warning_class
      Warning.singleton_class.prepend(DeprecationCollector::WarningCollector)
      Warning[:deprecated] = true if Warning.respond_to?(:[]=) # turn on ruby 2.7 deprecations
    end

    def tap_activesupport
      # TODO: a more polite hook
      ActiveSupport::Deprecation.behavior = lambda do |message, callstack, deprecation_horizon, gem_name|
        # not polite to turn off all other possible behaviors, but otherwise may get duplicate calls
        DeprecationCollector.collect(message, callstack, :rails)
        stock_behavior = Rails.application&.config&.active_support&.deprecation || :log
        ActiveSupport::Deprecation::DEFAULT_BEHAVIORS[stock_behavior].call(
          message, callstack, deprecation_horizon, gem_name
        )
      end
    end

    def tap_kernel
      Kernel.class_eval do
        # module is included in others thus prepend does not work
        remove_method :warn
        class << self
          remove_method :warn
        end
        module_function(define_method(:warn) do |*messages, **kwargs|
          KernelWarningCollector.warn(*messages, backtrace: caller, **kwargs)
        end)
      end
    end
  end

  # Ruby sometimes has two warnings for one actual occurence
  # Example:
  # caller.rb:1: warning: Passing the keyword argument as the last hash parameter is deprecated
  # calleee.rb:1: warning: The called method `method_name' is defined here
  module MultipartWarningJoiner
    module_function

    def two_part_warning?(str)
      # see ruby src - `rb_warn`, `rb_compile_warn`
      str.end_with?(
        "uses the deprecated method signature, which takes one parameter\n", # respond_to?
        # 2.7 kwargs:
        "maybe ** should be added to the call\n",
        "Passing the keyword argument as the last hash parameter is deprecated\n", # бывает и не двойной
        "Splitting the last argument into positional and keyword parameters is deprecated\n"
      ) ||
        str.include?("warning: already initialized constant") ||
        str.include?("warning: method redefined; discarding old")
    end

    def handle(new_str)
      old_str = Thread.current[:multipart_warning_str]
      Thread.current[:multipart_warning_str] = nil
      if old_str
        return yield(old_str + new_str) if new_str.include?("is defined here") || new_str.include?(" was here")

        yield(old_str)
      end

      return (Thread.current[:multipart_warning_str] = new_str) if two_part_warning?(new_str)

      yield(new_str)
    end
  end

  # taps into ruby core Warning#warn
  module WarningCollector
    def warn(str)
      backtrace = caller
      MultipartWarningJoiner.handle(str) do |multi_str|
        DeprecationCollector.collect(multi_str, backtrace, :warning)
      end
    end
  end

  # for tapping into Kernel#warn
  module KernelWarningCollector
    module_function

    def warn(*messages, backtrace: nil, **_kwargs)
      backtrace ||= caller
      str = messages.map(&:to_s).join("\n").strip
      DeprecationCollector.collect(str, backtrace, :kernel)
      # not passing to `super` - it will pass to Warning#warn, we do not want that
    end
  end
end
