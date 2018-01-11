require 'stringio'
RSpec::Support.require_rspec_core "formatters/base_bisect_formatter"
RSpec::Support.require_rspec_core "bisect/utilities"

module RSpec
  module Core
    module Bisect
      # TODO: docs
      # @private
      class ForkRunner
        def self.start(shell_command)
          instance = new(shell_command)
          yield instance
        ensure
          instance.shutdown
        end

        def initialize(shell_command)
          @shell_command = shell_command

          @channel = Channel.new(*IO.pipe)
          @run_dispatcher = RunDispatcher.new(@channel, @shell_command.original_cli_args)
        end

        def run(locations)
          run_locations(ExampleSetDescriptor.new(locations,
            original_results.failed_example_ids))
        end

        def original_results
          @original_results ||= run_locations(ExampleSetDescriptor.new(
            @shell_command.original_locations, []))
        end

        def shutdown
          @channel.close
        end

      private

        def run_locations(run_descriptor)
          @run_dispatcher.dispatch_specs(run_descriptor)
          @channel.receive.tap do |result|
            if result.is_a?(String)
              raise BisectFailedError.for_failed_spec_run(result)
            end
          end
        end

        class RunDispatcher
          def initialize(channel, original_cli_args)
            RSpec.reset
            @channel = channel
            @spec_output = StringIO.new
            options = ConfigurationOptions.new(original_cli_args)
            @runner = Runner.new(options)
            @runner.load_config(@spec_output, @spec_output)
            # TODO: consider running `before(:suite)` hooks
          end

          def dispatch_specs(run_descriptor)
            pid = fork { run_specs(run_descriptor); exit! }
            Process.waitpid(pid)
          end

        private

          def run_specs(run_descriptor)
            $stdout = $stderr = @spec_output
            formatter = CaptureFormatter.new(run_descriptor.failed_example_ids)

            RSpec.configure do |c|
              c.files_or_directories_to_run = run_descriptor.all_example_ids
              c.formatter = formatter
              c.load_spec_files
            end

            # `announce_filters` has the side effect of implementing the logic
            # that honors `config.run_all_when_everything_filtered` so we need
            # to call it here. When we remove `run_all_when_everything_filtered`
            # (slated for RSpec 4), we can remove this call to `announce_filters`.
            RSpec.world.announce_filters

            @runner.run_specs
            latest_run_results = formatter.results

            if latest_run_results.nil? || latest_run_results.all_example_ids.empty?
              @channel.send(@spec_output.string)
            else
              @channel.send(latest_run_results)
            end
          end
        end

        class CaptureFormatter < Formatters::BaseBisectFormatter
          attr_accessor :results
          alias_method :notify_results, :results=
        end
      end
    end
  end
end
